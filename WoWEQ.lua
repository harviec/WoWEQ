-- WoWEQ.lua (v1.1.3)
-- Audio-reactive frequency equalizer for WoW Midnight (Patch 12.x)
--
-- Bar layout: horizontal strips stacked vertically inside two side panels.
--   Band 1 (bottom) = bass / low frequencies
--   Band N (top)    = treble / high frequencies
--
-- Signal sources:
--   C_CombatAudioAlert.GetCategoryVolume(0-8)  — nine live audio category volumes,
--       each mapped to its appropriate frequency range.
--   hooksecurefunc on PlaySound/PlaySoundFile/C_Sound.PlaySound — broadband bursts.
--   COMBAT_LOG_EVENT_UNFILTERED — fine-grained band injection per combat action type.
--   Game events (combat, boss, zone, spellcasts) — coarser state bursts.
--
-- Slash commands:
--   /woweq            toggle visibility
--   /woweq show|hide  show or hide panels
--   /woweq bars N     change bar count (4-32), persisted in SavedVariables

-- ============================================================
-- Configuration  (geometry/animation constants — not user-facing)
-- ============================================================
local CFG = {
    -- user-controlled; default overridden from WoWEQDB.numBars at ADDON_LOADED
    NUM_BARS      = 12,

    -- bar geometry
    BAR_HEIGHT    = 14,     -- px: height of each horizontal bar
    BAR_GAP       = 5,      -- px: vertical gap between bars
    MAX_WIDTH     = 130,    -- px: max horizontal extent (full amplitude)
    MIN_WIDTH     = 2,      -- px: minimum rendered width
    PADDING       = 10,     -- px: inner padding around the bar area

    -- animation
    UPDATE_RATE   = 0.033,  -- tick interval in seconds (~30 fps)
    LERP_SPEED    = 7.0,    -- bar width smoothing (higher = snappier)
    BAND_DECAY    = 2.5,    -- injected energy decay rate per second (out of combat)
    PEAK_HOLD     = 0.90,   -- seconds peak indicator stays before falling
    PEAK_FALL     = 3.0,    -- peak fall speed multiplier

    -- idle / ambient animation
    IDLE_FREQ_LO  = 0.20,   -- Hz: slow oscillation on bass bands
    IDLE_FREQ_HI  = 2.00,   -- Hz: fast oscillation on treble bands
    -- Peak amplitude for bass band at idle; treble gets ~45% of this.
    -- In combat the whole spectrum rises significantly.
    IDLE_AMP_BASE = 0.30,   -- bass peak amplitude out of combat
    IDLE_AMP_COMB = 0.55,   -- bass peak amplitude in combat
}

-- ============================================================
-- Shared runtime state
-- ============================================================
local S = {
    inCombat    = false,
    inBoss      = false,
    isResting   = false,
    playerGUID  = nil,
    alertEnergy = {},   -- C_CombatAudioAlert volumes indexed [0-8]
    bandEnergy  = {},   -- injected energy per frequency band [1..NUM_BARS]
    barState    = {},   -- per-band animation: {phase, peak, peakTimer}
    elapsed     = 0,    -- total seconds since load (drives oscillators)
    accumDt     = 0,    -- delta accumulator for throttled ticks
}

-- ============================================================
-- Color themes
-- ============================================================
local COL = {
    peaceful = {0.10, 0.55, 1.00},
    combat   = {1.00, 0.40, 0.10},
    boss     = {0.85, 0.15, 1.00},
    resting  = {0.20, 0.90, 0.45},
}

local function GetColor()
    if     S.inBoss      then return unpack(COL.boss)
    elseif S.inCombat    then return unpack(COL.combat)
    elseif S.isResting   then return unpack(COL.resting)
    else                      return unpack(COL.peaceful)
    end
end

-- ============================================================
-- Utilities
-- ============================================================
local function lerp(a, b, t)    return a + (b - a) * t end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- Normalised position of band i within the spectrum (0 = bass, 1 = treble)
local function FreqFrac(band)
    return (band - 1) / math.max(CFG.NUM_BARS - 1, 1)
end

-- ============================================================
-- Frequency-band energy injection
-- ============================================================
-- lowFrac / highFrac are 0-1 fractions of the full frequency spectrum.
local function InjectBands(lowFrac, highFrac, amount)
    local lo = math.max(1,            math.floor(lowFrac  * CFG.NUM_BARS) + 1)
    local hi = math.min(CFG.NUM_BARS, math.ceil (highFrac * CFG.NUM_BARS))
    for b = lo, hi do
        S.bandEnergy[b] = math.min(1.0, (S.bandEnergy[b] or 0) + amount)
    end
end

local function InjectAll(a)     InjectBands(0.00, 1.00, a) end
local function InjectLow(a)     InjectBands(0.00, 0.35, a) end
local function InjectMid(a)     InjectBands(0.30, 0.70, a) end
local function InjectHigh(a)    InjectBands(0.65, 1.00, a) end
local function InjectLowMid(a)  InjectBands(0.10, 0.55, a) end
local function InjectMidHigh(a) InjectBands(0.45, 0.90, a) end

-- ============================================================
-- Panel frames  (persistent containers; bars inside are rebuilt)
-- ============================================================
local leftPanel  = CreateFrame("Frame", "WoWEQ_Left",  UIParent, "BackdropTemplate")
local rightPanel = CreateFrame("Frame", "WoWEQ_Right", UIParent, "BackdropTemplate")

local function ConfigurePanel(panel, anchor, panelH)
    local w = CFG.MAX_WIDTH + CFG.PADDING * 2
    panel:SetSize(w, panelH)
    panel:SetFrameStrata("BACKGROUND")
    panel:SetFrameLevel(1)
    panel:ClearAllPoints()
    panel:SetPoint(anchor, UIParent, anchor, 0, 0)
    panel:SetBackdrop(nil)  -- no background box, bars only
end

-- Hide until ADDON_LOADED so there is no flash of unstyled panels
leftPanel:Hide()
rightPanel:Hide()

-- ============================================================
-- Bar construction and teardown
-- ============================================================
local leftBars  = {}
local rightBars = {}

local function DestroyBars(bars)
    for _, bar in ipairs(bars) do
        if bar.frame     then bar.frame:SetParent(nil);     bar.frame:Hide()     end
        if bar.peakFrame then bar.peakFrame:SetParent(nil); bar.peakFrame:Hide() end
    end
    wipe(bars)
end

-- Build one horizontal bar for the given band index.
-- isRight = true  → bar grows leftward (right panel, mirrored)
-- isRight = false → bar grows rightward (left panel)
-- slotH = height of each band's slot; barH = rendered bar height within that slot
local function MakeBar(panel, bandIndex, isRight, slotH, barH)
    -- Centre the bar vertically within its slot; band 1 at bottom, band N at top
    local yOff = (bandIndex - 1) * slotH + math.floor((slotH - barH) / 2)

    -- Main bar (width animated each frame)
    local f = CreateFrame("Frame", nil, panel)
    f:SetSize(CFG.MIN_WIDTH, barH)
    if isRight then
        f:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -CFG.PADDING, yOff)
    else
        f:SetPoint("BOTTOMLEFT",  panel, "BOTTOMLEFT",   CFG.PADDING, yOff)
    end

    local tex = f:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetColorTexture(0.1, 0.55, 1.0, 0.92)

    -- Bright leading-edge highlight (4 px strip at the far end of the bar)
    local edge = f:CreateTexture(nil, "OVERLAY")
    edge:SetSize(4, barH)
    if isRight then
        edge:SetPoint("LEFT",  f, "LEFT",  0, 0)
    else
        edge:SetPoint("RIGHT", f, "RIGHT", 0, 0)
    end
    edge:SetColorTexture(1, 1, 1, 0.28)

    -- Peak indicator (2-px vertical strip, parented to panel so it stays put)
    local pf = CreateFrame("Frame", nil, panel)
    pf:SetSize(2, barH)
    pf:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", CFG.PADDING, yOff) -- updated each frame

    local ptex = pf:CreateTexture(nil, "ARTWORK")
    ptex:SetAllPoints()
    ptex:SetColorTexture(1, 1, 1, 0.85)

    return {
        frame     = f,
        tex       = tex,
        edge      = edge,
        peakFrame = pf,
        peakTex   = ptex,
        panel     = panel,
        isRight   = isRight,
        yOff      = yOff,
        barH      = barH,
        current   = 0,
    }
end

-- Rebuild all bars from scratch (called on load and when bar count changes)
local function BuildBars()
    DestroyBars(leftBars)
    DestroyBars(rightBars)

    -- Reset per-band state
    wipe(S.barState)
    wipe(S.bandEnergy)
    for i = 1, CFG.NUM_BARS do
        S.barState[i]   = {phase = (i - 1) * (math.pi * 2 / CFG.NUM_BARS), peak = 0, peakTimer = 0}
        S.bandEnergy[i] = 0
    end

    -- Distribute bars evenly across the full screen height.
    -- 82% of each slot is bar, 18% is the gap between bars.
    local panelH = math.floor(UIParent:GetHeight())
    local slotH  = math.floor(panelH / CFG.NUM_BARS)
    local barH   = math.max(6, math.floor(slotH * 0.82))

    ConfigurePanel(leftPanel,  "LEFT",  panelH)
    ConfigurePanel(rightPanel, "RIGHT", panelH)

    -- Create bars
    for i = 1, CFG.NUM_BARS do
        leftBars[i]  = MakeBar(leftPanel,  i, false, slotH, barH)
        rightBars[i] = MakeBar(rightPanel, i, true,  slotH, barH)
    end
end

-- ============================================================
-- Sound hooks → broadband bursts
-- ============================================================
-- UI sounds are predominantly mid/high range; avoid InjectAll which flattens
-- all bands to the same level and erases frequency variation.
hooksecurefunc("PlaySound",     function() InjectMid(0.12); InjectHigh(0.08) end)
hooksecurefunc("PlaySoundFile", function() InjectMid(0.10); InjectHigh(0.06) end)
if C_Sound and C_Sound.PlaySound then
    pcall(hooksecurefunc, C_Sound, "PlaySound", function() InjectMid(0.12); InjectHigh(0.08) end)
end

-- ============================================================
-- C_CombatAudioAlert → frequency-mapped live volumes
-- ============================================================
-- Each of the nine alert categories is assigned to a specific frequency range.
-- This drives the bars in a musically meaningful way during combat speech alerts.
local ALERT_MAP = {
    [0] = {0.00, 1.00},   -- General        → full spectrum
    [1] = {0.00, 0.30},   -- PlayerHealth   → deep bass  (danger feel)
    [2] = {0.10, 0.40},   -- TargetHealth   → low-mid
    [3] = {0.30, 0.65},   -- PlayerCast     → mids
    [4] = {0.30, 0.65},   -- TargetCast     → mids
    [5] = {0.50, 0.80},   -- PlayerResource1 → mid-high
    [6] = {0.50, 0.80},   -- PlayerResource2 → mid-high
    [7] = {0.00, 0.25},   -- PartyHealth    → bass
    [8] = {0.70, 1.00},   -- PlayerDebuffs  → treble
}

local function PollAlertVolumes()
    if not C_CombatAudioAlert then return end
    for cat = 0, 8 do
        local v = C_CombatAudioAlert.GetCategoryVolume(cat)
        S.alertEnergy[cat] = v and (v / 100.0) or 0
    end
end

local function ApplyAlertEnergy()
    for cat = 0, 8 do
        local e = S.alertEnergy[cat] or 0
        if e > 0 then
            local range = ALERT_MAP[cat]
            if range then InjectBands(range[1], range[2], e * 0.35) end
        end
    end
end

-- ============================================================
-- Animation: compute target amplitude for one band (0-1)
-- ============================================================
local function ComputeTarget(band)
    local bs = S.barState[band]
    local ff = FreqFrac(band)  -- 0 = bass, 1 = treble

    -- Bass oscillates slowly, treble quickly — matches real acoustic behaviour
    local freq = lerp(CFG.IDLE_FREQ_LO, CFG.IDLE_FREQ_HI, ff)
    if S.inCombat then freq = freq * 2.0 end

    -- Bass has a naturally higher resting amplitude than treble.
    -- At idle bass sits at ~IDLE_AMP_BASE; treble sits at ~45% of that.
    -- This creates a visible slope across the panel even with no events.
    local ampPeak = S.inCombat and CFG.IDLE_AMP_COMB or CFG.IDLE_AMP_BASE
    local bandAmp = ampPeak * lerp(1.0, 0.45, ff)

    -- Two offset sine waves give organic movement without total periodicity
    local w1 = (math.sin(S.elapsed * freq         + bs.phase)       * 0.5 + 0.5)
    local w2 = (math.sin(S.elapsed * freq * 1.618 + bs.phase * 2.3) * 0.5 + 0.5) * 0.40
    local wave = (w1 + w2) / 1.40 * bandAmp

    return clamp(wave + (S.bandEnergy[band] or 0), 0, 1)
end

-- ============================================================
-- Animation: update and render a full set of bars
-- ============================================================
local function UpdateBars(bars, dt)
    local r, g, b = GetColor()
    local lerpT   = clamp(CFG.LERP_SPEED * dt, 0, 1)

    for i, bar in ipairs(bars) do
        local bs  = S.barState[i]
        local tgt = ComputeTarget(i)

        bar.current = lerp(bar.current, tgt, lerpT)

        -- Peak hold then fall
        if bar.current >= bs.peak then
            bs.peak      = bar.current
            bs.peakTimer = 0
        else
            bs.peakTimer = bs.peakTimer + dt
            if bs.peakTimer > CFG.PEAK_HOLD then
                local fallT = (bs.peakTimer - CFG.PEAK_HOLD) * CFG.PEAK_FALL * dt
                bs.peak = lerp(bs.peak, bar.current, clamp(fallT, 0, 1))
            end
        end

        -- Apply bar width
        local bw = math.max(CFG.MIN_WIDTH, bar.current * CFG.MAX_WIDTH)
        bar.frame:SetWidth(bw)

        -- Colour: brightness scales with amplitude
        local bright = 0.50 + bar.current * 0.50
        bar.tex:SetColorTexture(r * bright, g * bright, b * bright, 0.92)
        bar.edge:SetColorTexture(1, 1, 1, bar.current * 0.35)

        -- Peak indicator positioned at peak width from the panel edge
        local pw = math.max(CFG.MIN_WIDTH, bs.peak * CFG.MAX_WIDTH)
        bar.peakFrame:ClearAllPoints()
        if bar.isRight then
            bar.peakFrame:SetPoint("BOTTOMRIGHT", bar.panel, "BOTTOMRIGHT",
                -(CFG.PADDING + pw - 2), bar.yOff)
        else
            bar.peakFrame:SetPoint("BOTTOMLEFT", bar.panel, "BOTTOMLEFT",
                CFG.PADDING + pw - 2, bar.yOff)
        end
        bar.peakTex:SetColorTexture(r, g, b, 0.90)
    end
end

-- ============================================================
-- Main update driver
-- ============================================================
local driver = CreateFrame("Frame", "WoWEQ_Driver", UIParent)
driver:SetScript("OnUpdate", function(_, dt)
    S.elapsed = S.elapsed + dt
    S.accumDt = S.accumDt + dt
    if S.accumDt < CFG.UPDATE_RATE then return end
    local tick = S.accumDt
    S.accumDt  = 0

    -- Decay injected band energy (faster in combat to keep response snappy)
    local decay = S.inCombat and (CFG.BAND_DECAY * 1.5) or CFG.BAND_DECAY
    for b = 1, CFG.NUM_BARS do
        S.bandEnergy[b] = math.max(0, (S.bandEnergy[b] or 0) - tick * decay)
    end

    UpdateBars(leftBars,  tick)
    UpdateBars(rightBars, tick)
end)

-- ============================================================
-- Game events
-- ============================================================
local events = CreateFrame("Frame", "WoWEQ_Events", UIParent)

events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("ENCOUNTER_START")
events:RegisterEvent("ENCOUNTER_END")
events:RegisterEvent("UNIT_SPELLCAST_START")
events:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
events:RegisterEvent("ZONE_CHANGED_NEW_AREA")
events:RegisterEvent("PLAYER_UPDATE_RESTING")

events:SetScript("OnEvent", function(_, event, ...)
    -- --------------------------------------------------------
    if event == "ADDON_LOADED" then
        if (...) ~= "WoWEQ" then return end
        WoWEQDB         = WoWEQDB or {}
        CFG.NUM_BARS    = WoWEQDB.numBars or 12
        BuildBars()
        leftPanel:Show()
        rightPanel:Show()

    -- --------------------------------------------------------
    elseif event == "PLAYER_LOGIN" then
        S.playerGUID = UnitGUID("player")

    -- --------------------------------------------------------
    elseif event == "PLAYER_ENTERING_WORLD" then
        S.playerGUID = UnitGUID("player")
        S.isResting  = IsResting() or false
        InjectAll(0.55)

    -- --------------------------------------------------------
    elseif event == "PLAYER_REGEN_DISABLED" then
        S.inCombat = true
        InjectAll(0.85)

    -- --------------------------------------------------------
    elseif event == "PLAYER_REGEN_ENABLED" then
        S.inCombat = false
        InjectAll(0.45)

    -- --------------------------------------------------------
    elseif event == "ENCOUNTER_START" then
        S.inBoss   = true
        S.inCombat = true
        InjectAll(1.00)

    -- --------------------------------------------------------
    elseif event == "ENCOUNTER_END" then
        S.inBoss = false
        InjectAll(0.60)

    -- --------------------------------------------------------
    elseif event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_SUCCEEDED" then
        if (...) == "player" then InjectMid(0.40) end

    -- --------------------------------------------------------
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        InjectAll(0.55)

    -- --------------------------------------------------------
    elseif event == "PLAYER_UPDATE_RESTING" then
        S.isResting = IsResting() or false
    end
end)

-- COMBAT_LOG_EVENT_UNFILTERED is protected in Midnight and cannot be registered
-- via RegisterEvent(). Use RegisterEventCallback() instead (added Patch 12.0.0).
local function OnCombatLog()
    local _, subEvent, _, srcGUID, _, _, _, dstGUID = CombatLogGetCurrentEventInfo()
    local pg = S.playerGUID
    if not pg then return end

    -- Player is the source of the action
    if srcGUID == pg then
        if    subEvent == "SWING_DAMAGE"           then InjectLow    (0.70)
        elseif subEvent == "SPELL_DAMAGE"
            or subEvent == "RANGE_DAMAGE"          then InjectMid    (0.65)
        elseif subEvent == "SPELL_PERIODIC_DAMAGE" then InjectLowMid (0.35)
        elseif subEvent == "SPELL_HEAL"            then InjectLowMid (0.45)
        elseif subEvent == "SPELL_PERIODIC_HEAL"   then InjectLowMid (0.25)
        elseif subEvent == "SPELL_CAST_SUCCESS"    then InjectMidHigh(0.40)
        elseif subEvent == "SPELL_AURA_APPLIED"    then InjectHigh   (0.30)
        end
    end

    -- Player is taking damage
    if dstGUID == pg then
        if    subEvent == "SWING_DAMAGE"           then InjectLow    (0.55)
        elseif subEvent == "SPELL_DAMAGE"
            or subEvent == "RANGE_DAMAGE"          then InjectMid    (0.50)
        elseif subEvent == "SPELL_PERIODIC_DAMAGE" then InjectLowMid (0.30)
        end
    end

    -- Deaths: full spectrum burst
    if subEvent == "UNIT_DIED" then
        InjectAll(dstGUID == pg and 1.00 or 0.55)
    end
end

events:RegisterEventCallback("COMBAT_LOG_EVENT_UNFILTERED", OnCombatLog)

-- ============================================================
-- Slash command:  /woweq [show|hide|bars N]
-- ============================================================
SLASH_WOWEQ1 = "/woweq"
SlashCmdList["WOWEQ"] = function(msg)
    local cmd, arg = strsplit(" ", strtrim(msg):lower(), 2)

    if cmd == "hide" then
        leftPanel:Hide(); rightPanel:Hide()
        print("|cff00ccffWoWEQ|r hidden.")

    elseif cmd == "show" then
        leftPanel:Show(); rightPanel:Show()
        print("|cff00ccffWoWEQ|r visible.")

    elseif cmd == "bars" then
        local n = tonumber(arg)
        if not n or n < 4 or n > 32 then
            print("|cff00ccffWoWEQ|r Usage: /woweq bars <4-32>")
            return
        end
        CFG.NUM_BARS        = n
        WoWEQDB             = WoWEQDB or {}
        WoWEQDB.numBars     = n
        BuildBars()
        print(string.format("|cff00ccffWoWEQ|r bars set to %d (saved).", n))

    else
        -- bare /woweq → toggle
        local vis = leftPanel:IsShown()
        leftPanel:SetShown(not vis)
        rightPanel:SetShown(not vis)
        print("|cff00ccffWoWEQ|r " .. (vis and "hidden." or "visible."))
    end
end

print("|cff00ccffWoWEQ|r v1.1.3 loaded  —  /woweq bars <4-32> | /woweq show|hide")
