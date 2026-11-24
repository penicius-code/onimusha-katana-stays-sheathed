# Changelog

## Wall Run Keeps Sheathed

### 1.3 - 2026-11-15
- Debug logging off by default. Otherwise the same as 1.2.
- Confirmed working in game.

### 1.2 - 2026-11-15
- Fixed: the katana still appeared during the run. The game switches it on every frame from the motion data, so the script now skips the katana's own per-frame on/off check during the run and answers "off" to its joint-scale test.
- Confirmed working in game.

### 1.1 - 2026-11-15
- The katana object is looked up ahead of time, so the hold can start.
- Landing in the sheathed stance when the katana was never drawn. Worked in game.
- Known problem in this version: putting the katana back once per frame had no visible effect.

### 1.0 - 2026-11-15
- Hooks and state tracking. Start, actions and end of a wall run were detected correctly in game, but the katana object was not found, so nothing was held.

## Bow Keeps Sheathed

### 3.1 - 2026-11-13
- Debug logging off by default.
- The katana is also recognised by its class name.
- The weapon state is sampled only while the bow is lowered.
- Not re-tested in game; passes the offline test (69 checks).

### 3.0 - 2026-11-13
- Fixed: the draw animation still played. Actions are now read by their id and the action table is verified against the running game before use. The request for the bow-lowering action is replaced by the sheathed idle action.
- Confirmed in game: 8 bow uses from the sheathed stance skipped the draw; 1 use with the katana out stayed vanilla.

### 2.0 - 2026-11-13
- Redirected the action request instead of sheathing afterwards.
- Did not work as intended: the animation played, then the sword went back. Cause: the redirect table was built with the two numbers of an action in the wrong order.

### 1.0 - 2026-11-13
- Sheathed the katana about 0.4 seconds after it came out. Rejected: the draw and the sheathe were both visible.
