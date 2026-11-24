-- Offline smoke test for bow_keeps_sheathed.lua (v2): fakes the REFramework Lua API and
-- plays action-transition sequences through the installed hooks.
-- Run:  lua run_bow_keeps_sheathed_test.lua <path to bow_keeps_sheathed.lua>
-- It only tests the script's own logic, not any game behaviour.

local script_path = arg[1] or error("pass the script path")

-- controllable clock -----------------------------------------------------------
local T = 0
os.clock = function() return T end
local function advance(dt) T = T + dt end

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
local G = { weapon_on = false, battle = false, force_req = 0, timer_forced = 0, log = {}, cfg = nil, saved = nil,
    switch_mode = "reject", switch_calls = 0, pending_base = nil, sword_on = false, bow_on = false }

local supporter = Obj(0x5000, "app.cPlayerAutoWeaponOnOffSupporter", {
    isWeaponOn = function() return G.weapon_on end,
    forceTimeOutOneHandIdleWeaponOffTimer = function() G.timer_forced = G.timer_forced + 1 end,
    set_RequestForceAutoWeaponOnOff = function(_, v) G.force_req = v end,
}, { ["<RequestForceAutoWeaponOnOff>k__BackingField"] = 0 })
supporter.get_field = function(self, name)
    if name == "<RequestForceAutoWeaponOnOff>k__BackingField" then return G.force_req end
    error("no field " .. name)
end

-- base actions: category 0 = sheathed stance, 1 = katana stance, 2 = two-handed (bow)
local registry = { [0] = {}, [1] = {}, [2] = {} }
local next_action_addr = 0x100
local function action(cat, tname)
    next_action_addr = next_action_addr + 1
    local o = Obj(next_action_addr, tname, { get_OwnerCharacter = function() return objects_by_addr[0x1000] end })
    if cat ~= nil then
        table.insert(registry[cat], o)
        o._cat, o._idx = cat, #registry[cat] - 1
    end
    return o
end
local A = {
    basic_nothing = action(0, "app.PlayerBasicAction.cDoNothing"),
    basic_idle = action(0, "app.PlayerBasicAction.cIdle"),
    basic_run = action(0, "app.PlayerBasicAction.cRun"),
    basic_off = action(0, "app.PlayerBasicAction.cAutoWeaponOff"),
    one_nothing = action(1, "app.PlayerOneHandedAction.cDoNothing"),
    one_attack = action(1, "app.PlayerOneHandedAction.cAttackWeak1"),
    one_idle = action(1, "app.PlayerOneHandedAction.cIdle"),
    one_run = action(1, "app.PlayerOneHandedAction.cRun"),
    one_battle = action(1, "app.PlayerOneHandedAction.cBattleIdleLoop"),
    one_autoon = action(1, "app.PlayerOneHandedAction.cAutoWeaponOnIdle"),
    bow_start = action(2, "app.PlayerTwoHandedAction.cBowStart"),
    bow_loop = action(2, "app.PlayerTwoHandedAction.cBowLoop"),
    bow_shot = action(2, "app.PlayerTwoHandedAction.cBowShot"),
    bow_end = action(2, "app.PlayerTwoHandedAction.cBowEnd"),
    sub_nothing = action(nil, "app.PlayerOneHandedSubAction.cDoNothing"),
    sub_off_idle = action(nil, "app.PlayerOneHandedSubAction.cAutoWeaponOffIdle"),
    sub_on_idle = action(nil, "app.PlayerOneHandedSubAction.cAutoWeaponOnIdle"),
    enemy_act = action(nil, "app.Em100FullBodyAction.cBowAttackStand"),
}

local hooks = {}
local current_base = A.basic_idle
local base_ctrl
base_ctrl = Obj(0x3000, "ace.cActionController", {
    getActionNum = function(_, c) return #registry[c] end,
    ["getAction(System.Int32, System.Int32)"] = function(_, i, c) return registry[c] and registry[c][i + 1] end,
    ["getAction(ace.ACTION_ID)"] = function(_, vt)
        local c, i = vt:get_field("_Category"), vt:get_field("_Index")
        return registry[c] and registry[c][i + 1]
    end,
    get_CurrentActionID = function() return id_valuetype(current_base._cat, current_base._idx) end,
    get_CurrentAction = function() return current_base end,
    -- like the real thing, the mod's own call passes through the mod's own hook
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
}, { _ActionList = { call = function(_, n) if n == "get_Count" then return 3 end error("no method " .. n) end } })
local sub_ctrl = Obj(0x3100, "ace.cActionController", {})
local enemy_ctrl = Obj(0x3900, "ace.cActionController", {})
local character = Obj(0x1000, "app.PlayerCharacter", {
    get_BaseActionController = function() return base_ctrl end,
    get_SubActionController = function() return sub_ctrl end,
    get_BaseCurrentAction = function() return current_base end,
    get_SubCurrentAction = function() return A.sub_nothing end,
})
local sword = Obj(0x6001, "app.Gm800_000", { get_WeaponType = function() return 14 end, get_IsWeaponOn = function() return G.sword_on end })
local bow = Obj(0x6002, "app.Gm800_100", { get_WeaponType = function() return 99 end, get_IsWeaponOn = function() return G.bow_on end })
local empty_list = Obj(0x6100, "System.Collections.Generic.List`1<app.Gm800>", { get_Count = function() return 0 end })
local sword_data = Obj(0x6101, "app.cCharacterWeaponSupporter.cData", { get_WeaponGimmick = function() return sword end })
local bow_data = Obj(0x6102, "app.cCharacterWeaponSupporter.cData", { get_WeaponGimmick = function() return bow end })
local data_list = Obj(0x6103, "System.Collections.Generic.List`1<app.cCharacterWeaponSupporter.cData>", {
    get_Count = function() return 2 end,
    get_Item = function(_, i) return ({ sword_data, bow_data })[i + 1] end,
})
local weapon_supporter = Obj(0x6200, "app.cCharacterWeaponSupporter", {
    getWeaponGimmickEquipList = function() return empty_list end,
    get_WeaponDataList = function() return data_list end,
})
local entity = Obj(0x2000, "app.cPlayerCharacterEntity", {
    get_AutoWeaponOnOffSupporter = function() return supporter end,
    get_Weapon = function() return weapon_supporter end,
})
local info = Obj(0x2100, "app.PlayerManager.cPlayerInfo", {}, {
    ["<Character>k__BackingField"] = character,
    ["<CharacterEntity>k__BackingField"] = entity,
})
local player_manager = Obj(0x4000, "app.PlayerManager", { getControllingPlayerInfo = function() return info end })
local enemy_manager = Obj(0x4100, "app.EnemyManager", { isCheckBattleMode = function() return G.battle end })

-- fake REFramework API ---------------------------------------------------------
local tuple_name = "System.ValueTuple`2<app.cPlayerAutoWeaponOnOffSupporter.ONOFFTYPE,System.Boolean>"
local function tfield(tname, off) return { get_type = function() return { get_full_name = function() return tname end } end, get_offset_from_base = function() return off end } end
local return_type = {
    get_full_name = function() return tuple_name end,
    get_valuetype_size = function() return 8 end,
    get_field = function(_, n) if n == "Item1" then return tfield("app.cPlayerAutoWeaponOnOffSupporter.ONOFFTYPE", 16) else return tfield("System.Boolean", 20) end end,
}
local methods = {
    ["ace.cActionController|callActionEnter"] = { key = "enter", params = 2 },
    ["app.cPlayerAutoWeaponOnOffSupporter|getCheckWeaponOnOffType(app.cPlayerCommandResult)"] = { key = "check", params = 1, rt = return_type },
    ["app.PlayerTwoHandedAction.cBowBase|detailEnter"] = { key = "bow", params = 0 },
    ["app.CharacterBase|requestBaseAction(ace.ACTION_ID, app.CharacterDef.ACTION_REQUEST_CATEGORY)"] = { key = "req", params = 2 },
    ["app.CharacterBase|requestBaseActionWithArgument(ace.ACTION_ID, app.CharacterDef.ACTION_REQUEST_CATEGORY, app.cCharacterArgumentData)"] = { key = "reqarg", params = 3 },
    ["ace.cActionController|changeActionRequest(ace.ACTION_ID)"] = { key = "car_id", params = 1 },
    ["ace.cActionController|changeActionRequest(System.Int32, System.Int32)"] = { key = "car_ints", params = 2 },
    ["ace.cActionController|changeActionImmediate(ace.ACTION_ID, System.Boolean)"] = { key = "cai_id", params = 2 },
    ["ace.cActionController|changeActionImmediate(System.Int32, System.Int32, System.Boolean)"] = { key = "cai_ints", params = 3 },
    ["app.cPlayerActionSelector|selectActionEndAction"] = { key = "sel_end", params = 0 },
    ["app.cPlayerActionSelector|selectIdleAction"] = { key = "sel_idle", params = 0 },
    ["app.CharacterBase|requestSubAction(ace.ACTION_ID)"] = { key = "subreq", params = 1 },
}
local typedefs = {}
local function typedef(tn)
    if typedefs[tn] == nil then
        typedefs[tn] = {
            get_method = function(_, sig)
                local m = methods[tn .. "|" .. sig]
                if not m then return nil end
                return { _m = m, get_num_params = function() return m.params end, get_return_type = function() return m.rt end }
            end,
            get_field = function(_, n)
                if tn == "app.WeaponDef.TYPE" and n == "SWORD" then return { get_data = function() return 14 end } end
                return nil
            end,
        }
    end
    return typedefs[tn]
end
local ACTION_ID_T = typedef("ace.ACTION_ID")
sdk = {
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
    get_native_field = function(raw, t, n)
        if t == ACTION_ID_T then return mem[raw][n] end
        return raw[n]
    end,
    set_native_field = function(raw, t, n, v)
        if t == ACTION_ID_T then mem[raw][n] = v else raw[n] = v end
    end,
}
local app_entries = {}
re = {
    on_pre_application_entry = function(name, fn) app_entries[name] = fn end,
    on_draw_ui = function() end,
    on_script_reset = function() end,
}
imgui = {}
json = { load_file = function() return G.cfg end, dump_file = function(_, t) G.saved = t; return true end }
log = { info = function(s) G.log[#G.log + 1] = s; print("   LOG " .. s) end }
thread = { get_hook_storage = (function() local st = {} return function() return st end end)() }

-- load the script --------------------------------------------------------------
local function load_script()
    _G.bow_keeps_sheathed_loaded = nil
    hooks = {}
    assert(loadfile(script_path))()
    for _, k in ipairs({ "enter", "check", "bow", "req", "reqarg", "car_id", "car_ints", "cai_id", "cai_ints", "sel_end", "sel_idle", "subreq" }) do
        assert(hooks[k], "hook not installed: " .. k)
    end
end
G.cfg = { cut_bow_end = 1.5, debug = true }     -- A-M: let the bow-lowering animation play (the v2 behaviour)
load_script()

-- drivers ----------------------------------------------------------------------
local function enter(ctrl, act)       -- an action change that the callActionEnter hook sees
    if ctrl == base_ctrl then current_base = act end
    hooks.enter.pre({ nil, ctrl:get_address(), act:get_address(), 0 })
    hooks.enter.post(0)
end
local function frame(dt)
    advance(dt or 0.016)
    if G.pending_base ~= nil then current_base, G.pending_base = G.pending_base, nil end
    app_entries["UpdateBehavior"]()
end
local function silent(act, dt)        -- an action change that only polling can see
    current_base = act
    frame(dt)
end
-- the game asks for a base action through CharacterBase.requestBaseAction; returns the action that would start
local function game_request(act)
    local args = { nil, character:get_address(), id_ptr(act._cat, act._idx), 1 }
    hooks.req.pre(args)
    local m = mem[args[3]]
    hooks.req.post(1)
    return registry[m._Category][m._Index + 1]
end
local function check(direction)
    -- struct return: args[2] = return buffer, args[3] = this
    hooks.check.pre({ nil, 0xDEAD, supporter:get_address(), 0xBEEF })
    local rv = { Item1 = direction, Item2 = true }
    hooks.check.post(rv)
    return rv.Item1
end
local function expect(cond, msg) if cond then print("ok   " .. msg) else print("FAIL " .. msg); os.exit(1) end end
local function logged(text, from)
    for k = (from or 1), #G.log do if G.log[k]:find(text, 1, true) then return true end end
    return false
end
local function reset_game()
    G.weapon_on, G.battle, G.force_req, G.timer_forced, G.switch_target = false, false, 0, 0, nil
    G.switch_mode, G.switch_calls, G.pending_base, G.sword_on, G.bow_on = "reject", 0, nil, false, false
end

-- Scenarios A-G: the last-resort path (v1 behaviour). The direct switch is rejected by the fake
-- controller, so the script has to fall back to the sheathe request.

print("\n== A: sheathed before bow, out of combat (last-resort path)")
reset_game()
enter(enemy_ctrl, A.enemy_act)                     -- noise from an enemy controller
enter(base_ctrl, A.basic_run)
enter(base_ctrl, A.basic_idle)
enter(base_ctrl, A.bow_start); G.weapon_on = true   -- game now counts the bow as weapon on
enter(base_ctrl, A.bow_loop); frame(0.5)
enter(base_ctrl, A.bow_shot); frame(0.3)
enter(base_ctrl, A.bow_end); frame(0.4)
enter(base_ctrl, A.one_idle)                         -- the complaint: katana stance after the bow
expect(G.switch_calls == 1, "direct switch tried first")
expect(G.timer_forced == 1, "idle auto-sheathe timer was expired once")
expect(check(1) == 0, "auto-draw ON vetoed to NONE while armed")
expect(check(2) == 2, "OFF decision passes through untouched")
frame(0.2); expect(G.force_req == 0, "no explicit request before the fallback delay")
frame(0.2); expect(G.force_req == 2, "explicit OFF request sent after the fallback delay")
enter(sub_ctrl, A.sub_off_idle)                      -- game sheathes
G.weapon_on = false; G.force_req = 0
enter(base_ctrl, A.basic_idle)
expect(check(1) == 0, "still vetoing inside the grace window after the sheathe")
frame(3.0)
expect(check(1) == 1, "no veto once the grace window is over")

print("\n== B: katana out before bow")
reset_game(); G.weapon_on = true
enter(base_ctrl, A.one_idle)
enter(base_ctrl, A.bow_start); frame(0.5)
enter(base_ctrl, A.bow_end); frame(0.4)
enter(base_ctrl, A.one_idle); frame(1.0)
expect(G.timer_forced == 0 and G.force_req == 0 and G.switch_calls == 0, "nothing done when the katana was already out")
expect(check(1) == 1, "no veto when the katana was already out")

print("\n== C: sheathed before bow but enemies in battle mode")
reset_game(); G.battle = true
enter(base_ctrl, A.basic_idle)
enter(base_ctrl, A.bow_start); G.weapon_on = true; frame(0.5)
enter(base_ctrl, A.bow_end); frame(0.4)
enter(base_ctrl, A.one_idle); frame(1.0)
expect(G.timer_forced == 0 and G.force_req == 0 and G.switch_calls == 0, "nothing done in battle mode")

print("\n== D: sheathed before bow, attack right after")
reset_game()
enter(base_ctrl, A.basic_idle)
enter(base_ctrl, A.bow_start); G.weapon_on = true; frame(0.5)
enter(base_ctrl, A.bow_end); frame(0.4)
enter(base_ctrl, A.one_attack); frame(1.0)
expect(G.timer_forced == 0 and G.force_req == 0 and G.switch_calls == 0, "attack after the bow leaves the katana alone")
expect(check(1) == 1, "no veto after the player attacked")

print("\n== E: game auto-draws right before the bow")
reset_game()
enter(base_ctrl, A.basic_idle); frame(5.0)
enter(base_ctrl, A.one_autoon); G.weapon_on = true; frame(0.3)
enter(base_ctrl, A.bow_start); frame(0.5)
enter(base_ctrl, A.bow_end); frame(0.4)
enter(base_ctrl, A.one_idle)
expect(G.timer_forced == 1, "draw right before the bow is treated as sheathed-before")
frame(0.5); expect(G.force_req == 2, "fallback request sent")
frame(3.0)

print("\n== F: bow again right after the bow")
reset_game()
enter(base_ctrl, A.basic_idle)
enter(base_ctrl, A.bow_start); G.weapon_on = true
enter(base_ctrl, A.bow_end); frame(0.2)
enter(base_ctrl, A.one_idle)
expect(G.timer_forced == 1, "first sheathe attempt")
enter(base_ctrl, A.bow_start); frame(0.5)
enter(base_ctrl, A.bow_end); frame(0.2)
enter(base_ctrl, A.one_idle)
expect(G.timer_forced == 2, "second bow use also sheathes")
expect(not logged("by polling"), "no polling while the transition hook works")

print("\n== G: transition hook silent, polling fallback (what the real game does)")
frame(5.0)
reset_game()
current_base = A.basic_idle
load_script()
local mark = #G.log
frame()
silent(A.basic_run); silent(A.basic_idle)
silent(A.bow_start); G.weapon_on = true
silent(A.bow_loop, 0.5); silent(A.bow_shot, 0.3); silent(A.bow_end, 0.4)
silent(A.one_idle)
expect(logged("by polling", mark), "polling took over")
expect(G.timer_forced == 1, "poll: idle auto-sheathe timer was expired once")
expect(check(1) == 0, "poll: auto-draw ON vetoed to NONE while armed")
frame(0.2); frame(0.2); expect(G.force_req == 2, "poll: explicit OFF request sent after the fallback delay")
G.weapon_on = false; G.force_req = 0
silent(A.basic_idle)
frame(3.0)

-- Scenarios H-M: the v2 paths, all in polling mode like the real game.

print("\n== H: redirect, the request for the katana stance becomes the sheathed stance")
reset_game(); mark = #G.log
silent(A.basic_idle)
silent(A.bow_start); G.weapon_on = true
silent(A.bow_shot, 0.3); silent(A.bow_end, 0.5)
expect(game_request(A.one_attack) == A.one_attack, "an attack request during the bow is left alone")
local started = game_request(A.one_idle)
expect(started == A.basic_idle, "idle request redirected to the sheathed idle")
expect(game_request(A.one_run) == A.basic_run, "run request redirected to the sheathed run")
expect(game_request(A.one_battle) == A.one_battle, "battle idle has no sheathed twin and is left alone")
silent(started)
expect(logged("redirect via requestBaseAction", mark), "redirect logged")
expect(logged("sheathed stance reached", mark), "sheathed stance reached without a sheathe animation")
expect(G.timer_forced == 0 and G.force_req == 0 and G.switch_calls == 0, "no timer trick, no sheathe request, no direct switch")
expect(game_request(A.one_idle) == A.one_idle, "no redirect once the bow is over")
frame(3.0)

print("\n== H2: no redirect when the katana was out, or in battle mode")
reset_game(); G.weapon_on = true
silent(A.one_idle)
silent(A.bow_start); silent(A.bow_end, 0.5)
expect(game_request(A.one_idle) == A.one_idle, "katana was out: request untouched")
silent(A.one_idle); frame(1.0)
reset_game(); G.battle = true
silent(A.basic_idle)
silent(A.bow_start); silent(A.bow_end, 0.5)
expect(game_request(A.one_idle) == A.one_idle, "battle mode: request untouched")
silent(A.one_idle); frame(1.0)

print("\n== I: request not seen by the hooks, direct switch accepted")
reset_game(); G.switch_mode = "accept"; mark = #G.log
silent(A.basic_idle)
silent(A.bow_start); G.weapon_on = true
silent(A.bow_end, 0.5)
silent(A.one_idle)
expect(G.switch_calls == 1, "direct switch requested")
frame()
expect(current_base == A.basic_idle, "the fake game switched to the sheathed idle")
expect(logged("sheathed stance reached", mark), "sheathed stance reached")
frame(0.5)
expect(G.timer_forced == 0 and G.force_req == 0, "no sheathe request needed")
frame(3.0)

print("\n== J: direct switch accepted but without effect, sheathe request takes over")
reset_game(); G.switch_mode = "ignore"; mark = #G.log
silent(A.basic_idle)
silent(A.bow_start); G.weapon_on = true
silent(A.bow_end, 0.5)
silent(A.one_idle)
expect(G.switch_calls == 1 and G.timer_forced == 0, "direct switch tried, nothing else yet")
frame(0.3)
expect(logged("direct switch had no effect", mark), "ineffective switch noticed")
expect(G.timer_forced == 1, "timer trick used")
frame(0.4); expect(G.force_req == 2, "sheathe request sent")
G.weapon_on = false; G.force_req = 0
silent(A.basic_idle); frame(3.0)

print("\n== K: auto cut, the katana starts to come out while the bow is lowered")
reset_game(); G.switch_mode = "accept"; mark = #G.log
silent(A.basic_idle)
silent(A.bow_start); G.weapon_on = true; G.bow_on = true
silent(A.bow_end, 0.5)
frame(0.1); frame(0.1)
expect(G.switch_calls == 0, "no cut while the katana is still off")
G.sword_on = true
frame()
expect(G.switch_calls == 1, "cut requested when the katana switched on")
expect(logged("katana started to come out", mark), "cut reason logged")
expect(logged("weapon Gm800_000#14 on=true", mark), "katana on/off change logged")
frame()
expect(current_base == A.basic_idle, "the fake game cut to the sheathed idle")
expect(logged("sheathed stance reached", mark), "sheathed stance reached after the cut")
frame(3.0)

print("\n== M: the selector's own pick is rewritten while the bow is lowered")
reset_game()
silent(A.basic_idle)
silent(A.bow_start); G.weapon_on = true
local p0 = id_ptr(A.one_idle._cat, A.one_idle._idx)
expect(hooks.sel_end.post(p0) == p0 and mem[p0]._Category == A.one_idle._cat, "not touched before the bow-lowering action")
silent(A.bow_end, 0.5)
local p1 = id_ptr(A.one_idle._cat, A.one_idle._idx)
expect(hooks.sel_end.post(p1) == p1, "pointer return value kept")
expect(mem[p1]._Category == A.basic_idle._cat and mem[p1]._Index == A.basic_idle._idx, "pointed-to id rewritten to the sheathed idle")
local packed = (A.one_idle._idx << 32) | A.one_idle._cat
expect(hooks.sel_idle.post(packed) == ((A.basic_idle._idx << 32) | A.basic_idle._cat), "packed return value rewritten to the sheathed idle")
expect(hooks.sel_idle.post(-1) == -1, "invalid id (-1) passes through untouched")
expect(hooks.sel_idle.post(0) == 0, "null passes through untouched")
silent(A.basic_idle); frame(3.0)

-- Scenarios N-Q: v3 defaults, the bow-lowering animation is skipped.
G.cfg = { debug = true }          -- the checks below read the script's log lines
current_base = A.basic_idle
load_script()

print("\n== N: skip, the request for the bow-lowering action becomes the sheathed idle")
reset_game(); mark = #G.log
frame()
silent(A.basic_idle)
silent(A.bow_start); G.weapon_on = true
silent(A.bow_shot, 0.9)
expect(logged("verified", mark) and not logged("NOT verified", mark), "action table verified against the running action")
expect(game_request(A.bow_loop) == A.bow_loop, "another bow action is left alone")
started = game_request(A.bow_end)
expect(started == A.basic_idle, "bow-lowering request redirected to the sheathed idle")
silent(started)
expect(logged("redirect via requestBaseAction: TwoHandedAction.cBowEnd -> BasicAction.cIdle", mark), "skip logged")
expect(logged("sheathed stance reached", mark), "sheathed stance reached")
expect(G.switch_calls == 0 and G.timer_forced == 0 and G.force_req == 0, "no direct switch, no sheathe request")
frame(3.0)

print("\n== N2: no skip when the katana was out, or in battle mode")
reset_game(); G.weapon_on = true
silent(A.one_idle)
silent(A.bow_start); silent(A.bow_shot, 0.6)
expect(game_request(A.bow_end) == A.bow_end, "katana was out: bow-lowering plays")
silent(A.bow_end, 0.5); silent(A.one_idle); frame(1.0)
expect(G.switch_calls == 0, "katana was out: nothing switched")
reset_game(); G.battle = true
silent(A.basic_idle)
silent(A.bow_start); silent(A.bow_shot, 0.6)
expect(game_request(A.bow_end) == A.bow_end, "battle mode: bow-lowering plays")
silent(A.bow_end, 0.5); silent(A.one_idle); frame(1.0)
expect(G.switch_calls == 0, "battle mode: nothing switched")

print("\n== O: the bow-lowering action starts anyway, left in the next frame")
reset_game(); G.switch_mode = "accept"; mark = #G.log
silent(A.basic_idle)
silent(A.bow_start); G.weapon_on = true
silent(A.bow_shot, 0.6)
silent(A.bow_end)
expect(G.switch_calls == 1 and G.switch_target == A.basic_idle, "direct switch to the sheathed idle (index, category order)")
frame()
expect(current_base == A.basic_idle, "the fake game left the bow-lowering action")
expect(logged("sheathed stance reached", mark), "sheathed stance reached")
frame(3.0)

print("\n== P: katana-out time is measured when the animation plays")
reset_game(); G.weapon_on = true; mark = #G.log; G.saved = nil
silent(A.one_idle)
silent(A.bow_start); G.bow_on = true
silent(A.bow_shot, 0.6)
silent(A.bow_end)
frame(0.2); frame(0.2)
G.sword_on = true
frame(0.05)
expect(logged("measured: the katana switches on", mark), "time measured")
expect(G.saved ~= nil and math.abs(G.saved.katana_on_at - 0.45) < 0.03, "time saved to the settings file")
expect(G.switch_calls == 0, "katana was out: no cut")
silent(A.one_idle); frame(1.0)

print("\n== Q: integer hooks use (index, category)")
reset_game()
silent(A.basic_idle)
silent(A.bow_start); G.weapon_on = true
silent(A.bow_shot, 0.6)
local iargs = { nil, base_ctrl:get_address(), A.bow_end._idx, A.bow_end._cat }
hooks.car_ints.pre(iargs); hooks.car_ints.post(1)
expect(iargs[3] == A.basic_idle._idx and iargs[4] == A.basic_idle._cat, "bow-lowering request rewritten in (index, category) order")
silent(A.basic_idle); frame(3.0)

print("\nall scenarios passed")
