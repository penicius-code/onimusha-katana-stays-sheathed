-- Bow Keeps Sheathed v3.1 (2026-11-13)
-- After Musashi lowers the bow, the game drops him into the one-handed stance, i.e. the
-- katana is in his hand even if it was sheathed before he drew the bow.
-- This script remembers whether the katana was out when the bow came up. If it was not:
--
--   1. REDIRECT (main path): while the bow is active, every request for a calm katana-stance
--      action (idle / walk / run / dash family) is swapped for its sheathed-stance twin
--      (app.PlayerOneHandedAction.cIdle -> app.PlayerBasicAction.cIdle, ...). The katana is
--      never drawn. Intercepted at:
--        app.CharacterBase.requestBaseAction / requestBaseActionWithArgument
--        ace.cActionController.changeActionRequest / changeActionImmediate (both overloads)
--        app.cPlayerActionSelector.selectActionEndAction / selectIdleAction (return value)
--   2. SKIP / CUT: the bow-lowering action (cBowEnd) contains the katana draw animation
--      (seen in game with v2: "the animation plays then the sword goes back to sheathed").
--      So by default it is skipped: the request for cBowEnd itself becomes the sheathed idle.
--      With "cut_bow_end" > 0 it plays for that long first, and with auto cut it also stops
--      the moment the katana object switches to "on".
--   3. DIRECT SWITCH (fallback): if the bow still ended in the katana stance, ask the action
--      controller for the sheathed twin right away.
--   4. SHEATHE REQUEST (last resort, the v1 behaviour): set_RequestForceAutoWeaponOnOff(OFF),
--      which plays the normal sheathe animation.
--
-- Findings in game (2026-11-13):
--   v1: ace.cActionController.callActionEnter never fires for the player, so action changes
--       are followed by polling get_BaseCurrentAction() once per frame.
--   v2: the game's (Int32, Int32) action methods take (index, category), not (category, index).
--       Base categories: 0 PlayerBasicAction, 1 BasicDamageAction, 2 PlayerOneHandedAction,
--       4 PlayerTwoHandedAction. cIdle is index 1 in both stances, cBowShot 4/66, cBowEnd 4/68.
--       End of cBowEnd: selectIdleAction -> requestBaseAction -> changeActionRequest(ACTION_ID).
--       changeActionRequest to PlayerBasicAction.cIdle is accepted and shows the katana sheathed.
--
-- Menu: Insert -> Script Generated UI -> Bow Keeps Sheathed
-- Settings: reframework/data/bow_keeps_sheathed.json
-- Debug lines go to re2_framework_log.txt with the prefix [BowKeepsSheathed].

if _G.bow_keeps_sheathed_loaded then return end
_G.bow_keeps_sheathed_loaded = true

local CONFIG_FILE = "bow_keeps_sheathed.json"
local TAG = "[BowKeepsSheathed] "
local VERSION = "3.1"

local cfg = {
    enabled = true,
    respect_combat = true,   -- do nothing when enemies are in battle mode (the game would draw anyway)
    redirect = true,         -- go straight to the sheathed stance when the bow ends (no draw at all)
    cut_bow_end = 0.0,       -- seconds the bow-lowering animation may play before the sheathed idle (0 = skip it)
    auto_cut = true,         -- when it plays: stop it the moment the katana starts to come out
    katana_on_at = 0.0,      -- measured: seconds into the bow-lowering animation at which the katana switches on
    early_timer = false,     -- expire the auto-sheathe timer already while the bow is being lowered
    grace = 2.5,             -- seconds after the bow ends during which auto-draw is vetoed
    fallback_delay = 0.35,   -- seconds after the timer trick before the explicit OFF request is sent
    debug = false,           -- write transitions and decisions to the REFramework log (off since v3 works in game)
}

local ONOFF_NONE, ONOFF_ON, ONOFF_OFF = 0, 1, 2
local BASIC_IDLE = "app.PlayerBasicAction.cIdle"
local BOW_END = "app.PlayerTwoHandedAction.cBowEnd"

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

local function load_cfg()
    local saved = safe(json.load_file, CONFIG_FILE)
    if type(saved) ~= "table" then return end
    for k, v in pairs(cfg) do
        if type(saved[k]) == type(v) then cfg[k] = saved[k] end
    end
    if cfg.grace < 0.5 then cfg.grace = 0.5 elseif cfg.grace > 8 then cfg.grace = 8 end
    if cfg.fallback_delay < 0 then cfg.fallback_delay = 0 elseif cfg.fallback_delay > 2 then cfg.fallback_delay = 2 end
    if cfg.cut_bow_end < 0 then cfg.cut_bow_end = 0 elseif cfg.cut_bow_end > 2 then cfg.cut_bow_end = 2 end
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
local status = { install = "not installed", tuple = "n/a" }

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
    base_ctrl = 0, sub_ctrl = 0, supporter_addr = 0, character_addr = 0,
    resolved_at = -100, last_base_action = nil, last_sub_action = nil, cache = nil,
}

-- Returns {character, entity, supporter, base, sub} or nil. Also refreshes the cached addresses.
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
    local supporter = call(entity, "get_AutoWeaponOnOffSupporter")
    if supporter == nil then return nil end
    local base = call(character, "get_BaseActionController")
    local sub = call(character, "get_SubActionController")
    local character_addr = addr(character)
    if character_addr ~= P.character_addr then
        -- new player object (first resolve, respawn, area change): seed the action names
        P.last_base_action = type_name(call(character, "get_BaseCurrentAction"))
        P.last_sub_action = type_name(call(character, "get_SubCurrentAction"))
        if P.character_addr ~= 0 then note("player object changed, state reset") end
    end
    P.character_addr = character_addr
    P.base_ctrl = addr(base)
    P.sub_ctrl = addr(sub)
    P.supporter_addr = addr(supporter)
    P.cache = { character = character, entity = entity, supporter = supporter, base = base, sub = sub }
    return P.cache
end
-- the objects resolved during this tick, or a fresh resolve
local function player()
    if P.cache ~= nil and now() - P.resolved_at < 0.004 then return P.cache end
    return resolve_player()
end

local function in_battle()
    local enemies = safe(sdk.get_managed_singleton, "app.EnemyManager")
    local v = call(enemies, "isCheckBattleMode")
    return v == true
end

-------------------------------------------------------------------------------
-- action classification
-------------------------------------------------------------------------------
local function is_bow(name) return name ~= nil and name:find("^app%.PlayerTwoHandedAction%.cBow") ~= nil end
local function is_basic(name) return name ~= nil and name:find("^app%.PlayerBasicAction%.") ~= nil end
local function is_onehanded(name) return name ~= nil and name:find("^app%.PlayerOneHandedAction%.") ~= nil end
local function is_auto_on(name) return name ~= nil and name:find("cAutoWeaponOn", 1, true) ~= nil end
local function is_auto_off(name) return name ~= nil and name:find("cAutoWeaponOff", 1, true) ~= nil end

-- One-handed actions in which an automatic sheathe is appropriate (standing / moving, no attack).
local CALM_ONEHANDED = {
    "^app%.PlayerOneHandedAction%.cIdle$",
    "^app%.PlayerOneHandedAction%.cBattleIdle",
    "^app%.PlayerOneHandedAction%.cWalk",
    "^app%.PlayerOneHandedAction%.cRun",
    "^app%.PlayerOneHandedAction%.cDash",
    "^app%.PlayerOneHandedAction%.cStrafe",
    "^app%.PlayerOneHandedAction%.cAutoWeaponOnIdle$",
    "^app%.PlayerOneHandedAction%.cVacuumIdle",
}
local function is_calm_onehanded(name)
    if name == nil then return false end
    for _, pat in ipairs(CALM_ONEHANDED) do
        if name:find(pat) then return true end
    end
    return false
end

-------------------------------------------------------------------------------
-- action tables: ACTION_ID (category, index) <-> action class name, per controller
-------------------------------------------------------------------------------
local T_ACTION_ID = safe(sdk.find_type_definition, "ace.ACTION_ID")
local function new_action_table(label)
    return { label = label, ctrl = 0, by_name = {}, by_id = {}, count = 0, tried_at = -100, status = "not read yet" }
end
local A = new_action_table("base")      -- the player's base action controller
local Asub = new_action_table("sub")    -- the player's sub action controller (diagnostics only)
local function id_key(c, i) return c * 65536 + i end

local function read_id(vt)   -- ValueType ace.ACTION_ID -> category, index
    local c, i = field(vt, "_Category"), field(vt, "_Index")
    if type(c) == "number" and type(i) == "number" then return c, i end
    return nil
end

local function build_actions(tbl, ctrl)
    local a = addr(ctrl)
    if a == 0 then return false end
    if tbl.ctrl == a and (tbl.count > 0 or now() - tbl.tried_at < 5.0) then return tbl.count > 0 end
    tbl.ctrl, tbl.by_name, tbl.by_id, tbl.count, tbl.tried_at = a, {}, {}, 0, now()
    local ncat = call(field(ctrl, "_ActionList"), "get_Count")
    if type(ncat) ~= "number" or ncat < 1 or ncat > 64 then
        tbl.status = "action list not readable"
        note("action table (" .. tbl.label .. "): " .. tbl.status)
        return false
    end
    -- The (Int32, Int32) overload takes (index, category). Prefer the ACTION_ID overload, where
    -- the two numbers are named, and only fall back to the integers.
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
                    tbl.by_id[id_key(c, i)] = name
                    if tbl.by_name[name] == nil then tbl.by_name[name] = { c = c, i = i } end
                    tbl.count = tbl.count + 1
                end
            end
        end
    end
    -- cross-check with the action that is running right now
    local cc, ci = read_id(call(ctrl, "get_CurrentActionID"))
    local cur = type_name(call(ctrl, "get_CurrentAction"))
    local verified = cc ~= nil and cur ~= nil and tbl.by_id[id_key(cc, ci)] == cur
    tbl.verified = verified
    tbl.status = string.format("%d actions in %d categories, %s%s", tbl.count, ncat, verified and "verified" or "NOT verified",
        by_struct and "" or " (integer lookup)")
    note(string.format("action table (%s): %s  [current %s id=%s,%s]", tbl.label, tbl.status, short(cur), tostring(cc), tostring(ci)))
    return tbl.count > 0
end

-- sheathed-stance twin of a calm katana-stance action (idle / walk / run / dash family), or nil
local function basic_twin(name)
    if name == nil then return nil end
    local s = name:match("^app%.PlayerOneHandedAction%.(c[%w_]+)$")
    if s == nil then return nil end
    if not (s == "cIdle" or s:find("^cWalk") or s:find("^cRun") or s:find("^cDash")) then return nil end
    local target = "app.PlayerBasicAction." .. s
    if A.by_name[target] ~= nil then return target end
    return nil
end

-------------------------------------------------------------------------------
-- state machine
-------------------------------------------------------------------------------
-- idle    : nothing pending
-- in_bow  : a cBow* base action is running; S.was_out says whether the katana was out before it
-- armed   : bow ended with the katana previously sheathed; keep it sheathed until the grace window ends
local S = {
    state = "idle", was_out = nil, bow_started_at = 0, bow_ended_at = 0, action_at = 0,
    guard_until = 0, fallback_due = nil, acted = false, request_sent = false, done = false,
    last_auto_on_at = -100, vetoes = 0, cycles = 0, sheathed_ok = 0,
    redirects = 0, redirect_total = 0, seen = {}, seen_n = 0, combat_noted = false,
    bow_end_at = nil, cut_done = false, sword_prev = nil,
    switch_tried = false, switch_check = nil,
}
local function reset_attempts()
    S.fallback_due, S.switch_check = nil, nil
    S.acted, S.request_sent, S.done, S.switch_tried = false, false, false, false
end
local function reset_cycle()
    S.state, S.was_out = "idle", nil
    S.bow_end_at, S.cut_done, S.sword_prev = nil, false, nil
    reset_attempts()
end

local function combat_blocks()
    return cfg.respect_combat and in_battle()
end
local function want_redirect()
    return cfg.enabled and cfg.redirect and S.state == "in_bow" and S.was_out == false
end

-- one log line per distinct request during a bow cycle
local function diag(api, name, c, i)
    if not cfg.debug or S.seen_n >= 40 then return end
    local key = api .. "|" .. tostring(c) .. "," .. tostring(i)
    if S.seen[key] then return end
    S.seen[key] = true
    S.seen_n = S.seen_n + 1
    note(string.format("request %s: %s (%s,%s) during %s +%.2fs", api, short(name), tostring(c), tostring(i),
        short(P.last_base_action), now() - S.action_at))
end

-- Called for every base action request of the player while a bow cycle is active.
-- Returns the category and index to use instead, or nil.
local function pick_redirect(api, c, i)
    local name = A.by_id[id_key(c, i)]
    diag(api, name, c, i)
    if name == nil or not want_redirect() or not A.verified then return nil end
    local target
    if name == BOW_END then
        -- the bow-lowering action draws the katana: skip it unless it is allowed to play for a while
        if cfg.cut_bow_end > 0 or A.by_name[BASIC_IDLE] == nil then return nil end
        target = BASIC_IDLE
    else
        target = basic_twin(name)
    end
    if target == nil then return nil end
    if combat_blocks() then
        if not S.combat_noted then S.combat_noted = true; note("enemies in battle mode, not redirecting " .. short(name)) end
        return nil
    end
    local t = A.by_name[target]
    S.redirects = S.redirects + 1
    S.redirect_total = S.redirect_total + 1
    if S.redirects == 1 then note(string.format("redirect via %s: %s -> %s", api, short(name), short(target))) end
    return t.c, t.i
end

-- Ask the base action controller for a sheathed-stance action ourselves.
local function switch_to(target, reason)
    local p = player()
    local t = A.by_name[target]
    if p == nil or p.base == nil or t == nil or not A.verified then
        note("direct switch not possible (" .. reason .. "): " .. ((t == nil or not A.verified) and ("action table: " .. A.status) or "player not resolvable"))
        return false
    end
    -- (index, category): this order is what the game accepted in the v2 test
    local ok, accepted = pcall(function() return p.base:call("changeActionRequest(System.Int32, System.Int32)", t.i, t.c) end)
    note(string.format("direct switch to %s (%s): ok=%s accepted=%s", short(target), reason, tostring(ok), tostring(accepted)))
    return ok and accepted ~= false
end

local function act_sheathe(reason)
    S.acted = true
    local p = player()
    if p == nil then note("act_sheathe: player not resolvable (" .. reason .. ")"); return end
    local won = call(p.supporter, "isWeaponOn")
    if won ~= true then
        note("act_sheathe skipped, isWeaponOn=" .. tostring(won) .. " (" .. reason .. ")")
        S.done = true
        return
    end
    local ok = pcall(function() p.supporter:call("forceTimeOutOneHandIdleWeaponOffTimer") end)
    note(string.format("sheathe: idle auto-sheathe timer expired (%s) ok=%s; fallback request in %.2fs", reason, tostring(ok), cfg.fallback_delay))
    S.fallback_due = now() + cfg.fallback_delay
end

local function send_fallback_request()
    S.fallback_due = nil
    if S.request_sent then return end
    local p = player()
    if p == nil then return end
    local won = call(p.supporter, "isWeaponOn")
    if won ~= true then
        note("fallback not needed, isWeaponOn=" .. tostring(won))
        S.done = true
        return
    end
    if not is_calm_onehanded(P.last_base_action) then
        note("fallback skipped, player busy in " .. tostring(P.last_base_action))
        return
    end
    local pending = field(p.supporter, "<RequestForceAutoWeaponOnOff>k__BackingField")
    if pending ~= nil and pending ~= 0 then
        note("fallback skipped, a force request is already pending (" .. tostring(pending) .. ")")
        return
    end
    local ok = pcall(function() p.supporter:call("set_RequestForceAutoWeaponOnOff", ONOFF_OFF) end)
    S.request_sent = true
    note("fallback: set_RequestForceAutoWeaponOnOff(OFF) ok=" .. tostring(ok))
end

local function handle_post_bow_action(name)
    if is_basic(name) then
        local first = not S.done
        if first then S.done = true; S.sheathed_ok = S.sheathed_ok + 1 end
        S.switch_check, S.fallback_due = nil, nil
        if is_auto_off(name) then note("sheathing (base " .. name .. ")")
        elseif first then note("sheathed stance reached: " .. name) end
    elseif is_calm_onehanded(name) then
        if S.acted then return end
        local twin = (cfg.redirect and not S.switch_tried) and basic_twin(name) or nil
        if twin ~= nil then
            S.switch_tried = true
            if switch_to(twin, "bow ended in " .. short(name)) then
                S.switch_check = now() + 0.25
                return
            end
        end
        act_sheathe("entered " .. name)
    elseif is_bow(name) then
        note("bow drawn again, still counting the katana as sheathed")
        S.state = "in_bow"
        S.bow_end_at, S.cut_done, S.sword_prev = nil, false, nil
        reset_attempts()
    else
        note("player busy (" .. name .. "), leaving the katana alone")
        reset_cycle()
    end
end

-- weapon objects (katana, sheath, bow ...): log when one switches on/off during a bow cycle
local SWORD_TYPE = safe(function() return sdk.find_type_definition("app.WeaponDef.TYPE"):get_field("SWORD"):get_data(nil) end)
local Wp = { last = {}, unreadable = false }
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
-- All weapon objects (app.Gm800) of the player: katana, sheath, bow, quiver ...
local function weapon_objects(p)
    local ws = call(p.entity, "get_Weapon")
    local out = {}
    local data = call(ws, "get_WeaponDataList")
    local n, kind = list_len(data)
    if n ~= nil then
        for k = 0, math.min(n, 24) - 1 do
            local g = call(list_at(data, k, kind), "get_WeaponGimmick")
            if g ~= nil then out[#out + 1] = g end
        end
    end
    if #out == 0 then
        local list = call(ws, "getWeaponGimmickEquipList")
        n, kind = list_len(list)
        if n ~= nil then
            for k = 0, math.min(n, 24) - 1 do
                local g = list_at(list, k, kind)
                if g ~= nil then out[#out + 1] = g end
            end
        end
    end
    if #out == 0 and SWORD_TYPE ~= nil then
        local g = call(ws, "getWeaponGimmick(app.WeaponDef.TYPE)", SWORD_TYPE)
        if g ~= nil then out[1] = g end
    end
    return out
end
-- Returns the katana's on-state (true / false / nil when unknown).
local function sample_weapons(log_all)
    local p = player()
    if p == nil then return nil end
    local list = weapon_objects(p)
    if #list == 0 then
        if not Wp.unreadable then
            Wp.unreadable = true
            note("no weapon objects found, katana on/off cannot be logged and auto cut cannot work")
        end
        return nil
    end
    local sword_on, parts = nil, {}
    for _, g in ipairs(list) do
        local wt = call(g, "get_WeaponType")
        local on = call(g, "get_IsWeaponOn")
        local key = (tostring(type_name(g)):gsub("^app%.", "")) .. "#" .. tostring(wt)
        -- v3 in game: the player's list holds one object, app.Gm800_000 with weapon type 0, and a plain
        -- "wt == SWORD_TYPE" did not match it (different Lua types), so compare as text and by class.
        local is_sword = (SWORD_TYPE ~= nil and tostring(wt) == tostring(SWORD_TYPE)) or type_name(g) == "app.Gm800_000"
        if is_sword and sword_on ~= true then sword_on = on end
        if log_all then
            parts[#parts + 1] = key .. "=" .. tostring(on)
        elseif Wp.last[key] ~= nil and Wp.last[key] ~= on then
            note(string.format("weapon %s on=%s during %s +%.2fs", key, tostring(on), short(P.last_base_action), now() - S.action_at))
        end
        Wp.last[key] = on
    end
    if log_all then note("weapons (sword type=" .. tostring(SWORD_TYPE) .. "): " .. table.concat(parts, "  ")) end
    return sword_on
end

local W = { hook_seen = false, poll_hits = 0, enter_calls = 0 }

local function on_base_enter(name)
    local prev = P.last_base_action
    P.last_base_action = name
    S.action_at = now()
    if is_auto_on(name) then S.last_auto_on_at = now() end

    if S.state == "in_bow" then
        if is_bow(name) then
            if cfg.debug then note("bow: " .. name) end
            if name == BOW_END then
                S.bow_end_at, S.sword_prev = now(), nil
                if want_redirect() and cfg.cut_bow_end <= 0 and not S.cut_done and not combat_blocks() then
                    -- the request for it was not redirected: leave it right away
                    S.cut_done = true
                    switch_to(BASIC_IDLE, "skipping the bow-lowering animation")
                end
                if cfg.enabled and cfg.early_timer and S.was_out == false and not combat_blocks() then
                    local p = player()
                    if p ~= nil then
                        local ok = pcall(function() p.supporter:call("forceTimeOutOneHandIdleWeaponOffTimer") end)
                        note("early: idle auto-sheathe timer expired at cBowEnd ok=" .. tostring(ok))
                    end
                end
            end
            return
        end
        -- bow ended
        S.bow_ended_at = now()
        S.cycles = S.cycles + 1
        local tail = string.format(" [redirects=%d]", S.redirects)
        if not cfg.enabled then
            note("bow ended -> " .. name .. " (disabled, nothing to do)")
            reset_cycle(); return
        end
        if S.was_out ~= false then
            note("bow ended -> " .. name .. " (katana was out before, nothing to do)")
            reset_cycle(); return
        end
        if combat_blocks() then
            note("bow ended -> " .. name .. " (in battle mode, leaving the game's auto-draw alone)")
            reset_cycle(); return
        end
        S.state = "armed"
        S.guard_until = now() + cfg.grace
        S.vetoes = 0
        note("bow ended -> " .. name .. " (katana was sheathed before -> keep it sheathed)" .. tail)
        handle_post_bow_action(name)
        return
    end

    if is_bow(name) then
        -- bow begins: decide whether the katana was out before it
        local p = player()
        if p ~= nil then
            build_actions(A, p.base)
            build_actions(Asub, p.sub)
        end
        local won = p and call(p.supporter, "isWeaponOn")
        local was_out, how
        if is_basic(prev) then was_out, how = false, "previous action was sheathed stance"
        elseif is_onehanded(prev) then was_out, how = true, "previous action was katana stance"
        else was_out, how = (won == true), "from isWeaponOn" end
        if was_out and (now() - S.last_auto_on_at) < 0.75 then
            was_out, how = false, "auto-draw happened right before the bow, counted as sheathed"
        end
        if was_out and S.state == "armed" then
            was_out, how = false, "bow drawn again inside the keep-sheathed window, still counted as sheathed"
        end
        S.state, S.was_out, S.bow_started_at = "in_bow", was_out, now()
        S.bow_end_at, S.cut_done, S.sword_prev = nil, false, nil
        S.redirects, S.seen, S.seen_n, S.combat_noted = 0, {}, 0, false
        reset_attempts()
        note(string.format("bow start: %s  prev=%s  isWeaponOn=%s  was_out=%s (%s)  [v%s redirect=%s table=%s enterHookCalls=%d]",
            name, tostring(prev), tostring(won), tostring(was_out), how, VERSION, tostring(cfg.redirect), A.status, W.enter_calls))
        if cfg.debug then
            Wp.last = {}
            pcall(sample_weapons, true)
        end
        return
    end

    if S.state == "armed" then
        handle_post_bow_action(name)
    end
end

local function on_sub_enter(name)
    P.last_sub_action = name
    if is_auto_on(name) then
        S.last_auto_on_at = now()
        if S.state == "armed" then note("game draws via sub action " .. name .. " while armed") end
    elseif is_auto_off(name) and S.state == "armed" then
        note("sheathing (sub " .. name .. ")")
        if not S.done then S.done = true; S.sheathed_ok = S.sheathed_ok + 1 end
    elseif S.state ~= "idle" and cfg.debug then
        note("sub action: " .. short(name))
    end
end

-- Fallback for a silent callActionEnter hook: until the hook has delivered its first player
-- transition, read the player's current actions once per frame and feed changes to the state
-- machine. As soon as the hook proves itself, this stops and costs nothing.
local function poll_transitions()
    local p = resolve_player()
    if p == nil then return end
    local name = type_name(call(p.character, "get_BaseCurrentAction"))
    if name ~= nil and name ~= P.last_base_action then
        W.poll_hits = W.poll_hits + 1
        if W.poll_hits == 1 then note("callActionEnter hook silent so far, following the player's actions by polling") end
        on_base_enter(name)
    end
    local sub = type_name(call(p.character, "get_SubCurrentAction"))
    if sub ~= nil and sub ~= P.last_sub_action then on_sub_enter(sub) end
end

-- While the bow-lowering action runs: measure when the katana switches on (any cycle, also
-- when the katana was out before), and cut the action short when that is wanted.
local function check_cut(sword_on)
    if S.bow_end_at == nil or P.last_base_action ~= BOW_END then return end
    local prev = S.sword_prev
    S.sword_prev = sword_on
    local elapsed = now() - S.bow_end_at
    local flipped = prev == false and sword_on == true
    if flipped then
        note(string.format("measured: the katana switches on %.2fs into the bow-lowering animation", elapsed))
        if math.abs(cfg.katana_on_at - elapsed) > 0.02 then
            cfg.katana_on_at = elapsed
            save_cfg()
        end
    end
    if S.cut_done or not want_redirect() then return end
    local why = nil
    if cfg.cut_bow_end > 0 and elapsed >= cfg.cut_bow_end then
        why = string.format("played for %.2fs", elapsed)
    elseif cfg.auto_cut and flipped then
        why = string.format("katana started to come out at %.2fs", elapsed)
    end
    if why == nil or combat_blocks() then return end
    S.cut_done = true
    switch_to(BASIC_IDLE, why)
end

-- called once per game update (pre UpdateBehavior); cheap when nothing is pending
local function tick()
    if not W.hook_seen then pcall(poll_transitions) end
    local t = now()
    if S.state == "idle" then
        -- keep the action table ready so the first bow does not have to build it
        if P.base_ctrl ~= 0 and A.ctrl ~= P.base_ctrl and t - A.tried_at > 1.0 then
            local p = player()
            if p ~= nil then
                build_actions(A, p.base)
                build_actions(Asub, p.sub)
            end
        end
        return
    end
    local sword_on = nil
    -- the katana's state only matters while the bow-lowering action plays
    if cfg.debug or P.last_base_action == BOW_END then sword_on = safe(sample_weapons, false) end
    if S.state == "in_bow" then
        check_cut(sword_on)
        return
    end
    -- armed
    if t > S.guard_until then
        note(string.format("grace window over (vetoes=%d, sheathed=%s)", S.vetoes, tostring(S.done)))
        reset_cycle()
        return
    end
    if S.switch_check ~= nil and t >= S.switch_check then
        S.switch_check = nil
        if not is_basic(P.last_base_action) and not S.acted then
            note("direct switch had no effect (still " .. short(P.last_base_action) .. "), using the sheathe request")
            act_sheathe("direct switch failed")
        end
    end
    if S.fallback_due ~= nil and t >= S.fallback_due then
        send_fallback_request()
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

local hooks = {}

-- An ace.ACTION_ID argument or return value is either a pointer to the 8-byte struct or the
-- struct itself packed into the register. Tell them apart without touching bad memory.
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

-- 1) action transitions of the player (base and sub controller). Silent in this game build,
--    kept as the cheap path in case a game update brings it back.
local function install_enter_hook()
    local m = find_method("ace.cActionController", "callActionEnter", 2)
    if m == nil then return false end
    local ok = pcall(sdk.hook, m, function(args)
        W.enter_calls = W.enter_calls + 1
        local ctrl = safe(sdk.to_int64, args[2])
        if ctrl == nil or ctrl == 0 then return end
        if ctrl ~= P.base_ctrl and ctrl ~= P.sub_ctrl then
            if now() - P.resolved_at < 1.0 then return end
            resolve_player()
            if ctrl ~= P.base_ctrl and ctrl ~= P.sub_ctrl then return end
        end
        local action = safe(sdk.to_managed_object, args[3])
        local name = type_name(action)
        if name == nil then return end
        if not W.hook_seen then
            W.hook_seen = true
            if W.poll_hits > 0 then note("callActionEnter hook is alive after all, polling stopped") end
        end
        if ctrl == P.base_ctrl then
            pcall(on_base_enter, name)
        else
            pcall(on_sub_enter, name)
        end
    end, function(retval) return retval end)
    return ok
end

-- 2) veto the auto-draw decision while armed
local function install_veto_hook()
    local tuple_name = "System.ValueTuple`2<app.cPlayerAutoWeaponOnOffSupporter.ONOFFTYPE,System.Boolean>"
    local m = find_method("app.cPlayerAutoWeaponOnOffSupporter", "getCheckWeaponOnOffType(app.cPlayerCommandResult)", 1)
    if m == nil then status.tuple = "method missing"; return false end
    local rt = safe(m.get_return_type, m)
    local rt_name = rt and safe(rt.get_full_name, rt)
    if rt_name ~= tuple_name then status.tuple = "unexpected return type " .. tostring(rt_name); return false end
    local layout_ok = safe(function()
        return rt:get_valuetype_size() == 8
            and rt:get_field("Item1"):get_type():get_full_name() == "app.cPlayerAutoWeaponOnOffSupporter.ONOFFTYPE"
            and rt:get_field("Item2"):get_type():get_full_name() == "System.Boolean"
            and rt:get_field("Item1"):get_offset_from_base() == 16
            and rt:get_field("Item2"):get_offset_from_base() == 20
    end) == true
    if not layout_ok then status.tuple = "unexpected tuple layout"; return false end
    status.tuple = "ok"

    local ok = pcall(sdk.hook, m, function(args)
        local st = hook_storage()
        st.bks_mine = false
        if S.state ~= "armed" or not cfg.enabled then return end
        -- struct return: args[2] is the hidden return buffer and args[3] is "this" (or args[2] is "this")
        local a2, a3 = safe(sdk.to_int64, args[2]), safe(sdk.to_int64, args[3])
        if P.supporter_addr == 0 then return end
        if a2 ~= P.supporter_addr and a3 ~= P.supporter_addr then return end
        st.bks_mine = true
    end, function(retval)
        if hook_storage().bks_mine ~= true then return retval end
        if S.state ~= "armed" then return retval end
        local direction = safe(sdk.get_native_field, retval, rt, "Item1")
        if direction ~= ONOFF_ON then return retval end
        if combat_blocks() then
            note("auto-draw ON while enemies are in battle mode -> not vetoed, cycle ends")
            reset_cycle()
            return retval
        end
        local okset = pcall(sdk.set_native_field, retval, rt, "Item1", ONOFF_NONE)
        if okset and safe(sdk.get_native_field, retval, rt, "Item1") == ONOFF_NONE then
            S.vetoes = S.vetoes + 1
            if S.vetoes == 1 then note("vetoed auto-draw ON (-> NONE)") end
        end
        return retval
    end)
    return ok
end

-- 3) the bow base action's own enter: the earliest sign that the bow came up
local function install_bow_enter_hook()
    local m = find_method("app.PlayerTwoHandedAction.cBowBase", "detailEnter", 0)
    if m == nil then return false end
    local ok = pcall(sdk.hook, m, function(args)
        if S.state == "in_bow" then return end
        local action = safe(sdk.to_managed_object, args[2])
        local name = type_name(action)
        if not is_bow(name) then return end
        local owner = call(action, "get_OwnerCharacter")
        if addr(owner) == 0 then return end
        if addr(owner) ~= P.character_addr then
            resolve_player()
            if addr(owner) ~= P.character_addr then return end
        end
        if W.hook_seen then note("bow enter seen only by cBowBase.detailEnter (callActionEnter missed it)") end
        pcall(on_base_enter, name)
    end, function(retval) return retval end)
    return ok
end

-- 4) base action requests of the player: swap a katana-stance request for its sheathed twin.
--    kind "id":   args[3] is an ace.ACTION_ID
--    kind "ints": args[3], args[4] are index and category (in that order)
--    owner "character" (app.CharacterBase methods) or "controller" (ace.cActionController methods)
local function install_request_hook(key, type_, signature, num_params, kind, owner)
    local m = find_method(type_, signature, num_params)
    if m == nil then return false end
    local ok = pcall(sdk.hook, m, function(args)
        if S.state == "idle" then return end
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
                hook_storage().bks_id = id
                args[3] = sdk.to_ptr(id:get_address())
            end
        end)
    end, function(retval)
        if S.state ~= "idle" then hook_storage().bks_id = nil end
        return retval
    end)
    return ok
end

-- 5) the selector's own choice of the action that follows a finished action. Only touched
--    while the bow-lowering action runs, so the bow itself is never interrupted by it.
local function install_select_hook(key, signature)
    local m = find_method("app.cPlayerActionSelector", signature, 0)
    if m == nil then return false end
    local ok = pcall(sdk.hook, m, function(args) end, function(retval)
        if S.state ~= "in_bow" or P.last_base_action ~= BOW_END then return retval end
        local out = retval
        pcall(function()
            local c, i, mode = decode_id(retval)
            if c == nil then return end
            local nc, ni = pick_redirect(key, c, i)
            if nc == nil then return end
            if mode == "value" then
                out = sdk.to_ptr((ni << 32) | nc)
            else
                sdk.set_native_field(retval, T_ACTION_ID, "_Category", nc)
                sdk.set_native_field(retval, T_ACTION_ID, "_Index", ni)
            end
        end)
        return out
    end)
    return ok
end

-- 6) sub action requests of the player during a bow cycle (diagnostics only)
local function install_sub_request_hook()
    local m = find_method("app.CharacterBase", "requestSubAction(ace.ACTION_ID)", 1)
    if m == nil then return false end
    local ok = pcall(sdk.hook, m, function(args)
        if S.state == "idle" or not cfg.debug then return end
        if safe(sdk.to_int64, args[2]) ~= P.character_addr then return end
        pcall(function()
            local c, i = decode_id(args[3])
            if c == nil then return end
            diag("requestSubAction", Asub.by_id[id_key(c, i)], c, i)
        end)
    end, function(retval) return retval end)
    return ok
end

local REQUEST_HOOKS = {
    { "requestBaseAction", "app.CharacterBase", "requestBaseAction(ace.ACTION_ID, app.CharacterDef.ACTION_REQUEST_CATEGORY)", 2, "id", "character" },
    { "requestBaseActionWithArgument", "app.CharacterBase", "requestBaseActionWithArgument(ace.ACTION_ID, app.CharacterDef.ACTION_REQUEST_CATEGORY, app.cCharacterArgumentData)", 3, "id", "character" },
    { "changeActionRequest", "ace.cActionController", "changeActionRequest(ace.ACTION_ID)", 1, "id", "controller" },
    { "changeActionRequest(int,int)", "ace.cActionController", "changeActionRequest(System.Int32, System.Int32)", 2, "ints", "controller" },
    { "changeActionImmediate", "ace.cActionController", "changeActionImmediate(ace.ACTION_ID, System.Boolean)", 2, "id", "controller" },
    { "changeActionImmediate(int,int)", "ace.cActionController", "changeActionImmediate(System.Int32, System.Int32, System.Boolean)", 3, "ints", "controller" },
}

local function install()
    hooks.enter = install_enter_hook()
    hooks.veto = install_veto_hook()
    hooks.bow = install_bow_enter_hook()
    local request_ok, request_n = {}, 0
    for _, h in ipairs(REQUEST_HOOKS) do
        if install_request_hook(h[1], h[2], h[3], h[4], h[5], h[6]) then
            request_n = request_n + 1
        else
            request_ok[#request_ok + 1] = h[1]
        end
    end
    hooks.requests = request_n
    hooks.select_end = install_select_hook("selectActionEndAction", "selectActionEndAction")
    hooks.select_idle = install_select_hook("selectIdleAction", "selectIdleAction")
    hooks.sub = install_sub_request_hook()
    local parts = {}
    parts[#parts + 1] = "v" .. VERSION
    parts[#parts + 1] = "transitions=" .. (hooks.enter and "ok" or "FAILED")
    parts[#parts + 1] = "veto=" .. (hooks.veto and "ok" or ("off (" .. status.tuple .. ")"))
    parts[#parts + 1] = "bowEnter=" .. (hooks.bow and "ok" or "off")
    parts[#parts + 1] = string.format("requests=%d/%d", request_n, #REQUEST_HOOKS)
        .. (#request_ok > 0 and (" (missing: " .. table.concat(request_ok, ", ") .. ")") or "")
    parts[#parts + 1] = "selectEnd=" .. (hooks.select_end and "ok" or "off")
    parts[#parts + 1] = "selectIdle=" .. (hooks.select_idle and "ok" or "off")
    parts[#parts + 1] = "subRequest=" .. (hooks.sub and "ok" or "off")
    parts[#parts + 1] = "actionIdType=" .. (T_ACTION_ID ~= nil and "ok" or "MISSING")
    status.install = table.concat(parts, "  ")
    note("installed: " .. status.install)
end
install()

re.on_pre_application_entry("UpdateBehavior", function() pcall(tick) end)

-------------------------------------------------------------------------------
-- UI
-------------------------------------------------------------------------------
re.on_draw_ui(function()
    if not imgui.tree_node("Bow Keeps Sheathed") then return end
    local changed, c = false, false
    c, cfg.enabled = imgui.checkbox("Enabled", cfg.enabled); changed = changed or c
    c, cfg.redirect = imgui.checkbox("Go straight to the sheathed stance when the bow ends (no draw)", cfg.redirect); changed = changed or c
    c, cfg.cut_bow_end = imgui.slider_float("Bow-lowering animation: play this long (s), 0 = skip it", cfg.cut_bow_end, 0.0, 1.5, "%.2f"); changed = changed or c
    c, cfg.auto_cut = imgui.checkbox("When it plays: stop it the moment the katana starts to come out", cfg.auto_cut); changed = changed or c
    if cfg.katana_on_at > 0 then
        imgui.text(string.format("Measured: the katana comes out %.2fs into the bow-lowering animation (about 1.05s long)", cfg.katana_on_at))
    else
        imgui.text("Katana-out time not measured yet (use the bow once with the katana drawn)")
    end
    c, cfg.respect_combat = imgui.checkbox("Leave the game alone while enemies are in battle mode", cfg.respect_combat); changed = changed or c
    c, cfg.grace = imgui.slider_float("Grace window after the bow (s)", cfg.grace, 0.5, 8.0, "%.1f"); changed = changed or c
    if imgui.tree_node("Last-resort sheathe (only used when the redirect fails)") then
        c, cfg.early_timer = imgui.checkbox("Expire the auto-sheathe timer already while lowering the bow (experimental)", cfg.early_timer); changed = changed or c
        c, cfg.fallback_delay = imgui.slider_float("Delay before the explicit sheathe request (s)", cfg.fallback_delay, 0.0, 2.0, "%.2f"); changed = changed or c
        imgui.tree_pop()
    end
    c, cfg.debug = imgui.checkbox("Write debug lines to re2_framework_log.txt", cfg.debug); changed = changed or c
    if changed then save_cfg() end

    imgui.text("Hooks: " .. status.install)
    imgui.text("Action table: " .. A.status)
    imgui.text("Transitions via: " .. (W.hook_seen and "hook" or
        (W.poll_hits > 0 and ("polling (hook silent, " .. W.poll_hits .. " changes)") or "waiting for the first action change")))
    imgui.text(string.format("State: %s   was_out=%s   cycles=%d   redirects=%d   sheathed=%d   vetoes=%d",
        S.state, tostring(S.was_out), S.cycles, S.redirect_total, S.sheathed_ok, S.vetoes))
    imgui.text("Base action: " .. tostring(P.last_base_action))
    imgui.text("Sub action:  " .. tostring(P.last_sub_action))
    if imgui.tree_node("Recent events") then
        for i = #events, 1, -1 do imgui.text(events[i]) end
        if imgui.button("Clear") then events = {} end
        imgui.tree_pop()
    end
    imgui.tree_pop()
end)

re.on_script_reset(function() reset_cycle() end)
