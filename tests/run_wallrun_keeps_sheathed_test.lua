-- Offline smoke test for wallrun_keeps_sheathed.lua: fakes the REFramework Lua API and plays
-- wall-run sequences through the installed hooks.
-- Run:  lua run_wallrun_keeps_sheathed_test.lua <path to wallrun_keeps_sheathed.lua>
-- It only tests the script's own logic, not any game behaviour.

local script_path = arg[1] or error("pass the script path")

local T = 0
os.clock = function() return T end

-- fake managed objects ---------------------------------------------------------
local objects_by_addr = {}
local function Obj(addr, tname, methods, fields)
    local o = { _addr = addr, _type = tname, _m = methods or {}, _f = fields or {} }
    function o:get_address() return self._addr end
    function o:get_type_definition() return { get_full_name = function() return o._type end } end
    function o:call(name, ...)
        local m = self._m[name]
        if m == nil then error("no method " .. name .. " on " .. tname) end
        return m(self, ...)
    end
    function o:get_field(name)
        if self._f[name] == nil then error("no field " .. name .. " on " .. tname) end
        return self._f[name]
    end
    function o:set_field(name, v) self._f[name] = v end
    objects_by_addr[addr] = o
    return o
end

-- fake native memory for ace.ACTION_ID structs ---------------------------------
local mem, next_mem = {}, 0x7FF000001000
local function id_ptr(c, i)
    next_mem = next_mem + 16
    mem[next_mem] = { _Category = c, _Index = i }
    return next_mem
end
local function id_valuetype(c, i)
    local a = id_ptr(c, i)
    return {
        set_field = function(_, n, v) mem[a][n] = v end,
        get_field = function(_, n) return mem[a][n] end,
        get_address = function() return a end,
    }
end

-- game state -------------------------------------------------------------------
local G = { battle = false, log = {}, cfg = { debug = true }, switch_mode = "reject", switch_calls = 0, switch_target = nil,
    pending_base = nil, guard_held = false, cmd = {}, set_calls = {} }
local hooks = {}

-- base actions: category 0 = sheathed stance, 1 = katana stance
local registry = { [0] = {}, [1] = {} }
local next_action_addr = 0x100
local function action(cat, tname, fields)
    next_action_addr = next_action_addr + 1
    local o = Obj(next_action_addr, tname, { get_OwnerCharacter = function() return objects_by_addr[0x1000] end }, fields)
    if cat ~= nil then
        table.insert(registry[cat], o)
        o._cat, o._idx = cat, #registry[cat] - 1
    end
    return o
end
local MOT_ON, MOT_OFF = { "on motions" }, { "off motions" }
local A = {
    basic_nothing = action(0, "app.PlayerBasicAction.cDoNothing"),
    basic_idle = action(0, "app.PlayerBasicAction.cIdle"),
    basic_run = action(0, "app.PlayerBasicAction.cRun"),
    basic_jump = action(0, "app.PlayerBasicAction.cWallRunStartJump"),
    one_nothing = action(1, "app.PlayerOneHandedAction.cDoNothing"),
    one_idle = action(1, "app.PlayerOneHandedAction.cIdle"),
    one_run = action(1, "app.PlayerOneHandedAction.cRun"),
    one_attack = action(1, "app.PlayerOneHandedAction.cAttackWeak1"),
    one_jump = action(1, "app.PlayerOneHandedAction.cWallRunStartJump"),
    wr_start = action(1, "app.PlayerOneHandedAction.cWallRunStart", { _WepOnStartMotionID = MOT_ON, _WepOffStartMotionID = MOT_OFF }),
    wr_loop = action(1, "app.PlayerOneHandedAction.cWallRunLoop"),
    wr_guard = action(1, "app.PlayerOneHandedAction.cWallRunGuard"),
    wr_land = action(1, "app.PlayerOneHandedAction.cWallRunRouteEndLandSmall"),
    sub_nothing = action(nil, "app.PlayerOneHandedSubAction.cDoNothing"),
    sub_block = action(nil, "app.PlayerOneHandedSubAction.cWallRunBlock"),
}

local current_base, current_sub = A.basic_idle, A.sub_nothing
local base_ctrl = Obj(0x3000, "ace.cActionController", {
    getActionNum = function(_, c) return #registry[c] end,
    ["getAction(ace.ACTION_ID)"] = function(_, vt)
        local c, i = vt:get_field("_Category"), vt:get_field("_Index")
        return registry[c] and registry[c][i + 1]
    end,
    get_CurrentActionID = function() return id_valuetype(current_base._cat, current_base._idx) end,
    get_CurrentAction = function() return current_base end,
    ["changeActionRequest(System.Int32, System.Int32)"] = function(self, i, c)
        local args = { nil, self:get_address(), i, c }
        hooks.car_ints.pre(args)
        hooks.car_ints.post(1)
        G.switch_calls = G.switch_calls + 1
        G.switch_target = registry[args[4]] and registry[args[4]][args[3] + 1]
        if G.switch_mode == "reject" then return false end
        if G.switch_mode == "accept" then G.pending_base = G.switch_target end
        return true
    end,
}, { _ActionList = { call = function(_, n) if n == "get_Count" then return 2 end error("no method " .. n) end } })
local sub_ctrl = Obj(0x3100, "ace.cActionController", {})
local character = Obj(0x1000, "app.PlayerCharacter", {
    get_BaseActionController = function() return base_ctrl end,
    get_SubActionController = function() return sub_ctrl end,
    get_BaseCurrentAction = function() return current_base end,
    get_SubCurrentAction = function() return current_sub end,
})

-- the katana: setWeaponOn goes through the mod's hook, like in the game
local SIG = "setWeaponOn(System.Boolean, System.Int32, System.Int32, System.Int32)"
local sword
sword = Obj(0x6001, "app.Gm800_000", {
    get_IsWeaponOn = function(self) return self._f._IsWeaponOn end,
    [SIG] = function(self, on, list, layer, hokan)
        local args = { nil, self:get_address(), on and 1 or 0, list, layer, hokan }
        hooks.set_on.pre(args)
        hooks.set_on.post(0)
        self._f._IsWeaponOn = args[3] ~= 0
        self._f._WeaponOnVisualParamListNo, self._f._WeaponOnLayerNo = args[4], args[5]
        G.set_calls[#G.set_calls + 1] = { on = args[3] ~= 0, list = args[4], layer = args[5], hokan = args[6] }
    end,
}, { _IsWeaponOn = false, _WeaponOnVisualParamListNo = 0, _WeaponOnLayerNo = -1 })
local function game_sets_katana(on, list, layer, hokan) sword:call(SIG, on, list, layer, hokan) end
-- the real game's way (seen with v1.1): the katana's own per-frame check reads the motion's joint scale
local function game_checks_katana(motion_says_on)
    if hooks.check_on.pre({ nil, sword:get_address() }) == "skip" then return "skipped" end
    hooks.scale.pre({ nil, sword:get_address(), 0, 0, 0, 0 })
    local answer = hooks.scale.post(motion_says_on and 1 or 0)
    sword._f._IsWeaponOn = answer ~= 0
    if answer ~= 0 then sword._f._WeaponOnVisualParamListNo, sword._f._WeaponOnLayerNo = 1, 2 end
    hooks.check_on.post(0)
    return "ran"
end
local sword_data = Obj(0x6101, "app.cCharacterWeaponSupporter.cData", { get_WeaponGimmick = function() return sword end })
local data_list = Obj(0x6103, "List", { get_Count = function() return 1 end, get_Item = function() return sword_data end })
local weapon_supporter = Obj(0x6200, "app.cCharacterWeaponSupporter", { get_WeaponDataList = function() return data_list end })
local entity = Obj(0x2000, "app.cPlayerCharacterEntity", { get_Weapon = function() return weapon_supporter end })
local command_result = Obj(0x2300, "app.cPlayerCommandResult", {
    get__IsGuard = function() return G.guard_held end,
    checkNormalCommand = function(_, n) return G.cmd[n] == true end,
})
local controller_entity = Obj(0x2200, "app.cPlayerInputControllerEntity", { get_CommandResult = function() return command_result end })
local info = Obj(0x2100, "app.PlayerManager.cPlayerInfo", {}, {
    ["<Character>k__BackingField"] = character,
    ["<CharacterEntity>k__BackingField"] = entity,
    ["<ControllerEntity>k__BackingField"] = controller_entity,
})
local player_manager = Obj(0x4000, "app.PlayerManager", { getControllingPlayerInfo = function() return info end })
local enemy_manager = Obj(0x4100, "app.EnemyManager", { isCheckBattleMode = function() return G.battle end })
local track_on = Obj(0x7001, "app.motion_track.CharacterWeaponTrack", { get__Status = function() return 1 end, get__WeaponOnOffRate = function() return 1.0 end })

-- fake REFramework API ---------------------------------------------------------
local methods = {
    ["app.Gm800|" .. SIG] = { key = "set_on", params = 4 },
    ["app.Gm800|checkWeaponOn"] = { key = "check_on", params = 0 },
    ["app.Gm800|checkJointScaleY(via.motion.MotionInfo, System.Single, System.UInt32, System.Int32)"] = { key = "scale", params = 4 },
    ["app.Gm800|get_DEFAULT_PARAM_LIST_NO"] = { key = "def_list", params = 0, static = 0 },
    ["app.Gm800|get_DEFAULT_LAYER_NO"] = { key = "def_layer", params = 0, static = -1 },
    ["app.cPlayerCharacterEntity|evWeaponTrack(app.motion_track.CharacterWeaponTrack, ace.MOTION_SEQUENCE_UPDATER_ARGS)"] = { key = "track", params = 2 },
    ["app.PlayerOneHandedAction.cWallRunStart|doDetailEnter"] = { key = "start", params = 0 },
    ["app.PlayerCommonAction.cWallRunActionBase|detailEnter"] = { key = "enter_base", params = 0 },
    ["app.PlayerCommonAction.cWallRunStartJumpBase|detailEnter"] = { key = "enter_jump", params = 0 },
    ["app.PlayerOneHandedSubAction.cWallRunBlock|detailEnter"] = { key = "enter_block", params = 0 },
    ["app.PlayerOneHandedSubAction.cWallRunGuardHit|detailEnter"] = { key = "enter_hit", params = 0 },
    ["app.CharacterBase|requestBaseAction(ace.ACTION_ID, app.CharacterDef.ACTION_REQUEST_CATEGORY)"] = { key = "req", params = 2 },
    ["app.CharacterBase|requestBaseActionWithArgument(ace.ACTION_ID, app.CharacterDef.ACTION_REQUEST_CATEGORY, app.cCharacterArgumentData)"] = { key = "reqarg", params = 3 },
    ["ace.cActionController|changeActionRequest(ace.ACTION_ID)"] = { key = "car_id", params = 1 },
    ["ace.cActionController|changeActionRequest(System.Int32, System.Int32)"] = { key = "car_ints", params = 2 },
    ["ace.cActionController|changeActionImmediate(ace.ACTION_ID, System.Boolean)"] = { key = "cai_id", params = 2 },
    ["ace.cActionController|changeActionImmediate(System.Int32, System.Int32, System.Boolean)"] = { key = "cai_ints", params = 3 },
}
local typedefs = {}
local function typedef(tn)
    if typedefs[tn] == nil then
        typedefs[tn] = {
            get_method = function(_, sig)
                local m = methods[tn .. "|" .. sig]
                if not m then return nil end
                return { _m = m, get_num_params = function() return m.params end, call = function() return m.static end }
            end,
        }
    end
    return typedefs[tn]
end
local ACTION_ID_T = typedef("ace.ACTION_ID")
sdk = {
    PreHookResult = { SKIP_ORIGINAL = "skip" },
    get_managed_singleton = function(n)
        if n == "app.PlayerManager" then return player_manager end
        if n == "app.EnemyManager" then return enemy_manager end
        return nil
    end,
    find_type_definition = typedef,
    hook = function(m, pre, post) hooks[m._m.key] = { pre = pre, post = post } end,
    to_int64 = function(v) return v end,
    to_ptr = function(v) return v end,
    to_managed_object = function(v) return objects_by_addr[v] end,
    to_valuetype = function(raw, t)
        assert(t == ACTION_ID_T, "to_valuetype: unexpected type")
        return id_valuetype(mem[raw]._Category, mem[raw]._Index)
    end,
    get_native_field = function(raw, t, n) return mem[raw][n] end,
    set_native_field = function(raw, t, n, v) mem[raw][n] = v end,
}
local app_entries = {}
re = {
    on_pre_application_entry = function(name, fn) app_entries[name] = fn end,
    on_draw_ui = function() end,
    on_script_reset = function() end,
}
imgui = {}
json = { load_file = function() return G.cfg end, dump_file = function() return true end }
log = { info = function(s) G.log[#G.log + 1] = s; print("   LOG " .. s) end }
thread = { get_hook_storage = (function() local st = {} return function() return st end end)() }

local function load_script()
    _G.wallrun_keeps_sheathed_loaded = nil
    hooks = {}
    assert(loadfile(script_path))()
    for _, k in ipairs({ "check_on", "scale", "set_on", "track", "start", "enter_base", "enter_jump", "enter_block", "enter_hit", "req", "reqarg", "car_id", "car_ints", "cai_id", "cai_ints" }) do
        assert(hooks[k], "hook not installed: " .. k)
    end
end
load_script()

-- drivers ----------------------------------------------------------------------
local function frame(dt)
    T = T + (dt or 0.016)
    if G.pending_base ~= nil then current_base, G.pending_base = G.pending_base, nil end
    app_entries["UpdateBehavior"]()
end
local function silent(act, dt) current_base = act; frame(dt) end      -- seen by the poll only
-- an action starts the way the game does it: its detailEnter hook fires, the poll sees it next frame
local function enter(act, dt)
    local key = act._type:find("StartJump", 1, true) and "enter_jump" or "enter_base"
    hooks[key].pre({ nil, act:get_address() }); hooks[key].post(0)
    if act == A.wr_start then
        hooks.start.pre({ nil, act:get_address() })
        G.start_motion_used = act._f._WepOffStartMotionID     -- the fake game starts from the sheathed state
        hooks.start.post(0)
    end
    current_base = act
    frame(dt)
end
local function game_request(act)
    local args = { nil, character:get_address(), id_ptr(act._cat, act._idx), 1 }
    hooks.req.pre(args)
    local m = mem[args[3]]
    hooks.req.post(1)
    return registry[m._Category][m._Index + 1]
end
local function expect(cond, msg) if cond then print("ok   " .. msg) else print("FAIL " .. msg); os.exit(1) end end
local function logged(text, from)
    for k = (from or 1), #G.log do if G.log[k]:find(text, 1, true) then return true end end
    return false
end
local function reset_game(katana_on)
    frame(1.0)
    G.battle, G.switch_mode, G.switch_calls, G.switch_target, G.pending_base = false, "reject", 0, nil, nil
    G.guard_held, G.cmd, G.set_calls, G.start_motion_used = false, {}, {}, nil
    sword._f._IsWeaponOn = katana_on == true
    sword._f._WeaponOnVisualParamListNo, sword._f._WeaponOnLayerNo = katana_on and 1 or 0, katana_on and 2 or -1
    current_sub = A.sub_nothing
    silent(katana_on and A.one_idle or A.basic_idle)
    frame(1.0)
    return #G.log
end

print("\n== A: sheathed wall run, never drawn, lands sheathed")
local mark = reset_game(false)
enter(A.basic_jump, 0.3)
enter(A.wr_start, 0.2)
expect(G.start_motion_used == MOT_ON, "start: the katana-out start motion was used")
expect(A.wr_start._f._WepOffStartMotionID == MOT_OFF, "start: the original motion list is back after the call")
game_sets_katana(true, 1, 2, 5)
expect(sword._f._IsWeaponOn == false, "the game's draw was turned into 'off'")
expect(G.set_calls[1].list == 0 and G.set_calls[1].layer == -1 and G.set_calls[1].hokan == 5, "off call uses the sheath's own list / layer numbers")
enter(A.wr_loop, 1.0)
game_sets_katana(true, 1, 2, 5); frame()
expect(sword._f._IsWeaponOn == false, "still sheathed in the loop")
expect(hooks.track.pre({ nil, entity:get_address(), track_on:get_address() }) == nil, "weapon track not swallowed by default")
enter(A.wr_land, 0.3)
expect(game_request(A.wr_loop) == A.wr_loop, "a wall-run request is left alone")
expect(game_request(A.one_attack) == A.one_attack, "an attack request is left alone")
local started = game_request(A.one_idle)
expect(started == A.basic_idle, "idle after the run redirected to the sheathed idle")
silent(started)
expect(logged("never drawn, stays sheathed", mark), "sheathed landing logged")
expect(game_request(A.one_idle) == A.one_idle, "no redirect once the run is over")
game_sets_katana(true, 1, 2, 5)
expect(sword._f._IsWeaponOn == true, "the katana is free again after the run")
expect(G.switch_calls == 0, "no direct switch needed")

print("\n== B: guard mid-run draws, and it stays out")
mark = reset_game(false)
enter(A.basic_jump, 0.3); enter(A.wr_start, 0.2); enter(A.wr_loop, 0.5)
game_sets_katana(true, 1, 2, 5)
expect(sword._f._IsWeaponOn == false, "sheathed before guard")
current_sub = A.sub_block; frame()
expect(logged("guard -> katana may come out", mark), "guard seen (sub action cWallRunBlock)")
game_sets_katana(true, 1, 2, 5)
expect(sword._f._IsWeaponOn == true, "katana out after guard")
current_sub = A.sub_nothing; frame(0.5)
game_sets_katana(true, 1, 2, 5); frame(0.5)
expect(sword._f._IsWeaponOn == true, "stays out for the rest of the run")
enter(A.wr_land, 0.3)
expect(game_request(A.one_idle) == A.one_idle, "landing not redirected after a draw")
silent(A.one_idle)
expect(logged("katana was drawn with guard", mark), "end logged as drawn")

print("\n== B2: guard as base action, seen by its detailEnter hook")
mark = reset_game(false)
enter(A.basic_jump, 0.3); enter(A.wr_start, 0.2); enter(A.wr_loop, 0.5)
hooks.enter_base.pre({ nil, A.wr_guard:get_address() })
game_sets_katana(true, 1, 2, 5)
expect(sword._f._IsWeaponOn == true, "katana out in the same frame as cWallRunGuard")
current_base = A.wr_guard; frame(0.3); silent(A.wr_loop, 0.3); silent(A.one_idle)

print("\n== C: katana out before the wall run, vanilla")
mark = reset_game(true)
enter(A.one_jump, 0.3); enter(A.wr_start, 0.2)
expect(G.start_motion_used == MOT_OFF, "start motion untouched")
game_sets_katana(true, 1, 2, 5); enter(A.wr_loop, 0.5)
expect(sword._f._IsWeaponOn == true, "katana untouched")
enter(A.wr_land, 0.3)
expect(game_request(A.one_idle) == A.one_idle, "landing untouched")
silent(A.one_idle)
expect(logged("was_out=true", mark) and logged("katana was out before", mark), "logged as vanilla")

print("\n== D: guard key draws before any guard action starts")
mark = reset_game(false)
enter(A.basic_jump, 0.3); enter(A.wr_start, 0.2); enter(A.wr_loop, 0.5)
game_sets_katana(true, 1, 2, 5)
G.cmd[16] = true; frame(); G.cmd[16] = nil
expect(logged("GUARD command", mark), "guard key seen")
frame(0.2)
expect(sword._f._IsWeaponOn == true, "katana put into the hand with the blocked arguments (game did not ask again)")
expect(G.set_calls[#G.set_calls].list == 1 and G.set_calls[#G.set_calls].layer == 2, "on call uses the game's own list / layer numbers")
silent(A.one_idle)

print("\n== E: the hook sees nothing, the fallback puts the katana back")
mark = reset_game(false)
enter(A.basic_jump, 0.3); enter(A.wr_start, 0.2); enter(A.wr_loop, 0.5)
sword._f._IsWeaponOn, sword._f._WeaponOnVisualParamListNo, sword._f._WeaponOnLayerNo = true, 1, 2   -- behind the hook's back
frame()
expect(sword._f._IsWeaponOn == false, "katana put back")
expect(logged("katana is in the hand although held", mark), "fallback logged")
G.guard_held = true; frame(); G.guard_held = false
frame(0.2)
expect(sword._f._IsWeaponOn == true and sword._f._WeaponOnVisualParamListNo == 1, "guard: katana restored with the numbers read before the fallback")
silent(A.one_idle)

print("\n== F: start seen by the poll only (no detailEnter hook)")
mark = reset_game(false)
silent(A.basic_run, 0.2)
silent(A.wr_start, 0.2)
expect(logged("previous action was sheathed stance", mark) and logged("hold=true", mark), "hold decided from the previous action")
game_sets_katana(true, 1, 2, 5)
expect(sword._f._IsWeaponOn == false, "held")
silent(A.wr_loop, 0.5); silent(A.basic_idle)

print("\n== G: landing request not seen, direct switch")
mark = reset_game(false); G.switch_mode = "accept"
enter(A.basic_jump, 0.3); enter(A.wr_start, 0.2); enter(A.wr_loop, 0.5); enter(A.wr_land, 0.3)
silent(A.one_run)
expect(G.switch_calls == 1 and G.switch_target == A.basic_run, "direct switch to the sheathed run")
game_sets_katana(true, 1, 2, 5)
expect(sword._f._IsWeaponOn == false, "still held while the switch is pending")
frame()
expect(current_base == A.basic_run and logged("sheathed stance reached", mark), "sheathed stance reached")

print("\n== H: run ends in an attack, katana released")
mark = reset_game(false)
enter(A.basic_jump, 0.3); enter(A.wr_start, 0.2); enter(A.wr_loop, 0.5)
game_sets_katana(true, 1, 2, 5)
silent(A.one_attack)
expect(logged("katana comes out now", mark), "release logged")
frame(0.2)
expect(sword._f._IsWeaponOn == true, "katana in the hand for the attack")

print("\n== I: battle mode, landing not redirected; disabled, nothing held")
mark = reset_game(false); G.battle = true
enter(A.basic_jump, 0.3); enter(A.wr_start, 0.2); enter(A.wr_loop, 0.5)
game_sets_katana(true, 1, 2, 5)
expect(sword._f._IsWeaponOn == false, "held during the run even in battle mode")
expect(game_request(A.one_idle) == A.one_idle, "battle mode: landing request untouched")
silent(A.one_idle); frame(0.2)
expect(sword._f._IsWeaponOn == true, "battle mode: katana out after the run")
G.cfg = { debug = true, enabled = false }
load_script()
mark = reset_game(false)
enter(A.basic_jump, 0.3); enter(A.wr_start, 0.2)
game_sets_katana(true, 1, 2, 5)
expect(sword._f._IsWeaponOn == true and G.start_motion_used == MOT_OFF, "disabled: nothing touched")
silent(A.one_idle)

print("\n== J: weapon-track skip option")
G.cfg = { debug = false, skip_weapon_track = true }
load_script()
mark = reset_game(false)
expect(hooks.track.pre({ nil, entity:get_address(), track_on:get_address() }) == nil, "no skip outside a wall run")
enter(A.basic_jump, 0.3); enter(A.wr_start, 0.2)
expect(hooks.track.pre({ nil, entity:get_address(), track_on:get_address() }) == "skip", "WEAPON_ON track swallowed during the hold")
expect(hooks.track.pre({ nil, 0x9999, track_on:get_address() }) == nil, "other characters untouched")
silent(A.basic_idle)

print("\n== K: the katana's own per-frame check (what the game really uses)")
G.cfg = { debug = true }
load_script()
mark = reset_game(false)
expect(game_checks_katana(false) == "ran", "check runs outside a wall run")
enter(A.basic_jump, 0.3); enter(A.wr_start, 0.2)
expect(game_checks_katana(true) == "skipped" and sword._f._IsWeaponOn == false, "check skipped during the hold, katana stays sheathed")
enter(A.wr_loop, 0.5)
expect(game_checks_katana(true) == "skipped", "still skipped in the loop")
current_sub = A.sub_block; frame()
expect(game_checks_katana(true) == "ran" and sword._f._IsWeaponOn == true, "after guard the check runs again and the katana comes out")
current_sub = A.sub_nothing
silent(A.one_idle)
G.cfg = { debug = true, hold_check = false }
load_script()
mark = reset_game(false)
enter(A.basic_jump, 0.3); enter(A.wr_start, 0.2)
expect(game_checks_katana(true) == "ran" and sword._f._IsWeaponOn == false, "check not skipped: the joint-scale answer is turned into off")
G.guard_held = true; frame(); G.guard_held = false
expect(game_checks_katana(true) == "ran" and sword._f._IsWeaponOn == true, "after guard the joint-scale answer passes")
silent(A.one_idle)
expect(game_checks_katana(true) == "ran" and sword._f._IsWeaponOn == true, "untouched outside a wall run")

print("\nall scenarios passed")
