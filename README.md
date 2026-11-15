# RNGFix 2

[![RNGFix Demo Video](https://i.imgur.com/YYm16Qh.png)](https://www.youtube.com/watch?v=PlMjHAQ90G8)

A [SourceMod](https://www.sourcemod.net/about.php) plugin for CS:S and CS:GO that fixes physics bugs in bhop and surf that appear to happen at random. Nothing it does is impossible otherwise; it just stops luck from mattering.

This is a fork of [RNGFix](https://github.com/jason-e/rngfix) by rio. All credit for the original plugin goes to him.

## What's new in 2.0

- **Subtick fixes** (on by default): the part of a tick that fixes, stairs and teleports would otherwise throw away is given back, so the result no longer depends on where in the tick contact happened. `rngfix_subtick 0` restores upstream timing.
- **CS:GO ducked hull** is 54 units, not 64, so the stair fix no longer snaps ducked players upwards in grates and other 64-unit gaps.
- **Safer fixes:** rewinds are hull-traced before moving the player, predictions that start in solid are ignored, the stair fix needs a real wall, and the duck-tick origin is handled correctly.
- **Ordered telehop** (`rngfix_telehop 2`, opt-in), **bots skipped** by default, `sm_rngfix_stats`, and per-map surf detection (`rngfix_surfmap`).
- Smaller fixes: air speed cap from `sv_air_max_wishspeed`, trigger bookkeeping, and the remaining movement offsets moved to gamedata.

Details are in [tech.md](tech.md).

## Installation

Download the [latest release](https://github.com/cawnr912/rngfix-2/releases/latest) and extract it into your server's `csgo/` or `cstrike/` folder. Always update `rngfix.smx` and `rngfix.games.txt` together.

**Requirements:** SourceMod 1.10 build 6326 or newer, and [DHooks](https://forums.alliedmods.net/showthread.php?t=180114). On CS:GO, [Movement Unlocker](https://forums.alliedmods.net/showthread.php?t=255298) is needed for sliding (surf and the stair fix). Remove Slopefix, since RNGFix replaces it.

## Fixes

- **Downhill inclines:** you always get boosted when landing on a downhill slope (what Slopefix did, without its double boosts on `trigger_push` slopes).
- **Uphill inclines:** you never randomly lose speed when jumping up a slope, as long as keeping it was possible.
- **Trigger jumping:** you can't jump on thin triggers (boosters, teleports) without activating them.
- **Telehops:** you can't hit the wall or floor behind a teleport in the same tick you touch it.
- **Edge bugs:** landing on the very edge of a platform at speed still lets you jump, and still activates triggers there.
- **Stair sliding** (surf maps only): hitting the face of a step while landing on stairs at speed still lets you slide up them.

## Settings

Set these in `cfg/sourcemod/plugin.rngfix.cfg`.

| Cvar | Default | Description |
|---|---|---|
| `rngfix_downhill` | `1` | Downhill fix. |
| `rngfix_uphill` | `1` | Uphill fix. `-1` also normalizes effects in the player's favour (not recommended). |
| `rngfix_triggerjump` | `1` | Trigger jump fix. |
| `rngfix_telehop` | `1` | Telehop fix. `2` only restores speed if the player reached the teleport before the collision. |
| `rngfix_edge` | `1` | Edge bug fix. |
| `rngfix_stairs` | `1` | Stair slide fix. |
| `rngfix_subtick` | `1` | Subtick fixes. `0` = upstream timing. |
| `rngfix_subtick_parts` | `15` | Troubleshooting: which subtick parts run (sum of `1` time credit, `2` stair leftover, `4` teleport leftover, `8` multi-surface edge prediction). |
| `rngfix_bots` | `0` | Apply fixes to bots too. Off so walking replay bots aren't nudged. |
| `rngfix_surfmap` | `-1` | Is this a surf map? `-1` = name starts with `surf_`, `0` = no, `1` = yes. Set per map, and reset to `-1` in your server config. |
| `rngfix_useoldslopefixlogic` | `0` | Old Slopefix behaviour, for maps that rely on it. Set per map. |
| `rngfix_debug` | `0` | `1` = debug messages (including why a fix was skipped), `2` = also lasers. |

**Command:** `sm_rngfix_stats` shows how often each fix has fired for you, and some server-wide counters. `sm_rngfix_stats reset` zeroes them.

## License

GPLv3, as upstream. See [LICENSE](LICENSE).
