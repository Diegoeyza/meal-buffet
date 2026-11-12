-- consumables_probe.lua v4 — discovery probe for the consumable-buff feature.
-- Throwaway tool: not part of the release, deleted after use.
--
-- v3 learned the base duration of every buff type and that activateItemBuff
-- takes (type, effect_rate, time_scale). v4 reads the derived attack/defence
-- values (via.rds.DahliaFloatBox:read()) to learn the effect strength of the
-- normal / mega / pill variants and to confirm the Item Prolonger style scale.
--
-- Output: reframework/data/consumables_probe.json

local VERSION = "4"
local OUT_FILE = "consumables_probe.json"
local unpack = unpack or table.unpack

local function log(fmt, ...)
    local args = { ... }
    pcall(function() print("[ConsProbe] " .. string.format(fmt, unpack(args))) end)
end

local function safe(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

local function is_primitive(v)
    local t = type(v)
    return t == "number" or t == "boolean" or t == "string"
end

local function safe_str(v)
    if v == nil then return nil end
    if is_primitive(v) then return v end
    return tostring(v)
end

local function type_name(obj)
    if obj == nil then return nil end
    local td = safe(function() return obj:get_type_definition() end)
    return td and safe(function() return td:get_full_name() end) or nil
end

local function find_field_descriptor(obj, name)
    if obj == nil then return nil end
    local td = safe(function() return obj:get_type_definition() end)
    local depth = 0
    while td and depth < 10 do
        for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
            if safe(function() return f:get_name() end) == name then return f end
        end
        td = safe(function() return td:get_parent_type() end)
        depth = depth + 1
    end
    return nil
end

local function field_value(obj, name)
    local f = find_field_descriptor(obj, name)
    if not f then return nil end
    local is_static = safe(function() return f:is_static() end)
    return safe(function() return f:get_data(is_static and nil or obj) end)
end

local function call_method(obj, name)
    if obj == nil then return nil end
    local v = safe(function() return obj:call(name) end)
    if v ~= nil then return v end
    local td = safe(function() return obj:get_type_definition() end)
    local m = td and safe(function() return td:get_method(name) end)
    if not m then return nil end
    return safe(function() return m:call(obj) end)
end

local function call_sig(obj, signature, ...)
    if obj == nil then return false, "no_object" end
    local td = safe(function() return obj:get_type_definition() end)
    if td == nil then return false, "no_type" end
    local m = safe(function() return td:get_method(signature) end)
    if m == nil then return false, "no_method:" .. tostring(signature) end
    local a = { ... }
    local n = select("#", ...)
    local ok, err = pcall(function()
        if n == 0 then m:call(obj)
        elseif n == 1 then m:call(obj, a[1])
        elseif n == 2 then m:call(obj, a[1], a[2])
        elseif n == 3 then m:call(obj, a[1], a[2], a[3])
        else m:call(obj, a[1], a[2], a[3], a[4]) end
    end)
    if not ok then return false, tostring(err) end
    return true, "ok"
end

-- via.rds.DahliaFloatBox exposes read()/decode()
local function box_read(box)
    if box == nil then return nil end
    if is_primitive(box) then return box end
    local v = call_method(box, "read")
    if v ~= nil and is_primitive(v) then return v end
    v = call_method(box, "decode")
    if v ~= nil and is_primitive(v) then return v end
    return nil
end

local function collection_count(c)
    local n = safe(function() return c:get_Count() end)
    if n == nil then
        local get_count = safe(function() return c.get_Count end)
        if get_count then n = safe(function() return get_count:call(c) end) end
    end
    if n == nil then n = safe(function() return c:get_Length() end) end
    return n
end

local function collection_get(c, i)
    local v = safe(function() return c:get_Item(i) end)
    if v ~= nil then return v end
    local get_item = safe(function() return c.get_Item end)
    if get_item then
        local got = safe(function() return get_item:call(c, i) end)
        if got ~= nil then return got end
    end
    return safe(function() return c[i] end)
end

local function enum_entries(enumName)
    local td = safe(sdk.find_type_definition, enumName)
    local out = {}
    if not td then return out end
    for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
        if safe(function() return f:is_static() end) then
            local name = safe(function() return f:get_name() end)
            local v = safe(function() return f:get_data(nil) end)
            if name and v ~= nil then out[#out + 1] = { name = name, value = v } end
        end
    end
    return out
end

local function instanced_array(pm)
    local list = field_value(pm, "_InstancedPlayerList")
        or field_value(pm, "<InstancedPlayerList>k__BackingField")
        or field_value(pm, "_PlayerList")
    if not list then return nil end
    return field_value(list, "_Array")
        or field_value(list, "<Array>k__BackingField")
        or field_value(list, "_Items")
        or list
end

local function character_of(inst, pi)
    for _, name in ipairs({ "get_Character", "get_Hunter", "get_Player" }) do
        local v = pi and call_method(pi, name)
        if v ~= nil and v ~= 0 then return v end
    end
    for _, name in ipairs({ "get_Hunter", "get_Character" }) do
        local v = call_method(inst, name)
        if v ~= nil and v ~= 0 then return v end
    end
    return field_value(inst, "<Character>k__BackingField") or field_value(inst, "_Character")
end

local function local_hunter()
    local pm = safe(function() return sdk.get_managed_singleton("app.PlayerManager") end)
    if not pm then return nil, "no_player_manager" end
    local arr = instanced_array(pm)
    if arr then
        for i = 0, 7 do
            local inst = collection_get(arr, i)
            if inst == nil then break end
            local pi = call_method(inst, "get_PlayerInfo")
            local ch = character_of(inst, pi)
            local st = ch and call_method(ch, "get_HunterStatus")
            if st and call_method(st, "get_IsUserControl") == true
                and call_method(st, "get_IsNpc") ~= true then
                return { character = ch, status = st }, "user_control"
            end
        end
    end
    return nil, "no_user_controlled_status"
end

local function stats(who)
    local st = who.status
    local attack = field_value(st, "_AttackPower")
    local defence = field_value(st, "_DefencePower")
    return {
        attack = box_read(field_value(attack, "_CurrentAttackPower")),
        attack_add = box_read(field_value(attack, "_CurrentAttackAdd")),
        attack_up_timer = field_value(attack, "_AttackUpTimer"),
        defence = box_read(field_value(defence, "_CurrentDefencePower")),
        defence_up_timer = field_value(defence, "_DefenceUpTimer"),
    }
end

local DRINKS = { "_KijinDrink", "_KijinDrink_G", "_KoukaDrink", "_KoukaDrink_G" }

local function drink_structs(ib)
    local out = {}
    for _, n in ipairs(DRINKS) do
        local o = field_value(ib, n)
        if o then
            out[n] = {
                max_time = field_value(o, "_MaxTime"),
                timer = field_value(o, "_Timer"),
                rate = field_value(o, "_EffectiveRate"),
            }
        end
    end
    return out
end

local function timer_fields(ib)
    local out = {}
    for _, f in ipairs({ "_Kairiki_Timer", "_Kairiki_MaxTime", "_Kairiki_EffectRate",
                         "_Kairiki_G_Timer", "_Kairiki_G_MaxTime",
                         "_Nintai_Timer", "_Nintai_MaxTime",
                         "_Nintai_G_Timer", "_Nintai_G_MaxTime",
                         "_KijinPowder_Timer", "_KijinPowder_MaxTime",
                         "_KoukaPowder_Timer", "_KoukaPowder_MaxTime",
                         "_DashJuice_Timer", "_Immunizer_Timer",
                         "_HotDrink_Timer", "_CoolerDrink_Timer" }) do
        out[f] = field_value(ib, f)
    end
    return out
end

local function snapshot(who)
    local ib = field_value(who.status, "_ItemBuff")
    if not ib then return nil end
    return {
        stats = stats(who),
        timers = timer_fields(ib),
        drinks = drink_structs(ib),
    }
end

-- ---------------------------------------------------------------------------
-- test state machine
-- ---------------------------------------------------------------------------

local STEPS = {
    { name = "KIJIN_DRINK",   rate = 1.0, scale = 1.0, note = "demondrug base" },
    { name = "KIJIN_DRINK",   rate = 1.5, scale = 1.0, note = "demondrug rate 1.5" },
    { name = "KIJIN_DRINK_G", rate = 1.0, scale = 1.0, note = "mega demondrug base" },
    { name = "KAIRIKI",       rate = 1.0, scale = 1.0, note = "might seed base" },
    { name = "KAIRIKI",       rate = 1.0, scale = 1.5, note = "might seed scale 1.5" },
    { name = "KAIRIKI_G",     rate = 1.0, scale = 1.0, note = "might pill base" },
    { name = "KOUKA",         rate = 1.0, scale = 1.0, note = "armorskin base" },
    { name = "KOUKA_G",       rate = 1.0, scale = 1.0, note = "mega armorskin base" },
}

local STATE = {
    who = nil,
    phase = 0,
    wait = 0,
    out = { probe_version = 4, steps = {} },
    enum_list = {},
    index = 1,
}

local function enum_value(name)
    for _, e in ipairs(STATE.enum_list) do
        if e.name == name then return e.value end
    end
    return nil
end

local function ib()
    return field_value(STATE.who.status, "_ItemBuff")
end

local function api_activate(typeName, rate, scale)
    local v = enum_value(typeName)
    if v == nil then return { error = "enum_not_found:" .. typeName } end
    local ok, err = call_sig(ib(),
        "activateItemBuff(app.HunterDef.ITEM_BUFF_TYPE, System.Single, System.Single)",
        v, rate, scale)
    return { type = typeName, rate = rate, scale = scale, ok = ok, err = err }
end

local function api_deactivate(typeName)
    local v = enum_value(typeName)
    if v == nil then return { error = "enum_not_found:" .. typeName } end
    local ok, err = call_sig(ib(), "deactivateItemBuff(app.HunterDef.ITEM_BUFF_TYPE)", v)
    return { type = typeName, ok = ok, err = err }
end

local function step_static()
    local out = STATE.out
    local who = STATE.who
    out.hunter_found = true
    out.status_type = type_name(who.status)
    out.item_prolonger = safe(function()
        local skill = field_value(who.status, "_Skill")
        return skill and skill:call("getSkillItemUsePowerUpTimeRate")
    end)
    STATE.enum_list = enum_entries("app.HunterDef.ITEM_BUFF_TYPE")
    out.item_buff_types = STATE.enum_list
    out.baseline = snapshot(who)
    log("static done, attack=%s", tostring(out.baseline.stats.attack))
end

local function advance(phase, wait)
    STATE.phase = phase
    STATE.wait = wait or 0
end

local function run_phase()
    local out = STATE.out
    local who = STATE.who
    if who == nil then return end

    if STATE.phase == 0 then
        step_static()
        advance(1, 20)
        return
    end
    if STATE.wait > 0 then
        STATE.wait = STATE.wait - 1
        return
    end

    if STATE.phase == 1 then
        local s = STEPS[STATE.index]
        if s == nil then
            out.completed = true
            out.dump_ok = safe(function() json.dump_file(OUT_FILE, out) return true end) == true
            log("dump %s", out.dump_ok and "written" or "FAILED")
            advance(2, 0)
            return
        end
        local rec = { note = s.note, name = s.name, rate = s.rate, scale = s.scale }
        rec.before = snapshot(who)
        rec.activate = api_activate(s.name, s.rate, s.scale)
        out.steps[STATE.index] = rec
        log("activate %s rate=%s scale=%s", s.name, s.rate, s.scale)
        advance(3, 40)
    elseif STATE.phase == 3 then
        local rec = out.steps[STATE.index]
        rec.after = snapshot(who)
        rec.deactivate = api_deactivate(rec.name)
        log("deactivate %s -> attack %s def %s",
            rec.name, tostring(rec.after.stats.attack), tostring(rec.after.stats.defence))
        advance(4, 20)
    elseif STATE.phase == 4 then
        local rec = out.steps[STATE.index]
        rec.after_off = snapshot(who)
        STATE.index = STATE.index + 1
        advance(1, 0)
    end
end

re.on_frame(function()
    pcall(function()
        if STATE.who == nil then
            local who = local_hunter()
            if who then STATE.who = who log("hunter found") end
            return
        end
        run_phase()
    end)
end)

re.on_draw_ui(function()
    pcall(function()
        if not imgui.tree_node("Consumables Probe v" .. VERSION) then return end
        imgui.text(string.format("step %d/%d completed=%s", STATE.index, #STEPS,
            tostring(STATE.out.completed == true)))
        imgui.tree_pop()
    end)
end)

log("loaded v%s", VERSION)
