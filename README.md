# Katana Stays Sheathed

Two scripts that keep the katana in its sheath after using the bow and during wall runs, for Onimusha: Way of the Sword. Single-player only.
Bow Keeps Sheathed 3.1 | Wall Run Keeps Sheathed 1.3 | Tested in game on 2026-11-13 and 2026-11-15 (see Status) | Status: working

> Unofficial fan-made modification, not affiliated with or endorsed by CAPCOM Co., Ltd. No Capcom game files or assets are included; a legitimate copy of the game is required.

Published on Nexus Mods as "Katana Stays Sheathed - Bow and Wall Run": <https://www.nexusmods.com/onimushawayofthesword/mods/401>

## The problem

Lowering the bow puts Musashi into the katana stance and plays a draw animation, even if the sword was sheathed before he raised the bow. A wall run draws it as well. If you like to walk around with the sword sheathed, you have to sheathe it again every time.

## What I built

Two REFramework Lua scripts (997 and 943 lines). Each remembers whether the katana was out before the action started and, if it was not, keeps it sheathed. A guard or parry during a wall run still draws it, and then it stays out. They change: which action the game switches to when the bow is lowered or the wall run ends, and whether the katana's own "show me" check runs during a wall run. No game files are changed.

## How it works

**Bow Keeps Sheathed**
- When a bow action starts, the script notes whether the katana was drawn.
- The bow-lowering action itself contains the draw animation. If the katana was sheathed, the request for that action is replaced by the sheathed idle action, so the draw never plays.
- Requests for calm katana-stance actions (idle, walk, run, dash) during the bow are replaced by their sheathed-stance twins.
- Before it redirects anything, the script reads the game's action table and verifies the entries it relies on.
- Fallbacks, in order, if the katana stance is reached anyway: a direct switch to the sheathed twin, then a normal sheathe request.

**Wall Run Keeps Sheathed**
- During a wall run the game never calls "weapon on" for the katana; its visibility follows the motion itself. So the script skips the katana's own per-frame on/off check for the length of the run and answers "off" to its joint-scale test.
- The guard command ends that hold, so guarding against projectiles on a wall works as usual.
- If the katana was never drawn, the landing goes to the sheathed stance.

```text
package/reframework/autorun/
  bow_keeps_sheathed.lua
  wallrun_keeps_sheathed.lua
tests/
  run_bow_keeps_sheathed_test.lua       offline test, 69 checks
  run_wallrun_keeps_sheathed_test.lua   offline test, 51 checks
```

## Requirements

| Requirement | Version | Link |
|---|---|---|
| Onimusha: Way of the Sword | the PC version current in November 2026; exact build not recorded | |
| REFramework | the build for this game current in November 2026; exact build not recorded | [praydog/REFramework](https://github.com/praydog/REFramework) |

REFramework is not bundled. Install it first from its own page.

## Install

1. Install REFramework for the game.
2. Copy the `reframework` folder from `package/` into the game folder, so that `reframework\autorun\bow_keeps_sheathed.lua` exists. Copy only one of the two scripts if you want only one.
3. Start the game. Open the REFramework menu (Insert) and look under "Script Generated UI": each script has its own entry with an "Enabled" box.

## Uninstall / roll back

1. Close the game.
2. Delete `reframework\autorun\bow_keeps_sheathed.lua` and `reframework\autorun\wallrun_keeps_sheathed.lua`.
3. Optional: delete their settings files `reframework\data\bow_keeps_sheathed.json` and `reframework\data\wallrun_keeps_sheathed.json`.
4. Saves are not affected. REFramework is left alone. To switch a script off without removing it, untick "Enabled" in its menu.

## Configuration

REFramework menu > Script Generated UI. Settings are saved to the JSON files named above.

Bow Keeps Sheathed:

| Option | Default | Meaning |
|---|---|---|
| Enabled | on | |
| Go straight to the sheathed stance when the bow ends | on | The main method |
| Bow-lowering animation: play this long | 0 s | 0 = skip it; up to 1.5 s |
| Stop it the moment the katana starts to come out | on | Only matters when the animation plays |
| Leave the game alone while enemies are in battle mode | on | |
| Grace window after the bow | 2.5 s | Time in which an automatic draw is refused |
| Debug lines in `re2_framework_log.txt` | off | |

Wall Run Keeps Sheathed: "Enabled", three boxes for the ways the katana is kept sheathed (all on), a fallback, "Start of the run: no draw gesture", "Guard / parry key draws at once", "Land in the sheathed stance when the katana was never drawn", "... but not while enemies are in battle mode", and the debug switch (off).

## Status

| Script | Version | In-game result |
|---|---|---|
| Bow Keeps Sheathed | 3.0 | Worked: 8 bow uses from the sheathed stance all skipped the draw; 1 use with the katana out stayed vanilla (2026-11-13). |
| Bow Keeps Sheathed | 3.1 | Not re-tested in game. Differences to 3.0: debug logging off by default, the katana is also recognised by its class name, weapon sampling only while the bow is lowered. Passes the offline test. |
| Wall Run Keeps Sheathed | 1.3 | Confirmed working in game (2026-11-15): the katana stays sheathed for the whole wall run, the guard / parry key draws it and it stays out, runs where it was never drawn land in the sheathed stance, runs that start with the katana out are vanilla. |

## Compatibility

| Item | Status | Notes |
|---|---|---|
| Other scripts that change the player's action requests | may conflict | Both would redirect the same requests. |
| A game update | unknown | The bow script verifies its action table against the running game and does not redirect when that check fails. |

## Known issues

- With the default settings the bow script jumps from the shot pose straight to the sheathed idle pose. Use "play this long" if you prefer to see part of the lowering animation.
- Not seen in a log yet: the one-handed quick shot, and raising the bow without shooting.
- The bow script still contains one hook that never fires in this game; it does nothing and can be removed.

## Engineering notes

**Problem.** The katana is drawn after every bow use.

**Finding where to act.** The game's managed code has no documentation, so a small type-dump tool listed the classes and methods, and logging hooks showed which of them run for the player. Three facts came out of the logs: the "action enter" callback never fires for the player (so the script polls the current action once per frame instead); the bow-lowering action itself contains the draw animation; and the request to switch to the sheathed idle action is accepted on the next frame.

**Three attempts, each tested in game.**
- Version 1 sheathed the katana about 0.4 seconds after it came out. Result: a visible draw followed by a sheathe. Not acceptable.
- Version 2 redirected the action request. Result: the animation still played, then the sword went back. Cause, found in the log: the game's two-integer action methods take (index, category), not (category, index), so the redirect table never matched.
- Version 3 reads actions by their id, verifies its table against the running game before use, and replaces the request for the bow-lowering action. Result: 8 of 8 bow uses from the sheathed stance skipped the draw, and none of the fallbacks was needed.

**Wall run.** Putting the katana back once per frame had no visible effect, because the game switches it on every frame from the motion data. The fix moved one level down, to the katana's own per-frame check.

**Tests without the game.** Each script has a test harness that replaces the game's action controller with a stub and plays through scenarios (69 checks for the bow, 51 for the wall run). They run in CI on every push.

**Rollback.** Untick "Enabled" in the menu, or delete the script file.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## Credits and licence

Runs on REFramework by praydog, which is not included here.

MIT, see [LICENSE](LICENSE). The licence covers my code only. The game, its names and its assets belong to their owners and are not included.

Built with AI assistance (Claude); designed, tested and maintained by me.
