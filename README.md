# WoWEQ

A World of Warcraft addon for Midnight (Patch 12.x) that displays an audio-reactive frequency equalizer on the left and right sides of your screen.

## Overview

WoWEQ renders two mirrored panels of horizontal bars — one on each side of the screen — that react in real time to in-game audio and combat activity. The bars are arranged as a frequency spectrum:

```
Panel edge
┌─────────────┐
│ ██████████  │  Treble  — debuffs, aura applications, high-energy events
│ ███████     │
│ ████████████│  Mids    — spellcasts, spell damage, resource alerts
│ ████        │
│ █████████   │  Bass    — melee hits, health alerts, slow ambient pulse
└─────────────┘
```

The left and right panels are mirrored. Each bar has a bright leading-edge highlight and a peak indicator that holds briefly before falling back.

## Why no real FFT?

The WoW addon API does not expose raw audio buffer data, waveforms, or frequency spectrum analysis — the sandbox intentionally prevents it. WoWEQ instead drives the visualizer using the signals that *are* available:

| Source | How it is used |
|---|---|
| `C_CombatAudioAlert.GetCategoryVolume(0–8)` | Nine live audio category volumes polled every tick, each mapped to its appropriate frequency range |
| `hooksecurefunc` on `PlaySound` / `PlaySoundFile` / `C_Sound.PlaySound` | Broadband energy burst whenever any sound fires |
| `COMBAT_LOG_EVENT_UNFILTERED` | Fine-grained per-action band injection (melee → bass, spells → mids, debuffs → treble) |
| Game events | Coarser state bursts for combat transitions, boss encounters, zone changes, and spellcasts |

## Frequency band mapping

### Combat log actions

| Action | Frequency range injected |
|---|---|
| Melee hit (dealing) | Bass (0–35%) |
| Melee hit (taking) | Bass (0–35%), lower intensity |
| Spell / ranged damage (dealing) | Mids (30–70%) |
| Spell / ranged damage (taking) | Mids (30–70%), lower intensity |
| DoT damage | Low-mid (10–55%) |
| Heal | Low-mid (10–55%) |
| HoT | Low-mid (10–55%), lower intensity |
| Spell cast success | Mid-high (45–90%) |
| Aura / debuff applied | Treble (65–100%) |
| Unit death (other) | Full spectrum burst |
| Player death | Full spectrum burst, maximum intensity |

### Combat audio alert categories

| Category | Frequency range |
|---|---|
| General (0) | Full spectrum |
| Player Health (1) | Deep bass |
| Target Health (2) | Low-mid |
| Player Cast (3) | Mids |
| Target Cast (4) | Mids |
| Player Resource 1 (5) | Mid-high |
| Player Resource 2 (6) | Mid-high |
| Party Health (7) | Bass |
| Player Debuffs (8) | Treble |

## Color themes

The panel color changes automatically based on your current game state:

| State | Color |
|---|---|
| Out of combat | Blue |
| In combat | Orange |
| Boss encounter | Purple |
| Resting (inn / city) | Green |

## Idle animation

Even without combat activity, the bars animate with a gentle ambient wave. Bass bands oscillate slowly and treble bands oscillate quickly, matching the physical behavior of real frequency bands. In combat the oscillation speed and amplitude increase.

## Installation

1. Copy the `WoWEQ` folder into your WoW addons directory:
   ```
   World of Warcraft\_retail_\Interface\AddOns\WoWEQ\
   ```
2. Launch WoW and enable **WoWEQ** on the character select screen.

## Slash commands

| Command | Effect |
|---|---|
| `/woweq` | Toggle both panels on / off |
| `/woweq show` | Show panels |
| `/woweq hide` | Hide panels |
| `/woweq bars <N>` | Set the number of frequency bars (4–32). Saved across sessions. Default: 12 |

The bar count is persisted in `WoWEQDB` (SavedVariables) and survives reloads and restarts. Changing it rebuilds the panels immediately with no reload required.

## Files

| File | Purpose |
|---|---|
| `WoWEQ.toc` | Addon manifest — interface version, title, SavedVariables declaration |
| `WoWEQ.lua` | All addon logic: panels, bars, signal polling, animation, events, slash command |

## Compatibility

- **WoW Midnight** — Patch 12.0.x (Interface 120001+)
- No external library dependencies
- No texture assets required (uses built-in UI textures)
