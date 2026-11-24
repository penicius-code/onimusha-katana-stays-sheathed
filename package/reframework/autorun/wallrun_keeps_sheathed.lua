-- Wall Run Keeps Sheathed v1.3 (2026-11-15)
-- v1.2 confirmed in game: skipping app.Gm800.checkWeaponOn for the katana
-- during the run keeps it sheathed (checkJointScaleY and setWeaponOn are never called for it),
-- the GUARD command draws it and it stays out, the landing is redirected to the sheathed twin.
-- v1.3 = v1.2 with debug logging off by default.
-- v1.1 in game: katana found, hold started, landing in the sheathed stance works.
-- But the game never calls setWeaponOn(true) for the katana: the katana object switches itself
-- on every frame (also with the start motion that has no weapon track), so the on/off comes from
-- the motion itself (joint scale, app.Gm800.checkWeaponOn / checkJointScaleY). Putting it back
-- once per frame had no visible effect. v1.2 therefore stops the katana's own per-frame check
-- during the hold (hold_check) and answers "off" to its joint-scale test (hold_scale).
-- v1.0 in game: all hooks installed, wall-run start / actions / end are seen correctly, but the
-- katana object was not found from inside the detailEnter hook, so nothing was held. v1.1 looks
-- it up ahead of time in the per-frame tick (several ways) and also adopts it from setWeaponOn.
-- Musashi draws the katana by himself as soon as a wall run starts. With this script the
-- katana stays in the sheath for the whole wall run when it was sheathed before the run.
-- The guard / parry key draws it (the game's own wall-run guard then works as usual), and
-- from then on it stays out for the rest of the run.
--
-- How (1b is the method that works in game; 1, 1c, 2, 3 are unused fallbacks):
--   1. HOLD: app.Gm800.setWeaponOn(Boolean, Int32, Int32, Int32) puts a weapon object into the
--      hand or back to its sheath. While a wall run is held sheathed, every "on" call for the
--      player's katana (app.Gm800_000) is turned into an "off" call. The wall-run motions
--      themselves are katana-stance motions and keep playing, only the katana stays put.
--   2. ENFORCE (fallback): if the katana still shows up in the hand, it is put back with the
--      same method once per frame. The log then says that the hook alone was not enough.
--   3. TRACK SKIP (option, off): do not let the motion's weapon track (WEAPON_ON) reach
--      app.cPlayerCharacterEntity.evWeaponTrack during the hold.
--   4. START MOTION: app.PlayerOneHandedAction.cWallRunStart has one start motion for "katana
--      out" and one for "katana sheathed" (the second one presumably contains the draw). While
--      holding, the "katana out" one is used so no draw gesture plays.
--   5. GUARD: base action cWallRunGuard / sub actions cWallRunBlock, cWallRunGuardHit, or the
--      guard / parry key itself, end the hold. The katana comes out and stays out.
--   6. LANDING: when the run ends still sheathed, the idle / walk / run / dash / land action that
--      follows is swapped for its sheathed-stance twin (same trick as Bow Keeps Sheathed).
--
-- Proven in game by Bow Keeps Sheathed and reused here: actions are followed by polling once per
-- frame (ace.cActionController.callActionEnter never fires), action-level detailEnter hooks do
-- fire, (Int32, Int32) action methods take (index, category), ace.ACTION_ID arrives as a pointer.
--
-- Menu: Insert -> Script Generated UI -> Wall Run Keeps Sheathed
-- Settings: reframework/data/wallrun_keeps_sheathed.json
-- Debug lines go to re2_framework_log.txt with the prefix [WallRunKeepsSheathed].

if _G.wallrun_keeps_sheathed_loaded then return end
_G.wallrun_keeps_sheathed_loaded = true

local CONFIG_FILE = "wallrun_keeps_sheathed.json"
local TAG = "[WallRunKeepsSheathed] "
local VERSION = "1.3"

local cfg = {
    enabled = true,
    hold_hook = true,            -- 1. turn the katana's "on" calls into "off" calls during the hold
    hold_check = true,           -- 1b. skip the katana's own per-frame on/off check during the hold
    hold_scale = true,           -- 1c. answer "off" to the katana's joint-scale test during the hold
    enforce = true,              -- 2. put the katana back when it shows up in the hand anyway
    skip_weapon_track = false,   -- 3. swallow the motion's WEAPON_ON track during the hold
    swap_start_motion = true,    -- 4. play the start motion without the draw gesture
    draw_on_key = true,          -- 5. the guard / parry key itself ends the hold (not only the guard action)
    stay_sheathed_after = true,  -- 6. land in the sheathed stance when the katana was never drawn
    respect_combat = true,       -- 6. ... but not while enemies are in battle mode
    debug = false,               -- write transitions and decisions to the REFramework log
}

local SIG_SET_ON = "setWeaponOn(System.Boolean, System.Int32, System.Int32, System.Int32)"
local CMD_PARRY, CMD_GUARD = 2, 16

-------------------------------------------------------------------------------
-- small helpers
-------------------------------------------------------------------------------
local function safe(fn, ...)
    local ok, v = pcall(fn, ...)
    if ok then return v end
    return nil
end
local function call(obj, name, ...)
    if obj == nil then return nil end
    local ok, v = pcall(obj.call, obj, name, ...)
    if ok then return v end
    return nil
end
local function field(obj, name)
    if obj == nil then return nil end
    local ok, v = pcall(obj.get_field, obj, name)
    if ok then return v end
    return nil
end
local function type_name(obj)
    if obj == nil then return nil end
    local ok, v = pcall(function() return obj:get_type_definition():get_full_name() end)
    if ok then return v end
    return nil
end
local function addr(obj)
    if obj == nil then return 0 end
    local ok, v = pcall(obj.get_address, obj)
    if ok and v then return v end
    return 0
end
local function now() return os.clock() end
local function short(name)
    if name == nil then return "nil" end
    return (tostring(name):gsub("^app%.Player", ""))
end
local function int32(v)   -- raw register value -> signed 32 bit integer
    if type(v) ~= "number" then return nil end
    v = v & 0xFFFFFFFF
    if v >= 0x80000000 then v = v - 0x100000000 end
    return v
end

local function load_cfg()
    local saved = safe(json.load_file, CONFIG_FILE)
    if type(saved) ~= "table" then return end
    for k, v in pairs(cfg) do
        if type(saved[k]) == type(v) then cfg[k] = saved[k] end
    end
end
local function save_cfg()
    pcall(json.dump_file, CONFIG_FILE, cfg, 2)
end
load_cfg()

-------------------------------------------------------------------------------
-- event log (ring buffer shown in the UI + optional REFramework log)
-------------------------------------------------------------------------------
local events, EVENTS_MAX = {}, 80
local function note(msg)
    local line = string.format("%8.2f  %s", now(), msg)
    events[#events + 1] = line
    if #events > EVENTS_MAX then table.remove(events, 1) end
    if cfg.debug and log and log.info then pcall(log.info, TAG .. msg) end
end
local status = { install = "not installed" }

local storage_ok = thread ~= nil and thread.get_hook_storage ~= nil
local plain_storage = {}
local function hook_storage()
    if storage_ok then return thread.get_hook_storage() end
    return plain_storage
end

-------------------------------------------------------------------------------
-- player lookup (addresses are cached; objects only for the current tick)
-------------------------------------------------------------------------------
local P = {
    base_ctrl = 0, character_addr = 0, entity_addr = 0,
    resolved_at = -100, last_base_action = nil, last_sub_action = nil, cache = nil,
}

local function resolve_player()
    P.resolved_at = now()
    P.cache = nil
    local manager = safe(sdk.get_managed_singleton, "app.PlayerManager")
    local info = call(manager, "getControllingPlayerInfo")
    if info == nil then return nil end
    local character = field(info, "<Character>k__BackingField")
    local entity = field(info, "<CharacterEntity>k__BackingField")
    if character == nil or entity == nil then return nil end
    if type_name(character) ~= "app.PlayerCharacter" then return nil end
    local base = call(character, "get_BaseActionController")
    local sub = call(character, "get_SubActionController")
    local character_addr = addr(character)
    if character_addr ~= P.character_addr then
        -- new player object (first resolve, respawn, area change): seed the action names
        P.last_base_action = type_name(call(character, "get_BaseCurrentAction"))
        P.last_sub_action = type_name(call(character, "get_SubCurrentAction"))
        P.changed = P.character_addr ~= 0
    end
    P.character_addr = character_addr
    P.entity_addr = addr(entity)
    P.base_ctrl = addr(base)
    P.cache = { info = info, character = character, entity = entity, base = base, sub = sub }
    return P.cache
end
local function player()
    if P.cache ~= nil and now() - P.resolved_at < 0.004 then return P.cache end
    return resolve_player()
end

local function in_battle()
    local enemies = safe(sdk.get_managed_singleton, "app.EnemyManager")
    return call(enemies, "isCheckBattleMode") == true
end

-------------------------------------------------------------------------------
-- action classification
-------------------------------------------------------------------------------
local function is_wallrun(name) return name ~= nil and name:find(".cWallRun", 1, true) ~= nil end
local function is_guard(name)
    return name ~= nil and (name:find(".cWallRunGuard", 1, true) ~= nil or name:find(".cWallRunBlock", 1, true) ~= nil)
end
local function is_basic(name) return name ~= nil and name:find("^app%.PlayerBasicAction%.") ~= nil end
local function is_onehanded(name) return name ~= nil and name:find("^app%.PlayerOneHanded") ~= nil end

-------------------------------------------------------------------------------
-- action table: ACTION_ID (category, index) <-> action class name (base controller)
-------------------------------------------------------------------------------
local T_ACTION_ID = safe(sdk.find_type_definition, "ace.ACTION_ID")
local A = { ctrl = 0, by_name = {}, by_id = {}, count = 0, tried_at = -100, status = "not read yet", verified = false }
local function id_key(c, i) return c * 65536 + i end

local function read_id(vt)
    local c, i = field(vt, "_Category"), field(vt, "_Index")
    if type(c) == "number" and type(i) == "number" then return c, i end
    return nil
end

local function build_actions(ctrl)
    local a = addr(ctrl)
    if a == 0 then return false end
    if A.ctrl == a and (A.count > 0 or now() - A.tried_at < 5.0) then return A.count > 0 end
    A.ctrl, A.by_name, A.by_id, A.count, A.tried_at, A.verified = a, {}, {}, 0, now(), false
    local ncat = call(field(ctrl, "_ActionList"), "get_Count")
    if type(ncat) ~= "number" or ncat < 1 or ncat > 64 then
        A.status = "action list not readable"
        note("action table: " .. A.status)
        return false
    end
    -- the (Int32, Int32) overload takes (index, category); prefer the ACTION_ID overload
    local vt = call(ctrl, "get_CurrentActionID")
    local by_struct = vt ~= nil and pcall(function() vt:set_field("_Category", 0); vt:set_field("_Index", 0) end)
    local function get_action(c, i)
        if by_struct then
            vt:set_field("_Category", c)
            vt:set_field("_Index", i)
            return call(ctrl, "getAction(ace.ACTION_ID)", vt)
        end
        return call(ctrl, "getAction(System.Int32, System.Int32)", i, c)
    end
    for c = 0, ncat - 1 do
        local n = call(ctrl, "getActionNum", c)
        if type(n) == "number" and n > 0 and n < 4096 then
            for i = 0, n - 1 do
                local name = type_name(safe(get_action, c, i))
                if name ~= nil then
                    A.by_id[id_key(c, i)] = name
                    if A.by_name[name] == nil then A.by_name[name] = { c = c, i = i } end
                    A.count = A.count + 1
                end
            end
        end
    end
    local cc, ci = read_id(call(ctrl, "get_CurrentActionID"))
    local cur = type_name(call(ctrl, "get_CurrentAction"))
    A.verified = cc ~= nil and cur ~= nil and A.by_id[id_key(cc, ci)] == cur
    A.status = string.format("%d actions in %d categories, %s", A.count, ncat, A.verified and "verified" or "NOT verified")
    note(string.format("action table: %s  [current %s id=%s,%s]", A.status, short(cur), tostring(cc), tostring(ci)))
    return A.count > 0
end

-- sheathed-stance twin of a calm katana-stance action (idle / walk / run / dash / land family), or nil
local function basic_twin(name)
    if name == nil then return nil end
    local s = name:match("^app%.PlayerOneHandedAction%.(c[%w_]+)$")
    if s == nil then return nil end
    if not (s == "cIdle" or s == "cFallReturnToIdle" or s:find("^cWalk") or s:find("^cRun") or s:find("^cDash")
        or s:find("^cLand")) then return nil end
    local target = "app.PlayerBasicAction." .. s
    if A.by_name[target] ~= nil then return target end
    return nil
end

-------------------------------------------------------------------------------
-- the katana object
-------------------------------------------------------------------------------
local function list_len(o)
    local n = call(o, "get_Count")
    if type(n) == "number" then return n, "list" end
    n = o and safe(function() return o:get_size() end)
    if type(n) == "number" then return n, "array" end
    return nil
end
local function list_at(o, i, kind)
    if kind == "list" then return call(o, "get_Item", i) end
    return safe(function() return o:get_element(i) end)
end
-- the player's katana (app.Gm800_000). Tried in this order: the weapon supporter's data list,
-- its equip list, its lookup by weapon type. Returns object, trace.
local SWORD_TYPE = safe(function() return sdk.find_type_definition("app.WeaponDef.TYPE"):get_field("SWORD"):get_data(nil) end)
local function find_katana(p)
    local trace = {}
    local ws = call(p.entity, "get_Weapon")
    trace[#trace + 1] = "supporter=" .. tostring(type_name(ws))
    local first = nil
    local function scan(label, list, unwrap)
        local n, kind = list_len(list)
        trace[#trace + 1] = label .. "=" .. tostring(n)
        if n == nil then return nil end
        for k = 0, math.min(n, 24) - 1 do
            local g = list_at(list, k, kind)
            if unwrap then g = call(g, "get_WeaponGimmick") end
            if g ~= nil then
                if type_name(g) == "app.Gm800_000" then return g end
                first = first or g
            end
        end
        return nil
    end
    local g = scan("dataList", call(ws, "get_WeaponDataList"), true)
        or scan("dataField", field(ws, "_WeaponDataList"), true)
        or scan("equipList", call(ws, "getWeaponGimmickEquipList"), false)
    if g == nil and SWORD_TYPE ~= nil then
        g = call(ws, "getWeaponGimmick(app.WeaponDef.TYPE)", SWORD_TYPE)
        trace[#trace + 1] = "byType=" .. tostring(type_name(g))
    end
    g = g or first
    trace[#trace + 1] = "-> " .. tostring(type_name(g))
    return g, table.concat(trace, " ")
end
-- looked up ahead of time in the tick (the lookup failed from inside a hook in v1.0)
local K = { obj = nil, addr = 0, character = 0, tried_at = -100, trace = "not tried" }
local function katana_cached(p, force)
    if K.obj ~= nil and K.character == P.character_addr then return K.obj end
    if not force and now() - K.tried_at < 2.0 then return nil end
    K.tried_at = now()
    local g, trace = find_katana(p)
    local changed = trace ~= K.trace
    K.obj, K.addr, K.character, K.trace = g, addr(g), P.character_addr, trace
    if g == nil then K.character = 0 end
    if changed then note("katana lookup: " .. trace) end
    return g
end
local function gm800_static(getter)
    return safe(function() return sdk.find_type_definition("app.Gm800"):get_method(getter):call(nil) end)
end

-------------------------------------------------------------------------------
-- state
-------------------------------------------------------------------------------
-- idle  : no wall run
-- run   : a wall-run action is running
-- after : the run ended still sheathed and the sheathed twin of the follow-up action was requested
-- S.hold: the katana is being kept in the sheath (only ever true in "run" / "after")
local S = {
    state = "idle", hold = false, drawn = false, was_out = nil, confirmed = false,
    started_at = 0, after_until = 0, action_at = 0,
    katana = nil, katana_addr = 0, off_list = nil, off_layer = nil,
    on_list = nil, on_layer = nil, on_hokan = nil, sword_prev = nil,
    calls = 0, forced = 0, enforced = 0, track_skips = 0, redirects = 0, swapped = false,
    seen = {}, seen_n = 0, combat_noted = false,
    runs = 0, held_runs = 0, guard_draws = 0, sheathed_landings = 0,
}
-- pending "is the katana back in the hand?" check after a hold ended
local R = { at = nil, katana = nil, list = nil, layer = nil, hokan = nil, why = nil }

local function reset_run()
    S.state, S.hold, S.drawn, S.was_out, S.confirmed = "idle", false, false, nil, false
    S.katana, S.katana_addr, S.off_list, S.off_layer = nil, 0, nil, nil
    S.on_list, S.on_layer, S.on_hokan, S.sword_prev = nil, nil, nil, nil
    S.calls, S.forced, S.enforced, S.track_skips, S.redirects, S.swapped = 0, 0, 0, 0, 0, false
    S.seen, S.seen_n, S.combat_noted, S.any_calls = {}, 0, false, 0
    S.check_calls, S.check_skips, S.scale_calls, S.scale_forced = 0, 0, 0, 0
end

local function summary()
    return string.format(" [checkWeaponOn calls=%d skipped=%d, checkJointScaleY calls=%d forcedOff=%d, setWeaponOn calls=%d forced=%d, enforced=%d, trackSkips=%d, redirects=%d, startSwap=%s]",
        S.check_calls or 0, S.check_skips or 0, S.scale_calls or 0, S.scale_forced or 0,
        S.calls, S.forced, S.enforced, S.track_skips, S.redirects, tostring(S.swapped))
end

-- one log line per distinct thing during a run
local function diag(key, msg)
    if not cfg.debug or S.seen_n >= 60 or S.seen[key] then return end
    S.seen[key] = true
    S.seen_n = S.seen_n + 1
    note(msg .. string.format("  (during %s +%.2fs)", short(P.last_base_action), now() - S.action_at))
end

-- Stop holding. The game normally puts the katana back into the hand by itself; R checks that.
local function end_hold(why)
    if not S.hold then return end
    S.hold = false
    R.at, R.katana, R.why = now() + 0.15, S.katana, why
    R.list, R.layer, R.hokan = S.on_list, S.on_layer, S.on_hokan
end

local function draw(why)
    if not S.hold then return end
    S.drawn = true
    S.guard_draws = S.guard_draws + 1
    note("guard -> katana may come out and stays out (" .. why .. ")" .. summary())
    end_hold("guard")
end

local function begin_run(name, source, prev)
    local p = player()
    if p == nil then return end
    build_actions(p.base)
    reset_run()
    S.state, S.started_at, S.action_at = "run", now(), now()
    S.runs = S.runs + 1
    S.katana = katana_cached(p, true)
    S.katana_addr = addr(S.katana)
    local on = call(S.katana, "get_IsWeaponOn")
    local was_out, how
    if is_basic(name) then was_out, how = false, "wall run entered from the sheathed stance"
    elseif source == "hook" and on ~= nil then was_out, how = (on == true), "katana object at the moment the wall run started"
    elseif is_basic(prev) then was_out, how = false, "previous action was sheathed stance"
    elseif is_onehanded(prev) then was_out, how = true, "previous action was katana stance"
    else was_out, how = (on == true), "katana object, seen one frame late" end
    S.was_out = was_out
    local list_now, layer_now = field(S.katana, "_WeaponOnVisualParamListNo"), field(S.katana, "_WeaponOnLayerNo")
    if on == false then
        S.off_list, S.off_layer = list_now, layer_now
    else
        S.off_list, S.off_layer = gm800_static("get_DEFAULT_PARAM_LIST_NO"), gm800_static("get_DEFAULT_LAYER_NO")
        if on == true then S.on_list, S.on_layer = list_now, layer_now end
    end
    -- without the object the hold still starts: the setWeaponOn hook adopts the katana on its first call
    S.hold = cfg.enabled and not was_out
    if S.hold then S.held_runs = S.held_runs + 1 end
    note(string.format("wall run start (%s): %s  prev=%s  katanaOn=%s  was_out=%s (%s)  hold=%s  offArgs=%s,%s  [v%s table=%s]",
        source, short(name), short(prev), tostring(on), tostring(was_out), how, tostring(S.hold),
        tostring(S.off_list), tostring(S.off_layer), VERSION, A.status))
    if S.katana_addr == 0 then note("katana object not found (" .. K.trace .. "), waiting for it in the setWeaponOn hook") end
end

local function combat_blocks()
    return cfg.respect_combat and in_battle()
end

-- Ask the base action controller for a sheathed-stance action ourselves.
local function switch_to(target, reason)
    local p = player()
    local t = A.by_name[target]
    if p == nil or p.base == nil or t == nil or not A.verified then
        note("direct switch not possible (" .. reason .. "): action table " .. A.status)
        return false
    end
    -- (index, category): the order the game accepted in the bow mod
    local ok, accepted = pcall(function() return p.base:call("changeActionRequest(System.Int32, System.Int32)", t.i, t.c) end)
    note(string.format("direct switch to %s (%s): ok=%s accepted=%s", short(target), reason, tostring(ok), tostring(accepted)))
    return ok and accepted ~= false
end

local function end_run(name)
    if not S.hold then
        note(string.format("wall run ended -> %s (%s)", short(name),
            S.drawn and "katana was drawn with guard" or (S.was_out and "katana was out before, vanilla" or "not held")) .. summary())
        reset_run()
        return
    end
    if is_basic(name) then
        S.sheathed_landings = S.sheathed_landings + 1
        note("wall run ended -> " .. short(name) .. " (never drawn, stays sheathed)" .. summary())
        reset_run()
        return
    end
    local twin = cfg.stay_sheathed_after and basic_twin(name) or nil
    if twin ~= nil and not combat_blocks() then
        note("wall run ended -> " .. short(name) .. " (never drawn, katana stance not redirected)" .. summary())
        if switch_to(twin, "wall run ended in " .. short(name)) then
            S.state, S.after_until = "after", now() + 0.4
            return
        end
    else
        note("wall run ended -> " .. short(name) .. " (never drawn, katana comes out now)" .. summary())
    end
    end_hold("wall run ended in " .. short(name))
    reset_run()
end

-- a wall-run action (base or sub) starts; from a detailEnter hook or from the poll
local function on_wallrun_enter(name, source, prev)
    if S.state ~= "run" then
        if S.state == "after" and S.hold then
            S.state, S.confirmed, S.started_at = "run", false, now()   -- next wall, still sheathed
        elseif name:find("SubAction", 1, true) == nil then
            begin_run(name, source, prev)
        end
    end
    if S.state == "run" then diag("act|" .. name, "wall-run action (" .. source .. "): " .. short(name)) end
    if S.hold and is_guard(name) then draw(short(name)) end
end

local function on_base_enter(name)
    local prev = P.last_base_action
    P.last_base_action = name
    if is_wallrun(name) then
        on_wallrun_enter(name, "poll", prev)
        if S.state == "run" then S.confirmed = true end
        S.action_at = now()
        return
    end
    S.action_at = now()
    if S.state == "run" then
        -- a run started by the detailEnter hook is one frame ahead of the poll: wait until the
        -- poll has seen a wall-run action before a non-wall-run action counts as the end
        if S.confirmed or now() - S.started_at > 0.5 then end_run(name) end
    elseif S.state == "after" then
        if is_basic(name) then
            S.sheathed_landings = S.sheathed_landings + 1
            note("sheathed stance reached: " .. short(name))
            reset_run()
        elseif basic_twin(name) == nil then
            note("player busy (" .. short(name) .. "), katana comes out")
            end_hold("busy after the wall run")
            reset_run()
        end
    end
end

local function on_sub_enter(name)
    P.last_sub_action = name
    if S.state == "idle" then return end
    if is_wallrun(name) then on_wallrun_enter(name, "poll sub", nil)
    else diag("sub|" .. name, "sub action: " .. short(name)) end
end

local function poll_transitions()
    local p = resolve_player()
    if p == nil then return end
    if P.changed then
        P.changed = false
        if S.state ~= "idle" then note("player object changed, state reset"); reset_run() end
    end
    local name = type_name(call(p.character, "get_BaseCurrentAction"))
    if name ~= nil and name ~= P.last_base_action then on_base_enter(name) end
    local sub = type_name(call(p.character, "get_SubCurrentAction"))
    if sub ~= nil and sub ~= P.last_sub_action then on_sub_enter(sub) end
end

-- guard / parry key state from the player's command result
local function guard_key(p)
    local cr = call(field(p.info, "<ControllerEntity>k__BackingField"), "get_CommandResult")
    if cr == nil then return nil end
    if call(cr, "get__IsGuard") == true then return "guard held" end
    if call(cr, "checkNormalCommand", CMD_GUARD) == true then return "GUARD command" end
    if call(cr, "checkNormalCommand", CMD_PARRY) == true then return "PARRY command" end
    return nil
end

local function set_katana(katana, on, list, layer, hokan)
    return pcall(function() katana:call(SIG_SET_ON, on, list or 0, layer or 0, hokan or 0) end)
end

-- called once per game update (pre UpdateBehavior); cheap when nothing is pending
local function tick()
    pcall(poll_transitions)
    local t = now()
    if R.at ~= nil and t >= R.at then
        local katana, why = R.katana, R.why
        R.at, R.katana = nil, nil
        if katana ~= nil and not is_basic(P.last_base_action) and call(katana, "get_IsWeaponOn") == false then
            if R.list ~= nil then
                local ok = set_katana(katana, true, R.list, R.layer, R.hokan)
                note(string.format("katana still sheathed 0.15s after the hold ended (%s) -> setWeaponOn(true, %s, %s, %s) ok=%s",
                    tostring(why), tostring(R.list), tostring(R.layer), tostring(R.hokan), tostring(ok)))
            else
                note("katana still sheathed after the hold ended (" .. tostring(why) .. "), but the game never asked for it: left alone")
            end
        end
    end
    if S.state == "idle" then
        -- keep the action table ready so the first wall run does not have to build it
        if P.base_ctrl ~= 0 and A.ctrl ~= P.base_ctrl and t - A.tried_at > 1.0 then
            local p = player()
            if p ~= nil then build_actions(p.base) end
        end
        if K.obj == nil or K.character ~= P.character_addr then
            local p = player()
            if p ~= nil then katana_cached(p, false) end
        end
        return
    end
    if S.katana == nil then
        local p = player()
        if p ~= nil then
            S.katana = katana_cached(p, false)
            S.katana_addr = addr(S.katana)
        end
    end
    if S.state == "run" and not S.confirmed and t - S.started_at > 0.6 then
        note("wall run start was not confirmed by the running action, state reset" .. summary())
        end_hold("not confirmed")
        reset_run()
        return
    end
    if S.state == "after" and t > S.after_until then
        note("sheathed stance not reached (still " .. short(P.last_base_action) .. "), katana comes out")
        end_hold("direct switch had no effect")
        reset_run()
        return
    end
    local on = nil
    if S.katana ~= nil and (S.hold or cfg.debug) then on = call(S.katana, "get_IsWeaponOn") end
    if cfg.debug and on ~= nil and on ~= S.sword_prev then
        if S.sword_prev ~= nil then
            note(string.format("katana on=%s (list=%s layer=%s) during %s +%.2fs", tostring(on),
                tostring(field(S.katana, "_WeaponOnVisualParamListNo")), tostring(field(S.katana, "_WeaponOnLayerNo")),
                short(P.last_base_action), t - S.action_at))
        end
        S.sword_prev = on
    end
    if not S.hold then return end
    if cfg.draw_on_key and S.state == "run" then
        local p = player()
        local key = p and guard_key(p)
        if key ~= nil then draw(key); return end
    end
    if cfg.enforce and on == true then
        if S.on_list == nil then
            S.on_list, S.on_layer = field(S.katana, "_WeaponOnVisualParamListNo"), field(S.katana, "_WeaponOnLayerNo")
        end
        local ok = set_katana(S.katana, false, S.off_list, S.off_layer, 0)
        S.enforced = S.enforced + 1
        if S.enforced == 1 then
            note(string.format("katana is in the hand although held (hook calls=%d forced=%d) -> setWeaponOn(false, %s, %s, 0) ok=%s",
                S.calls, S.forced, tostring(S.off_list), tostring(S.off_layer), tostring(ok)))
        end
        S.sword_prev = nil
    end
end

-------------------------------------------------------------------------------
-- hooks
-------------------------------------------------------------------------------
local function find_method(type_name_, signature, num_params)
    local td = safe(sdk.find_type_definition, type_name_)
    if td == nil then return nil end
    local m = safe(td.get_method, td, signature)
    if m == nil then return nil end
    if num_params ~= nil and safe(m.get_num_params, m) ~= num_params then return nil end
    return m
end

-- An ace.ACTION_ID argument is either a pointer to the 8-byte struct or the struct itself
-- packed into the register. Tell them apart without touching bad memory.
local function decode_id(raw)
    local v = safe(sdk.to_int64, raw)
    if type(v) ~= "number" or v <= 0 then return nil end
    local lo, hi = v & 0xFFFFFFFF, (v >> 32) & 0xFFFFFFFF
    if lo < 0x1000 and hi < 0x10000 then return lo, hi, "value" end
    if lo == 0xFFFFFFFF or hi == 0xFFFFFFFF then return nil end
    if (v & 3) ~= 0 or v < 0x10000 or v > 0x00007FFFFFFFFFFF then return nil end
    if T_ACTION_ID == nil then return nil end
    local c = safe(sdk.get_native_field, raw, T_ACTION_ID, "_Category")
    local i = safe(sdk.get_native_field, raw, T_ACTION_ID, "_Index")
    if type(c) ~= "number" or type(i) ~= "number" then return nil end
    return c, i, "pointer"
end

-- 1) the katana's on/off switch
local function install_hold_hook()
    local m = find_method("app.Gm800", SIG_SET_ON, 4)
    if m == nil then return false end
    return pcall(sdk.hook, m, function(args)
        if S.state == "idle" then return end                 -- fires for every weapon of every character
        local this = safe(sdk.to_int64, args[2])
        S.any_calls = (S.any_calls or 0) + 1
        if this == nil or this == 0 then return end
        if S.katana_addr == 0 then
            -- katana unknown: adopt the player's Gm800_000 from this very call
            local g = safe(sdk.to_managed_object, args[2])
            local tn = type_name(g)
            diag("anyset|" .. tostring(tn), "setWeaponOn called for " .. tostring(tn))
            if tn ~= "app.Gm800_000" then return end
            local owner = addr(call(g, "get_OwnerCharacter"))
            if owner ~= 0 and owner ~= P.character_addr then return end
            S.katana, S.katana_addr = g, this
            K.obj, K.addr, K.character = g, this, P.character_addr
            note("katana adopted from setWeaponOn (owner " .. (owner ~= 0 and "= player" or "unknown") .. ")")
        end
        if this ~= S.katana_addr then return end
        local raw = safe(sdk.to_int64, args[3])
        if raw == nil then return end
        local on = (raw & 0xFF) ~= 0
        local a4, a5, a6 = int32(safe(sdk.to_int64, args[4])), int32(safe(sdk.to_int64, args[5])), int32(safe(sdk.to_int64, args[6]))
        S.calls = S.calls + 1
        diag("set|" .. tostring(on) .. "|" .. tostring(a4) .. "|" .. tostring(a5) .. "|" .. tostring(a6),
            string.format("game: katana setWeaponOn(%s, %s, %s, %s) hold=%s", tostring(on), tostring(a4), tostring(a5), tostring(a6), tostring(S.hold)))
        if not on then
            if S.hold and a4 ~= nil and a5 ~= nil then S.off_list, S.off_layer = a4, a5 end
            return
        end
        if not (S.hold and cfg.hold_hook) then return end
        S.on_list, S.on_layer, S.on_hokan = a4, a5, a6
        args[3] = sdk.to_ptr(0)
        if S.off_list ~= nil then args[4] = sdk.to_ptr(S.off_list) end
        if S.off_layer ~= nil then args[5] = sdk.to_ptr(S.off_layer) end
        S.forced = S.forced + 1
        if S.forced == 1 then
            note(string.format("hold: katana setWeaponOn(true, %s, %s, %s) turned into (false, %s, %s, %s)",
                tostring(a4), tostring(a5), tostring(a6), tostring(S.off_list or a4), tostring(S.off_layer or a5), tostring(a6)))
        end
    end, function(retval) return retval end)
end

-- 1b) the katana's own per-frame on/off check: not run during the hold, so it stays where it is
local function install_check_hook()
    local m = find_method("app.Gm800", "checkWeaponOn", 0)
    if m == nil then return false end
    return pcall(sdk.hook, m, function(args)
        if S.state == "idle" then return end
        if safe(sdk.to_int64, args[2]) ~= S.katana_addr or S.katana_addr == 0 then return end
        S.check_calls = S.check_calls + 1
        if not (S.hold and cfg.hold_check) then return end
        S.check_skips = S.check_skips + 1
        if S.check_skips == 1 then note("hold: the katana's checkWeaponOn is skipped from now on") end
        return sdk.PreHookResult.SKIP_ORIGINAL
    end, function(retval) return retval end)
end

-- 1c) the katana's joint-scale test (the motion says "weapon on" through a joint's scale)
local function install_scale_hook()
    local m = find_method("app.Gm800", "checkJointScaleY(via.motion.MotionInfo, System.Single, System.UInt32, System.Int32)", 4)
        or find_method("app.Gm800", "checkJointScaleY", 4)
    if m == nil then return false end
    return pcall(sdk.hook, m, function(args)
        local st = hook_storage()
        st.wks_scale = false
        if S.state == "idle" then return end
        if safe(sdk.to_int64, args[2]) ~= S.katana_addr or S.katana_addr == 0 then return end
        st.wks_scale = true
    end, function(retval)
        if hook_storage().wks_scale ~= true then return retval end
        hook_storage().wks_scale = false
        S.scale_calls = S.scale_calls + 1
        local raw = safe(sdk.to_int64, retval)
        local on = raw ~= nil and (raw & 0xFF) ~= 0
        diag("scale|" .. tostring(on), "katana checkJointScaleY returned " .. tostring(on) .. " hold=" .. tostring(S.hold))
        if on and S.hold and cfg.hold_scale then
            S.scale_forced = S.scale_forced + 1
            if S.scale_forced == 1 then note("hold: the katana's checkJointScaleY answer true is turned into false") end
            return sdk.to_ptr(0)
        end
        return retval
    end)
end

-- 2) the motion's weapon track (diagnostics; optionally swallowed during the hold)
local function install_track_hook()
    local m = find_method("app.cPlayerCharacterEntity", "evWeaponTrack(app.motion_track.CharacterWeaponTrack, ace.MOTION_SEQUENCE_UPDATER_ARGS)", 2)
    if m == nil then return false end
    return pcall(sdk.hook, m, function(args)
        if S.state == "idle" then return end
        if not (cfg.debug or (S.hold and cfg.skip_weapon_track)) then return end
        if safe(sdk.to_int64, args[2]) ~= P.entity_addr then return end
        local track = safe(sdk.to_managed_object, args[3])
        local st = call(track, "get__Status")
        if st == nil then st = call(track, "get_Status") end
        if st == nil then st = field(track, "_Status") end
        local rate = call(track, "get__WeaponOnOffRate")
        if rate == nil then rate = field(track, "_WeaponOnOffRate") end
        diag("track|" .. tostring(st), string.format("weapon track (%s): status=%s rate=%s", tostring(type_name(track)), tostring(st), tostring(rate)))
        if S.hold and cfg.skip_weapon_track and tostring(st) == "1" then
            S.track_skips = S.track_skips + 1
            return sdk.PreHookResult.SKIP_ORIGINAL
        end
    end, function(retval) return retval end)
end

-- 3) a wall-run action's own enter: the earliest sign that a wall run starts / guard starts
local function install_enter_hook(type_)
    local m = find_method(type_, "detailEnter", 0)
    if m == nil then return false end
    return pcall(sdk.hook, m, function(args)
        if not cfg.enabled then return end
        local action = safe(sdk.to_managed_object, args[2])
        local name = type_name(action)
        if not is_wallrun(name) then return end
        if S.state == "run" and not (S.hold and is_guard(name)) and not cfg.debug then return end
        local owner = addr(call(action, "get_OwnerCharacter"))
        if owner == 0 then return end
        if owner ~= P.character_addr then
            resolve_player()
            if owner ~= P.character_addr then return end
        end
        pcall(on_wallrun_enter, name, "hook", P.last_base_action)
    end, function(retval) return retval end)
end

-- 4) the wall-run start: use the "katana out" start motion so no draw gesture plays
local function install_start_motion_hook()
    local m = find_method("app.PlayerOneHandedAction.cWallRunStart", "doDetailEnter", 0)
    if m == nil then return false end
    return pcall(sdk.hook, m, function(args)
        local st = hook_storage()
        st.wks_swap = nil
        if not (S.hold and cfg.swap_start_motion) then return end
        pcall(function()
            local action = sdk.to_managed_object(args[2])
            if addr(call(action, "get_OwnerCharacter")) ~= P.character_addr then return end
            local on_motion, off_motion = field(action, "_WepOnStartMotionID"), field(action, "_WepOffStartMotionID")
            if on_motion == nil or off_motion == nil then
                note("start motion: fields not readable, left alone")
                return
            end
            action:set_field("_WepOffStartMotionID", on_motion)
            st.wks_swap = { action = action, off_motion = off_motion }
            S.swapped = true
            note("start motion: the katana-out start motion is used (no draw gesture)")
        end)
    end, function(retval)
        local st = hook_storage()
        local swap = st.wks_swap
        if swap ~= nil then
            st.wks_swap = nil
            local ok = pcall(function() swap.action:set_field("_WepOffStartMotionID", swap.off_motion) end)
            if not ok then note("start motion: could not put the original motion list back") end
        end
        return retval
    end)
end

-- 5) base action requests of the player while the run is still sheathed: swap the katana-stance
--    action that follows the run for its sheathed twin.
local function pick_redirect(api, c, i)
    local name = A.by_id[id_key(c, i)]
    diag("req|" .. api .. "|" .. tostring(c) .. "," .. tostring(i), string.format("request %s: %s (%s,%s)", api, short(name), tostring(c), tostring(i)))
    if name == nil or not cfg.stay_sheathed_after or not A.verified or is_wallrun(name) then return nil end
    local target = basic_twin(name)
    if target == nil then return nil end
    if combat_blocks() then
        if not S.combat_noted then S.combat_noted = true; note("enemies in battle mode, not redirecting " .. short(name)) end
        return nil
    end
    local t = A.by_name[target]
    S.redirects = S.redirects + 1
    if S.redirects == 1 then note(string.format("redirect via %s: %s -> %s", api, short(name), short(target))) end
    return t.c, t.i
end

local function install_request_hook(key, type_, signature, num_params, kind, owner)
    local m = find_method(type_, signature, num_params)
    if m == nil then return false end
    return pcall(sdk.hook, m, function(args)
        if not S.hold then return end
        local this = safe(sdk.to_int64, args[2])
        if this == nil or this == 0 then return end
        if owner == "character" then
            if this ~= P.character_addr then return end
        elseif this ~= P.base_ctrl then
            return
        end
        pcall(function()
            local c, i, mode
            if kind == "ints" then
                i, c, mode = sdk.to_int64(args[3]) & 0xFFFFFFFF, sdk.to_int64(args[4]) & 0xFFFFFFFF, "ints"
            else
                c, i, mode = decode_id(args[3])
            end
            if c == nil then return end
            local nc, ni = pick_redirect(key, c, i)
            if nc == nil then return end
            if mode == "ints" then
                args[3] = sdk.to_ptr(ni)
                args[4] = sdk.to_ptr(nc)
            elseif mode == "value" then
                args[3] = sdk.to_ptr((ni << 32) | nc)
            else
                -- pointer: hand the game a private copy and keep it alive until the call returns
                local id = sdk.to_valuetype(args[3], T_ACTION_ID)
                id:set_field("_Category", nc)
                id:set_field("_Index", ni)
                if id:get_field("_Category") ~= nc or id:get_field("_Index") ~= ni then
                    note("redirect could not be written (" .. key .. ")")
                    return
                end
                hook_storage().wks_id = id
                args[3] = sdk.to_ptr(id:get_address())
            end
        end)
    end, function(retval)
        if S.state ~= "idle" then hook_storage().wks_id = nil end
        return retval
    end)
end

local REQUEST_HOOKS = {
    { "requestBaseAction", "app.CharacterBase", "requestBaseAction(ace.ACTION_ID, app.CharacterDef.ACTION_REQUEST_CATEGORY)", 2, "id", "character" },
    { "requestBaseActionWithArgument", "app.CharacterBase", "requestBaseActionWithArgument(ace.ACTION_ID, app.CharacterDef.ACTION_REQUEST_CATEGORY, app.cCharacterArgumentData)", 3, "id", "character" },
    { "changeActionRequest", "ace.cActionController", "changeActionRequest(ace.ACTION_ID)", 1, "id", "controller" },
    { "changeActionRequest(int,int)", "ace.cActionController", "changeActionRequest(System.Int32, System.Int32)", 2, "ints", "controller" },
    { "changeActionImmediate", "ace.cActionController", "changeActionImmediate(ace.ACTION_ID, System.Boolean)", 2, "id", "controller" },
    { "changeActionImmediate(int,int)", "ace.cActionController", "changeActionImmediate(System.Int32, System.Int32, System.Boolean)", 3, "ints", "controller" },
}
local ENTER_HOOKS = {
    "app.PlayerCommonAction.cWallRunActionBase",
    "app.PlayerCommonAction.cWallRunStartJumpBase",
    "app.PlayerOneHandedSubAction.cWallRunBlock",
    "app.PlayerOneHandedSubAction.cWallRunGuardHit",
}

local function install()
    local hold = install_hold_hook()
    local track = install_track_hook()
    local start = install_start_motion_hook()
    local enter_n, request_n = 0, 0
    for _, t in ipairs(ENTER_HOOKS) do
        if install_enter_hook(t) then enter_n = enter_n + 1 end
    end
    for _, h in ipairs(REQUEST_HOOKS) do
        if install_request_hook(h[1], h[2], h[3], h[4], h[5], h[6]) then request_n = request_n + 1 end
    end
    status.install = string.format("v%s  setWeaponOn=%s  weaponTrack=%s  startMotion=%s  enter=%d/%d  requests=%d/%d  actionIdType=%s",
        VERSION, hold and "ok" or "MISSING", track and "ok" or "off", start and "ok" or "off",
        enter_n, #ENTER_HOOKS, request_n, #REQUEST_HOOKS, T_ACTION_ID ~= nil and "ok" or "MISSING")
    status.install = status.install .. "  checkWeaponOn=" .. (install_check_hook() and "ok" or "MISSING")
        .. "  checkJointScaleY=" .. (install_scale_hook() and "ok" or "MISSING")
    note("installed: " .. status.install)
end
install()

re.on_pre_application_entry("UpdateBehavior", function() pcall(tick) end)

-------------------------------------------------------------------------------
-- UI
-------------------------------------------------------------------------------
re.on_draw_ui(function()
    if not imgui.tree_node("Wall Run Keeps Sheathed") then return end
    local changed, c = false, false
    c, cfg.enabled = imgui.checkbox("Enabled", cfg.enabled); changed = changed or c
    c, cfg.hold_hook = imgui.checkbox("Keep the katana in the sheath (block the game's draw)", cfg.hold_hook); changed = changed or c
    c, cfg.hold_check = imgui.checkbox("... by stopping the katana's own on/off check (main method)", cfg.hold_check); changed = changed or c
    c, cfg.hold_scale = imgui.checkbox("... by answering 'off' to its joint-scale test", cfg.hold_scale); changed = changed or c
    c, cfg.enforce = imgui.checkbox("Fallback: put it back when it shows up in the hand anyway", cfg.enforce); changed = changed or c
    c, cfg.skip_weapon_track = imgui.checkbox("Experimental: also swallow the motion's weapon-on track", cfg.skip_weapon_track); changed = changed or c
    c, cfg.swap_start_motion = imgui.checkbox("Start of the run: no draw gesture", cfg.swap_start_motion); changed = changed or c
    c, cfg.draw_on_key = imgui.checkbox("Guard / parry key draws at once (not only when the guard action starts)", cfg.draw_on_key); changed = changed or c
    c, cfg.stay_sheathed_after = imgui.checkbox("Land in the sheathed stance when the katana was never drawn", cfg.stay_sheathed_after); changed = changed or c
    c, cfg.respect_combat = imgui.checkbox("... but not while enemies are in battle mode", cfg.respect_combat); changed = changed or c
    c, cfg.debug = imgui.checkbox("Write debug lines to re2_framework_log.txt", cfg.debug); changed = changed or c
    if changed then save_cfg() end

    imgui.text("Hooks: " .. status.install)
    imgui.text("Action table: " .. A.status)
    imgui.text(string.format("State: %s   hold=%s   drawn=%s   was_out=%s", S.state, tostring(S.hold), tostring(S.drawn), tostring(S.was_out)))
    imgui.text(string.format("Wall runs: %d   held sheathed: %d   drawn with guard: %d   sheathed landings: %d",
        S.runs, S.held_runs, S.guard_draws, S.sheathed_landings))
    imgui.text("Base action: " .. tostring(P.last_base_action))
    imgui.text("Sub action:  " .. tostring(P.last_sub_action))
    if imgui.tree_node("Recent events") then
        for i = #events, 1, -1 do imgui.text(events[i]) end
        if imgui.button("Clear") then events = {} end
        imgui.tree_pop()
    end
    imgui.tree_pop()
end)

re.on_script_reset(function() reset_run() end)
