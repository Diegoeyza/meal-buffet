--
-- meal_apply_probe2.lua v1 — phase 2 probe: read the meal master data and test
-- the game's own apply path.
--
-- What probe v3 established on this build:
--   * app.cMealEffect is the meal definition container: SKILL_NUM,
--     SKILL_NUM_MAX, adds, _SkillEnum (app.MealDef.SKILL[]), _DurationTimer,
--     DurationSec. Its methods include
--       copyFrom(app.user_data.MealData.cData, System.Boolean)
--       addRandomData(app.user_data.MealSkillRandomTable.cData)
--       addRandomTableParam(app.MealDef.RANDOM_SKILL_TBL_Fixed)
--       addSkill(app.MealDef.SKILL) / resetMealSkill()
--   * app.cHunterMealEffect has setMealEffect(app.cMealEffect, System.Boolean),
--     setTimerActive(bool), setEffectActive(bool), setDurationTimer(float).
--   * a real eat sets, in one frame: _IsEffectActive/_IsTimerActive = true,
--     _DurationTimer = _TimerMax = 4200, _MaxHealthAdd = 50,
--     _MaxStaminaAdd = 150, and the inner cMealEffect gets SKILL_NUM = 5 with
--     _AttackAdd 5 / _DefenceAdd 10.
--   * app.FacilityDining exists as a class and exposes setMealEffectLobby,
--     executeLobby, execute(cMealEffect, int), EnableEat.
--   * app.MealUtil.getMealDataLobby(app.DiningDef.LOBBY_MENU_ID) returns the
--     base-meal record for a canteen menu entry.
--
-- What this probe answers:
--   1. the base meal records (index, time, hp/stam/attack/defence/attr, fixed
--      MealSkill[] and the random table ids) and the random table records
--      (skill, stat adds, weight), read through the real master-data tables;
--   2. the canteen menu: every app.DiningDef.LOBBY_MENU_ID value and the meal
--      record it resolves to, plus the field-camp LIFE_AREA variants;
--   3. whether the game's own apply path can be driven from Lua:
--        A) FacilityDining:setMealEffectLobby(menuId)      (state apply only)
--        B) build a cMealEffect, then cHunterMealEffect:setMealEffect(...)
--      each attempt is recorded with before/after state and +15/+120-frame
--      verification.
--
-- No hooks anywhere. Reads go through field descriptors (walking the parent
-- type chain, because the via.UserData tables keep _Values on the base class).
-- Writes happen only on the explicit apply buttons.
--

local re = re
local sdk = sdk
local json = json
local log = log
local imgui = imgui
local unpack = unpack or table.unpack

local PROBE_VERSION = 1

local OUT_TYPES  = "meal_apply_probe2_types.json"
local OUT_MASTER = "meal_apply_probe2_master.json"
local OUT_APPLY  = "meal_apply_probe2_apply.json"

local ALREADY_LOADED = _G.MEAL_APPLY_PROBE2_LOADED == true
_G.MEAL_APPLY_PROBE2_LOADED = true

local VERIFY_FRAMES = { 15, 120 }
local MAX_ERRORS = 30
local MAX_ATTEMPTS = 30

local lastStatus = "(idle)"
local pending_verify = nil
local pending_action = nil
local errors = {}

local function note_error(where, err)
    if #errors >= MAX_ERRORS then return end
    errors[#errors + 1] = {
        where = tostring(where),
        err = tostring(err),
        wall = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
    log.warn("[MealApplyProbe2] " .. tostring(where) .. ": " .. tostring(err))
end

local function dump_json(name, tbl)
    tbl.errors = errors
    tbl.probe_version = PROBE_VERSION
    tbl.wall = tbl.wall or os.date("!%Y-%m-%dT%H:%M:%SZ")
    local ok, err = pcall(function() json.dump_file(name, tbl) end)
    if not ok then note_error("dump " .. name, err) end
    return ok
end

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

local function safe(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

local function safe_str(v)
    if v == nil then return nil end
    local t = type(v)
    if t == "string" or t == "number" or t == "boolean" then return v end
    return tostring(v)
end

local function is_primitive(v)
    local t = type(v)
    return t == "number" or t == "boolean" or t == "string"
end

local function type_name(obj)
    if obj == nil then return nil end
    local td = safe(function() return obj:get_type_definition() end)
    return td and safe(function() return td:get_full_name() end) or nil
end

-- Walk the type hierarchy: the via.UserData tables declare _Values on a base
-- generic class, so a plain get_fields() on the object's own type misses it.
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

-- Void game calls (setMealEffect, copyFrom, addRandomTableParam, ...) return
-- nothing, so success is "the method exists and did not throw".
local function call_void(obj, signature, ...)
    if obj == nil then return false, "no_object" end
    local td = safe(function() return obj:get_type_definition() end)
    if not td then return false, "no_type" end
    local m = safe(function() return td:get_method(signature) end)
    if not m then return false, "no_method:" .. tostring(signature) end
    local a = { ... }
    local ok, err = pcall(function() m:call(obj, unpack(a)) end)
    if not ok then return false, tostring(err) end
    return true, "ok"
end

-- Static calls that return a value (MealUtil lookups).
local function static_value(typeName, signature, ...)
    local td = safe(sdk.find_type_definition, typeName)
    if not td then return nil end
    local m = safe(function() return td:get_method(signature) end)
    if not m then return nil end
    local a = { ... }
    return safe(function() return m:call(nil, unpack(a)) end)
end

local function collection_count(c)
    local n = safe(function() return c:get_Count() end)
    if n == nil then
        local get_count = safe(function() return c.get_Count end)
        if get_count then n = safe(function() return get_count:call(c) end) end
    end
    if n == nil then n = safe(function() return c:get_Length() end) end
    if n == nil then n = safe(function() return #c end) end
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

-- Read a managed array (System.Int32[], app.MealDef.SKILL[], ...) as primitives.
local function array_values(arr, max)
    local out = {}
    if arr == nil then return out end
    local n = collection_count(arr)
    if not n then return out end
    local base = 0
    if n > 0 and collection_get(arr, 0) == nil then base = 1 end
    local limit = n
    if max and limit > max then limit = max end
    for i = 0, limit - 1 do
        local v = collection_get(arr, base + i)
        if v == nil then break end
        out[#out + 1] = safe_str(v)
    end
    return out
end

local function table_values(ud)
    if ud == nil then return nil end
    return field_value(ud, "_Values") or ud
end

-- ---------------------------------------------------------------------------
-- enums + text
-- ---------------------------------------------------------------------------

local function enum_map(enumName)
    local td = safe(sdk.find_type_definition, enumName)
    local out = { name = enumName, exists = td ~= nil, entries = {} }
    if not td then return out end
    for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
        if safe(function() return f:is_static() end) then
            local name = safe(function() return f:get_name() end)
            local v = safe(function() return f:get_data(nil) end)
            if name and v ~= nil then
                out.entries[#out.entries + 1] = { name = name, value = safe_str(v) }
            end
        end
    end
    return out
end

local function first_enum(candidates)
    for _, name in ipairs(candidates) do
        local e = enum_map(name)
        if e.exists and #e.entries > 0 then return e end
    end
    return { name = candidates[1], exists = false, entries = {} }
end

local get_meal_skill_name_m, get_message_m

local function resolve_text_helpers()
    if get_meal_skill_name_m == nil then
        local mu = safe(sdk.find_type_definition, "app.MessageUtil")
        get_meal_skill_name_m = mu and safe(function()
            return mu:get_method("getMealSkillName(app.MealDef.SKILL)")
        end) or false
    end
    if get_message_m == nil then
        local gm = safe(sdk.find_type_definition, "via.gui.message")
        get_message_m = gm and safe(function() return gm:get_method("get(System.Guid)") end) or false
    end
end

local function meal_skill_name(id)
    resolve_text_helpers()
    if not id or get_meal_skill_name_m == false or get_message_m == false then return nil end
    local guid = safe(function() return get_meal_skill_name_m:call(nil, id) end)
    if guid == nil then return nil end
    return safe(function() return get_message_m:call(nil, guid) end)
end

-- ---------------------------------------------------------------------------
-- local hunter + meal state
-- ---------------------------------------------------------------------------

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

local function local_status()
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
            if st then
                local is_user = call_method(st, "get_IsUserControl")
                local is_npc = call_method(st, "get_IsNpc")
                if is_user == true and is_npc ~= true then return st, "user_control" end
            end
        end
    end
    return nil, "no_user_controlled_status"
end

local function meal_object()
    local st, src = local_status()
    if not st then return nil, src end
    local meal = field_value(st, "_MealEffect")
    if not meal then
        local td = safe(function() return st:get_type_definition() end)
        for _, f in ipairs(safe(function() return td and td:get_fields() end) or {}) do
            local tn = safe_str(safe(function() return f:get_type():get_full_name() end))
            if tn == "app.cHunterMealEffect" then
                local is_static = safe(function() return f:is_static() end)
                local v = safe(function() return f:get_data(is_static and nil or st) end)
                if v ~= nil then return v, src, st end
            end
        end
        return nil, "no_meal_object"
    end
    return meal, src, st
end

local function effect_summary(effect)
    local out = { type = type_name(effect), fields = {}, skills = {} }
    if effect == nil then return out end
    for _, name in ipairs({
        "SKILL_NUM", "SKILL_NUM_MAX", "_MaxHealthAdd", "_MaxStaminaAdd",
        "_AttackAdd", "_DefenceAdd", "_DurationTimer",
        "<DurationSec>k__BackingField",
    }) do
        out.fields[name] = safe_str(field_value(effect, name))
    end
    out.attr_resist = array_values(field_value(effect, "_AttrResistAdd"), 8)
    out.skills = array_values(field_value(effect, "_SkillEnum"), 12)
    out.skill_names = {}
    for i, id in ipairs(out.skills) do
        out.skill_names[i] = meal_skill_name(tonumber(id) or id)
    end
    return out
end

local function meal_state()
    local meal, src, st = meal_object()
    local out = { src = src, wall = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    if not meal then
        out.fail = src
        return out
    end
    out.pointer = tostring(meal)
    out.hunter = {}
    for _, name in ipairs({
        "_IsEffectActive", "_IsTimerActive", "_DurationTimer", "_TimerMax",
        "_MaxHealthAdd", "_MaxStaminaAdd", "_TempIsEffectActive", "_TempIsTimerActive",
    }) do
        out.hunter[name] = safe_str(field_value(meal, name))
    end
    out.derived = {}
    for _, g in ipairs({
        "get_AttackAdd", "get_DefenceAdd", "get_IsActiveGuts_L", "get_IsActiveGuts_S",
        "get_IsActiveHeroic", "get_IsUnevenActive_L", "get_IsUnevenActive_S",
    }) do
        out.derived[g] = safe_str(call_method(meal, g))
    end
    out.effect = effect_summary(field_value(meal, "_MealEffect"))
    out.skill_param = {}
    local spi = field_value(meal, "_SkillParamInfo")
    if spi then
        for _, name in ipairs({
            "_IsActiveGuts_L", "_IsActiveGuts_S", "_IsUsedGuts", "_UnevenTimer",
            "_IsActiveCoolHot", "_IsActiveWaterAdjust", "_IsActiveHeroic",
            "_RestBuffTimer", "_RecoilAttackTimer",
        }) do
            out.skill_param[name] = safe_str(field_value(spi, name))
        end
    end
    if st then
        local hp = call_method(st, "get_Health")
        if hp then
            out.health = {
                extra_max = safe_str(field_value(hp, "_ExtraMaxHealth")),
                red = safe_str(field_value(hp, "_RedHealth")),
            }
        end
        local sp = call_method(st, "get_Stamina")
        if sp then
            out.stamina = {
                temp_max = safe_str(field_value(sp, "_TempMaxStamina")),
                request_add = safe_str(field_value(sp, "_RequestAddMaxStamina")),
            }
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- master data: meals, meal skills, random table, canteen menus
-- ---------------------------------------------------------------------------

local data = { dining = nil, meals = {}, meal_by_index = {}, random = {}, skills = {}, lobby = {}, life_area = {} }

local function resolve_chain()
    local vm = safe(function() return sdk.get_managed_singleton("app.VariousDataManager") end)
    if not vm then return nil, "no_various_manager" end
    local setting = field_value(vm, "_Setting")
    local facility = setting and field_value(setting, "_FacilitySetting")
    local dining = facility and field_value(facility, "_FacilityDiningSetting")
    if not dining then return nil, "no_dining_setting" end
    data.dining = dining
    return dining, "ok"
end

local function read_table(ud, max)
    local vals = table_values(ud)
    local n = collection_count(vals)
    local out = { count = n, entries = {}, fetch_ok = false }
    if not n then return out end
    local base = 0
    if n > 0 and collection_get(vals, 0) == nil then base = 1 end
    local limit = n
    if max and limit > max then limit = max end
    for i = 0, limit - 1 do
        local v = collection_get(vals, base + i)
        if v ~= nil then
            out.fetch_ok = true
            out.entries[#out.entries + 1] = v
        end
    end
    return out
end

local function dump_meals()
    local dining, src = resolve_chain()
    if not dining then return nil, src end

    local meal_table = read_table(field_value(dining, "_MealData"), 80)
    data.meals = {}
    for i, cd in ipairs(meal_table.entries) do
        local rec = {
            index_table = i - 1,
            index = safe_str(field_value(cd, "_Index")),
            time = safe_str(field_value(cd, "_Time")),
            health = safe_str(field_value(cd, "_Health")),
            stamina = safe_str(field_value(cd, "_Stamina")),
            attack = safe_str(field_value(cd, "_Attack")),
            defence = safe_str(field_value(cd, "_Defence")),
            attr_resist = safe_str(field_value(cd, "_AttrResist")),
            portable_food = safe_str(field_value(cd, "_PortableFoodType")),
            skills = array_values(call_method(cd, "get_MealSkill"), 12),
            random_tables = array_values(call_method(cd, "get_RandomTable"), 8),
        }
        rec.skill_names = {}
        for k, id in ipairs(rec.skills) do
            rec.skill_names[k] = meal_skill_name(tonumber(id))
        end
        rec.pointer = tostring(cd)
        data.meal_by_index[tostring(rec.index)] = cd
        data.meals[#data.meals + 1] = rec
    end

    local skill_table = read_table(field_value(dining, "_MealSkill"), 80)
    data.skills = {}
    for i, cd in ipairs(skill_table.entries) do
        local id = call_method(cd, "get_MealSkill")
        data.skills[#data.skills + 1] = {
            index_table = i - 1,
            index = safe_str(field_value(cd, "_Index")),
            skill = safe_str(id),
            name = meal_skill_name(tonumber(safe_str(id) or 0) or 0),
        }
    end

    local random_table = read_table(field_value(dining, "_MealSkillRandomTable"), 120)
    data.random = {}
    for i, cd in ipairs(random_table.entries) do
        local id = call_method(cd, "get_MealSkill")
        data.random[#data.random + 1] = {
            index_table = i - 1,
            table = safe_str(call_method(cd, "get_RandomTable")),
            skill = safe_str(id),
            name = meal_skill_name(tonumber(safe_str(id) or 0) or 0),
            health = safe_str(field_value(cd, "_Health")),
            stamina = safe_str(field_value(cd, "_Stamina")),
            attack = safe_str(field_value(cd, "_Attack")),
            defence = safe_str(field_value(cd, "_Defence")),
            attr_resist = safe_str(field_value(cd, "_AttrResist")),
            weight = safe_str(field_value(cd, "_RandomValue")),
        }
    end

    -- canteen menus: lobby (hub) and field camp life areas
    local lobby_enum = first_enum({ "app.DiningDef.LOBBY_MENU_ID", "app.DiningDef.MENU_ID", "app.DiningDef.LOBBY_MENU" })
    data.lobby = {}
    for _, e in ipairs(lobby_enum.entries) do
        local cd = static_value("app.MealUtil", "getMealDataLobby(app.DiningDef.LOBBY_MENU_ID)", e.value)
        data.lobby[#data.lobby + 1] = {
            menu = e.name,
            menu_value = e.value,
            meal_index = cd and safe_str(field_value(cd, "_Index")) or nil,
            meal_time = cd and safe_str(field_value(cd, "_Time")) or nil,
            resolved = cd ~= nil,
        }
    end

    local area_enum = first_enum({ "app.FieldDef.LIFE_AREA", "app.FieldDef.AREA" })
    data.life_area = {}
    for _, e in ipairs(area_enum.entries) do
        local cd = static_value("app.MealUtil", "getMealDataLifeArea(app.FieldDef.LIFE_AREA)", e.value)
        data.life_area[#data.life_area + 1] = {
            area = e.name,
            area_value = e.value,
            meal_index = cd and safe_str(field_value(cd, "_Index")) or nil,
            active_minutes = safe_str(static_value("app.MealUtil", "getActiveMinutes(app.FieldDef.LIFE_AREA)", e.value)),
            resolved = cd ~= nil,
        }
    end

    local dining_inst = safe(function() return sdk.get_managed_singleton("app.FacilityDining") end)
    local info = dining_inst and call_method(dining_inst, "get_MealInfo")
    local out = {
        meal_table_count = meal_table.count,
        meal_fetch_ok = meal_table.fetch_ok,
        meals = data.meals,
        skill_table_count = skill_table.count,
        skills = data.skills,
        random_table_count = random_table.count,
        random = data.random,
        lobby_enum = lobby_enum,
        lobby = data.lobby,
        life_area_enum = area_enum,
        life_area = data.life_area,
        facility_dining = dining_inst ~= nil,
        meal_info = info and {
            type = type_name(info),
            fields = (function()
                local f = {}
                local td = safe(function() return info:get_type_definition() end)
                for _, fd in ipairs(safe(function() return td and td:get_fields() end) or {}) do
                    local n = safe(function() return fd:get_name() end)
                    local is_static = safe(function() return fd:is_static() end)
                    local v = safe(function() return fd:get_data(is_static and nil or info) end)
                    if n and is_primitive(v) then f[n] = v end
                end
                return f
            end)(),
        } or nil,
    }
    return out
end

local function dump_master()
    local out, src = dump_meals()
    if not out then
        dump_json(OUT_MASTER, { fail = src })
        lastStatus = "master: " .. tostring(src)
        log.warn("[MealApplyProbe2] " .. lastStatus)
        return
    end
    dump_json(OUT_MASTER, out)
    lastStatus = string.format("master: %s meals, %s skills, %s random lines, %d menus -> %s",
        tostring(out.meal_table_count), tostring(out.skill_table_count),
        tostring(out.random_table_count), #out.lobby, OUT_MASTER)
    log.info("[MealApplyProbe2] " .. lastStatus)
    return out
end

-- ---------------------------------------------------------------------------
-- types (small, targeted list for the apply path)
-- ---------------------------------------------------------------------------

local TYPES = {
    "app.cHunterMealEffect", "app.cMealEffect", "app.cHunterMealSkillParamInfo",
    "app.FacilityDining", "app.cMealMySetUse", "app.MealUtil", "app.MealDef",
    "app.DiningDef", "app.FieldDef", "app.savedata.cDiningParam",
    "app.user_data.MealData", "app.user_data.MealData.cData",
    "app.user_data.MealSkillData", "app.user_data.MealSkillData.cData",
    "app.user_data.MealSkillRandomTable", "app.user_data.MealSkillRandomTable.cData",
    "app.user_data.FacilityDiningSetting", "app.user_data.FacilitySetting",
    "app.user_data.VariousDataManagerSetting",
}

local ENUMS = {
    "app.DiningDef.LOBBY_MENU_ID", "app.FieldDef.LIFE_AREA",
    "app.MealDef.SKILL", "app.MealDef.SLOT_TYPE", "app.MealDef.PORTABLE_FOOD",
    "app.MealDef.RANDOM_SKILL_TBL_Fixed",
}

local function dump_type(typeName)
    local td = safe(sdk.find_type_definition, typeName)
    local e = { name = typeName, exists = td ~= nil }
    if not td then return e end
    e.full_name = safe(function() return td:get_full_name() end)
    e.fields = {}
    for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
        e.fields[#e.fields + 1] = {
            name = safe(function() return f:get_name() end),
            type = safe_str(safe(function() return f:get_type():get_full_name() end)),
            static = safe(function() return f:is_static() end),
        }
    end
    e.methods = {}
    for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
        local params, n = {}, safe(function() return m:get_num_params() end) or 0
        local pts = safe(function() return m:get_param_types() end) or {}
        for i = 1, n do
            params[#params + 1] = safe_str(safe(function() return pts[i]:get_full_name() end)) or "?"
        end
        e.methods[#e.methods + 1] = (safe(function() return m:get_name() end) or "?")
            .. "(" .. table.concat(params, ", ") .. ")"
            .. " -> " .. tostring(safe(function()
                return m:get_return_type():get_full_name()
            end))
    end
    return e
end

local function dump_types()
    local out = { kinds = {}, enums = {} }
    for _, name in ipairs(TYPES) do
        local ok, e = pcall(dump_type, name)
        if ok then out.kinds[#out.kinds + 1] = e else note_error("dump_type " .. name, e) end
    end
    for _, name in ipairs(ENUMS) do
        local ok, e = pcall(enum_map, name)
        if ok then out.enums[#out.enums + 1] = e else note_error("enum " .. name, e) end
    end
    dump_json(OUT_TYPES, out)
    lastStatus = "types -> " .. OUT_TYPES
    return out
end

-- ---------------------------------------------------------------------------
-- apply experiments
-- ---------------------------------------------------------------------------

local attempts = {}
local menu_index = 1
local last_built = nil

local function current_menu()
    if #data.lobby == 0 then return nil end
    if menu_index > #data.lobby then menu_index = 1 end
    return data.lobby[menu_index]
end

local function record_attempt(rec)
    attempts[#attempts + 1] = rec
    while #attempts > MAX_ATTEMPTS do table.remove(attempts, 1) end
    dump_json(OUT_APPLY, { attempts = attempts, menu_index = menu_index })
end

-- A) the facility's own state apply: no eat event, no item consumption.
local function apply_menu()
    if #data.lobby == 0 then
        local ok, err = pcall(dump_meals)
        if not ok then note_error("dump_meals", err) end
    end
    local menu = current_menu()
    if menu == nil then
        lastStatus = "apply menu: no lobby menu resolved (press Dump master data)"
        return
    end
    local dining = safe(function() return sdk.get_managed_singleton("app.FacilityDining") end)
    local rec = {
        action = "setMealEffectLobby",
        menu = menu.menu,
        menu_value = menu.menu_value,
        facility_dining = dining ~= nil,
        before = meal_state(),
    }
    if dining == nil then
        rec.fail = "no_facility_dining_singleton"
        record_attempt(rec)
        lastStatus = "apply menu: app.FacilityDining singleton not found"
        return
    end
    local enable = call_method(dining, "EnableEat")
    rec.enable_eat = safe_str(enable)
    local ok, err = call_void(dining,
        "setMealEffectLobby(app.DiningDef.LOBBY_MENU_ID)", menu.menu_value)
    rec.call_ok = ok
    rec.call_error = err
    rec.after = meal_state()
    pending_verify = { frames = VERIFY_FRAMES, done = {}, readings = {}, out = { attempts = attempts } }
    record_attempt(rec)
    lastStatus = string.format("apply menu '%s': call=%s", tostring(menu.menu), tostring(rec.call_ok))
    log.info("[MealApplyProbe2] " .. lastStatus)
end

-- B) build the effect ourselves, then hand it to the hunter.
local function build_effect(meal_rec, add_randoms)
    local cdata = data.meal_by_index[tostring(meal_rec.index)]
    if cdata == nil then return nil, "no_cdata_for_meal_index" end
    local effect = safe(function() return sdk.create_instance("app.cMealEffect") end)
    if effect == nil then return nil, "no_instance" end
    safe(function() effect:add_ref() end)

    local copied, copy_err = call_void(effect,
        "copyFrom(app.user_data.MealData.cData, System.Boolean)", cdata, false)
    if not copied then
        -- the bool may mean "lobby/life area"; try the other value once
        copied, copy_err = call_void(effect,
            "copyFrom(app.user_data.MealData.cData, System.Boolean)", cdata, true)
    end
    local built = effect_summary(effect)
    local added, add_errors = 0, {}
    if add_randoms then
        for _, tbl in ipairs(meal_rec.random_tables or {}) do
            local num = tonumber(tbl)
            if num then
                local ok, err = call_void(effect,
                    "addRandomTableParam(app.MealDef.RANDOM_SKILL_TBL_Fixed)", num)
                if ok then added = added + 1 else add_errors[#add_errors + 1] = tostring(err) end
            end
        end
    end
    local after = effect_summary(effect)
    return effect, nil, {
        copied = copied,
        copy_error = copy_err,
        random_added = added,
        random_errors = add_errors,
        built = built,
        after_randoms = after,
    }
end

local function build_and_apply()
    if #data.lobby == 0 then
        local ok, err = pcall(dump_meals)
        if not ok then note_error("dump_meals", err) end
    end
    local menu = current_menu()
    if menu == nil then
        lastStatus = "build: no lobby menu resolved"
        return
    end
    -- the meal record for this menu, matched by _Index
    local meal_rec = nil
    for _, rec in ipairs(data.meals) do
        if tostring(rec.index) == tostring(menu.meal_index) then meal_rec = rec break end
    end
    if meal_rec == nil then
        lastStatus = "build: menu meal index not in _MealData"
        return
    end

    local rec = {
        action = "build_and_apply",
        menu = menu.menu,
        menu_value = menu.menu_value,
        meal_index = meal_rec.index,
        before = meal_state(),
    }
    local effect, err, info = build_effect(meal_rec, true)
    if effect == nil then
        rec.fail = err
        record_attempt(rec)
        lastStatus = "build: " .. tostring(err)
        return
    end
    rec.build = info
    last_built = { effect = effect, meal = meal_rec, info = info }

    local meal, msrc = meal_object()
    if not meal then
        rec.fail = "no_meal_object:" .. tostring(msrc)
        record_attempt(rec)
        lastStatus = "build: " .. tostring(rec.fail)
        return
    end

    local attach, attach_err = call_void(meal,
        "setMealEffect(app.cMealEffect, System.Boolean)", effect, false)
    rec.attach_ok = attach
    rec.attach_error = attach_err
    local seconds = tonumber(meal_rec.time)
    if seconds and seconds > 0 then
        local ok, err = call_void(meal, "setDurationTimer(System.Single)", seconds * 60)
        rec.timer_ok = ok
        rec.timer_error = err
    end
    local t1, e1 = call_void(meal, "setTimerActive(System.Boolean)", true)
    local t2, e2 = call_void(meal, "setEffectActive(System.Boolean)", true)
    rec.timer_active_ok = t1
    rec.effect_active_ok = t2
    rec.active_errors = { timer = e1, effect = e2 }
    rec.after = meal_state()
    pending_verify = { frames = VERIFY_FRAMES, done = {}, readings = {}, out = { attempts = attempts } }
    record_attempt(rec)
    lastStatus = string.format("build+apply '%s': skills=%s attach=%s",
        tostring(menu.menu), tostring(info.after_randoms and #info.after_randoms.skills or 0),
        tostring(rec.attach_ok))
    log.info("[MealApplyProbe2] " .. lastStatus)
end

local function cycle_menu(delta)
    if #data.lobby == 0 then
        local ok, err = pcall(dump_meals)
        if not ok then note_error("dump_meals", err) end
    end
    if #data.lobby == 0 then
        lastStatus = "no lobby menus (press Dump master data)"
        return
    end
    menu_index = ((menu_index - 1 + delta) % #data.lobby) + 1
    local m = data.lobby[menu_index]
    lastStatus = string.format("menu %d/%d: %s (meal index %s)",
        menu_index, #data.lobby, tostring(m.menu), tostring(m.meal_index))
end

local ACTIONS = {
    menu = apply_menu,
    build = build_and_apply,
}

local function request_action(name)
    if ACTIONS[name] == nil then return end
    if pending_action ~= nil then
        lastStatus = "busy: " .. tostring(pending_action)
        return
    end
    pending_action = name
    lastStatus = "queued: " .. name .. " (runs next frame)"
end

-- ---------------------------------------------------------------------------
-- frame callback
-- ---------------------------------------------------------------------------

local function on_frame()
    if pending_action ~= nil then
        local name = pending_action
        pending_action = nil
        local ok, err = pcall(ACTIONS[name])
        if not ok then note_error("action " .. name, err) end
        return
    end
    if pending_verify == nil then return end
    pending_verify.count = (pending_verify.count or 0) + 1
    for i, target in ipairs(pending_verify.frames) do
        if not pending_verify.done[i] and pending_verify.count >= target then
            pending_verify.done[i] = true
            pending_verify.readings[#pending_verify.readings + 1] = {
                tag = "after_" .. target .. "f",
                state = meal_state(),
            }
        end
    end
    if #pending_verify.done >= #pending_verify.frames then
        local out = { attempts = attempts, verify = pending_verify.readings }
        dump_json(OUT_APPLY, out)
        pending_verify = nil
        lastStatus = "verification written -> " .. OUT_APPLY
        log.info("[MealApplyProbe2] " .. lastStatus)
    end
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

local function hunter_line()
    local meal, src = meal_object()
    if not meal then return "hunter meal: unavailable (" .. tostring(src) .. ")" end
    local inner = field_value(meal, "_MealEffect")
    return string.format("active=%s timer=%s/%s hp=+%s stam=+%s skills=%s atk=+%s def=+%s",
        tostring(field_value(meal, "_IsEffectActive")),
        tostring(field_value(meal, "_DurationTimer")),
        tostring(field_value(meal, "_TimerMax")),
        tostring(field_value(meal, "_MaxHealthAdd")),
        tostring(field_value(meal, "_MaxStaminaAdd")),
        tostring(inner and field_value(inner, "SKILL_NUM")),
        tostring(inner and field_value(inner, "_AttackAdd")),
        tostring(inner and field_value(inner, "_DefenceAdd")))
end

local function draw_ui()
    if not imgui.tree_node("Meal Apply Probe 2 v" .. PROBE_VERSION) then return end
    imgui.text("phase 2: meal master data + game apply path (no hooks)")
    imgui.text(hunter_line())
    imgui.separator()

    if imgui.button("Dump types") then
        local ok, err = pcall(dump_types)
        if not ok then note_error("dump_types", err) end
    end
    imgui.same_line()
    if imgui.button("Dump master data") then
        local ok, err = pcall(dump_master)
        if not ok then note_error("dump_master", err) end
    end

    imgui.separator()
    local menu = current_menu()
    imgui.text(string.format("menu %d/%d: %s  (meal index %s, time %s min)",
        menu_index, #data.lobby,
        menu and tostring(menu.menu) or "?",
        menu and tostring(menu.meal_index) or "?",
        menu and tostring(menu.meal_time) or "?"))
    if imgui.button("< Prev menu") then cycle_menu(-1) end
    imgui.same_line()
    if imgui.button("Next menu >") then cycle_menu(1) end

    imgui.separator()
    if imgui.button("Apply menu (facility path)") then request_action("menu") end
    imgui.same_line()
    if imgui.button("Build + apply") then request_action("build") end
    imgui.text(string.format("meals=%d skills=%d random=%d attempts=%d",
        #data.meals, #data.skills, #data.random, #attempts))

    imgui.separator()
    imgui.text("status: " .. tostring(lastStatus))
    if pending_verify then
        imgui.text(string.format("verifying: frame %d / %d",
            pending_verify.count or 0, pending_verify.frames[#pending_verify.frames]))
    end
    if #errors > 0 then
        imgui.text("errors: " .. tostring(#errors) .. " (last: " .. errors[#errors].where .. ")")
    end
    imgui.separator()
    imgui.text("1) Dump types, then Dump master data (read-only).")
    imgui.text("2) Cycle to a menu you know, then 'Apply menu'.")
    imgui.text("3) If nothing changed, press 'Build + apply'.")
    imgui.text("4) Check max HP/stamina, attack/defence and the food skills.")
    imgui.tree_pop()
end

-- ---------------------------------------------------------------------------

if not ALREADY_LOADED then
    re.on_frame(function()
        local ok, err = pcall(on_frame)
        if not ok then note_error("on_frame", err) end
    end)
    re.on_draw_ui(function()
        local ok, err = pcall(draw_ui)
        if not ok then note_error("draw_ui", err) end
    end)
    log.info("[MealApplyProbe2] loaded v" .. tostring(PROBE_VERSION)
        .. " (master data + apply path; no hooks)")
else
    log.info("[MealApplyProbe2] duplicate load ignored")
end
