--
-- meal_apply_probe2.lua v2 — phase 2 probe: meal master data and the game's
-- own apply path.
--
-- Established by probe v3 (all confirmed in game):
--   * app.cMealEffect is the meal definition instance: SKILL_NUM, SKILL_NUM_MAX,
--     _SkillEnum (app.MealDef.SKILL[]), adds, _DurationTimer.
--   * app.cHunterMealEffect holds the live buff (adds, timer, flags) and
--     exposes setMealEffect(app.cMealEffect, bool), setTimerActive(bool),
--     setEffectActive(bool), setDurationTimer(float).
--   * app.cMealEffect.copyFrom has one overload per meal source:
--       copyFrom(app.user_data.MealData.cData, bool)
--       copyFrom(app.user_data.MealDataLobby.cData, bool)
--       copyFrom(app.user_data.MealDataLifeArea.cData, bool)
--     plus addRandomTableParam(RANDOM_SKILL_TBL_Fixed) for the extra buffs.
--   * app.MealUtil.getMealDataLobby(app.DiningDef.LOBBY_MENU_ID) returns the
--     canteen menu record. The menu enum is INVALID, MENU_00 .. MENU_08, MAX.
--   * app.FacilityDining is NOT a managed singleton; the live instance is
--     app.FacilityManager:get_Dining().
--
-- What this probe answers:
--   1. the three meal tables with every primitive value: _MealData (3 base
--      records), _MealDataLobby (canteen menus) and _MealDataLifeArea (camp),
--      each with its MealSkill[] and _RandomTable[];
--   2. the canteen menu list and which record each menu resolves to;
--   3. three candidate apply paths, all driven from buttons:
--        A) FacilityDining:setMealEffectLobby(menuId)
--        B) build a cMealEffect from the menu record + random buffs, then
--           cHunterMealEffect:setMealEffect(...) and set the timer/flags
--        C) build only, no attach (diagnostic: what did copyFrom produce?)
--
-- No hooks. Reads use field descriptors and walk the parent type chain
-- (via.UserData keeps _Values on a base class). Writes only on explicit
-- buttons.
--

local re = re
local sdk = sdk
local json = json
local log = log
local imgui = imgui
local unpack = unpack or table.unpack

local PROBE_VERSION = 2

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

-- Void game calls return nothing, so success is "method exists and did not
-- throw".
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

-- Every primitive field plus every 0-arg primitive getter. Keeps the probe
-- independent of the exact field names of each meal record type.
local function primitive_summary(obj, max_getters)
    local out = {}
    if obj == nil then return out end
    local td = safe(function() return obj:get_type_definition() end)
    if not td then return out end
    for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
        local n = safe(function() return f:get_name() end)
        local is_static = safe(function() return f:is_static() end)
        local v = safe(function() return f:get_data(is_static and nil or obj) end)
        if n and not is_static and is_primitive(v) then out[n] = v end
    end
    local n = 0
    for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
        if max_getters and n >= max_getters then break end
        local mn = safe(function() return m:get_name() end) or ""
        local np = safe(function() return m:get_num_params() end) or 0
        if mn:find("^get_") and np == 0 then
            local v = safe(function() return m:call(obj) end)
            if is_primitive(v) then
                out[mn] = v
                n = n + 1
            end
        end
    end
    return out
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

local function localized(guid)
    resolve_text_helpers()
    if guid == nil or get_message_m == false then return nil end
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
                if call_method(st, "get_IsUserControl") == true
                    and call_method(st, "get_IsNpc") ~= true then
                    return st, "user_control"
                end
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
    local out = { type = type_name(effect), fields = {}, skills = {}, skill_names = {} }
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
    for i, id in ipairs(out.skills) do
        out.skill_names[i] = meal_skill_name(tonumber(id) or 0)
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
    local spi = field_value(meal, "_SkillParamInfo")
    out.skill_param = {}
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
                skill_extra = safe_str(field_value(hp, "_SkillExtraMaxHealth")),
            }
        end
        local sp = call_method(st, "get_Stamina")
        if sp then
            out.stamina = {
                temp_max = safe_str(field_value(sp, "_TempMaxStamina")),
            }
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- data holders
-- ---------------------------------------------------------------------------

local data = {
    dining_setting = nil,
    facility_manager = nil,
    dining = nil,
    meals = {},
    lobby_meals = {},
    life_area_meals = {},
    skills = {},
    random = {},
    lobby = {},
    life_area = {},
    lobby_cd = {},       -- menu value -> cData pointer (not serialised)
    meal_cd = {},        -- meal index -> cData pointer
    lobby_meal_cd = {},  -- lobby index -> cData pointer
    area_meal_cd = {},   -- area index -> cData pointer
}

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

local function record_summary(cd, kind, index_table)
    local rec = primitive_summary(cd, 40)
    rec.kind = kind
    rec.index_table = index_table
    rec.pointer = tostring(cd)
    rec.skills = array_values(call_method(cd, "get_MealSkill"), 12)
    rec.skill_names = {}
    for i, id in ipairs(rec.skills) do
        rec.skill_names[i] = meal_skill_name(tonumber(id) or 0)
    end
    rec.random_tables = array_values(call_method(cd, "get_RandomTable"), 8)
    -- optional name guid (some records expose get_Name / get_MenuName)
    for _, g in ipairs({ "get_Name", "get_MenuName", "getName", "get_MealName" }) do
        local guid = safe(function() return cd:call(g) end)
        if guid ~= nil then
            local text = localized(guid)
            if text then rec.name = text break end
        end
    end
    return rec
end

local function resolve_chain()
    local vm = safe(function() return sdk.get_managed_singleton("app.VariousDataManager") end)
    if not vm then return nil, "no_various_manager" end
    local setting = field_value(vm, "_Setting")
    local facility = setting and field_value(setting, "_FacilitySetting")
    local dining_setting = facility and field_value(facility, "_FacilityDiningSetting")
    if not dining_setting then return nil, "no_dining_setting" end
    data.dining_setting = dining_setting

    data.facility_manager = safe(function()
        return sdk.get_managed_singleton("app.FacilityManager")
    end)
    data.dining = nil
    if data.facility_manager then
        data.dining = call_method(data.facility_manager, "get_Dining")
            or field_value(data.facility_manager, "<Dining>k__BackingField")
    end
    return dining_setting, "ok"
end

local function dump_meals()
    local dining_setting, src = resolve_chain()
    if not dining_setting then return nil, src end

    -- _MealData: the three base records (portable/field meal templates)
    local meal_table = read_table(field_value(dining_setting, "_MealData"), 40)
    data.meals, data.meal_cd = {}, {}
    for i, cd in ipairs(meal_table.entries) do
        local rec = record_summary(cd, "MealData", i - 1)
        data.meals[#data.meals + 1] = rec
        data.meal_cd[tostring(rec._Index or rec.index_table)] = cd
    end

    -- _MealDataLobby: the canteen menus
    local lobby_table = read_table(field_value(dining_setting, "_MealDataLobby"), 40)
    data.lobby_meals, data.lobby_meal_cd = {}, {}
    for i, cd in ipairs(lobby_table.entries) do
        local rec = record_summary(cd, "MealDataLobby", i - 1)
        data.lobby_meals[#data.lobby_meals + 1] = rec
        data.lobby_meal_cd[tostring(rec._Index or rec.index_table)] = cd
    end

    -- _MealDataLifeArea: camp meals per life area
    local area_table = read_table(field_value(dining_setting, "_MealDataLifeArea"), 40)
    data.life_area_meals, data.area_meal_cd = {}, {}
    for i, cd in ipairs(area_table.entries) do
        local rec = record_summary(cd, "MealDataLifeArea", i - 1)
        data.life_area_meals[#data.life_area_meals + 1] = rec
        data.area_meal_cd[tostring(rec._Index or rec.index_table)] = cd
    end

    -- meal skill names table
    local skill_table = read_table(field_value(dining_setting, "_MealSkill"), 80)
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

    -- random table with weights
    local random_table = read_table(field_value(dining_setting, "_MealSkillRandomTable"), 200)
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

    -- canteen menu enum -> meal record
    local lobby_enum = first_enum({
        "app.DiningDef.LOBBY_MENU_ID", "app.DiningDef.MENU_ID", "app.DiningDef.LOBBY_MENU",
    })
    data.lobby, data.lobby_cd = {}, {}
    for _, e in ipairs(lobby_enum.entries) do
        local cd = static_value("app.MealUtil", "getMealDataLobby(app.DiningDef.LOBBY_MENU_ID)", e.value)
        local rec = {
            menu = e.name,
            menu_value = e.value,
            resolved = cd ~= nil,
            meal = cd and primitive_summary(cd, 10) or nil,
        }
        if cd ~= nil then data.lobby_cd[tostring(e.value)] = cd end
        data.lobby[#data.lobby + 1] = rec
    end

    -- field camp areas -> meal record
    local area_enum = first_enum({ "app.FieldDef.LIFE_AREA", "app.FieldDef.AREA" })
    data.life_area = {}
    for _, e in ipairs(area_enum.entries) do
        local cd = static_value("app.MealUtil", "getMealDataLifeArea(app.FieldDef.LIFE_AREA)", e.value)
        data.life_area[#data.life_area + 1] = {
            area = e.name,
            area_value = e.value,
            resolved = cd ~= nil,
            meal = cd and primitive_summary(cd, 10) or nil,
            active_minutes = safe_str(static_value("app.MealUtil",
                "getActiveMinutes(app.FieldDef.LIFE_AREA)", e.value)),
        }
    end

    local info = data.dining and (call_method(data.dining, "get_MealInfo")
        or field_value(data.dining, "<MealInfo>k__BackingField"))
    local out = {
        facility_manager = data.facility_manager ~= nil,
        facility_dining = data.dining ~= nil,
        dining_type = type_name(data.dining),
        dining_is_meal_effect_set = data.dining and safe_str(field_value(data.dining, "_IsMealEffectSet")) or nil,
        dining_enable_eat = data.dining and safe_str(call_method(data.dining, "EnableEat")) or nil,
        dining_ticket_item = data.dining and safe_str(field_value(data.dining, "<TicketItem>k__BackingField")) or nil,
        dining_life_area_effect = data.dining
            and tostring(field_value(data.dining, "<LifeAreaMealEffect>k__BackingField")) or nil,
        meal_info = info and { type = type_name(info), values = primitive_summary(info, 30) } or nil,
        meal_table_count = meal_table.count,
        meal_fetch_ok = meal_table.fetch_ok,
        meals = data.meals,
        lobby_table_count = lobby_table.count,
        lobby_fetch_ok = lobby_table.fetch_ok,
        lobby_meals = data.lobby_meals,
        area_table_count = area_table.count,
        area_fetch_ok = area_table.fetch_ok,
        life_area_meals = data.life_area_meals,
        skill_table_count = skill_table.count,
        skills = data.skills,
        random_table_count = random_table.count,
        random = data.random,
        lobby_enum = lobby_enum,
        lobby = data.lobby,
        life_area_enum = area_enum,
        life_area = data.life_area,
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
    lastStatus = string.format("master: meals=%s lobby=%s area=%s skills=%s random=%s dining=%s -> %s",
        tostring(out.meal_table_count), tostring(out.lobby_table_count),
        tostring(out.area_table_count), tostring(out.skill_table_count),
        tostring(out.random_table_count), tostring(out.facility_dining), OUT_MASTER)
    log.info("[MealApplyProbe2] " .. lastStatus)
    return out
end

-- ---------------------------------------------------------------------------
-- types
-- ---------------------------------------------------------------------------

local TYPES = {
    "app.cHunterMealEffect", "app.cMealEffect", "app.cHunterMealSkillParamInfo",
    "app.FacilityDining", "app.FacilityManager", "app.cMealMySetUse", "app.MealUtil",
    "app.MealDef", "app.DiningDef", "app.FieldDef", "app.savedata.cDiningParam",
    "app.user_data.MealData", "app.user_data.MealData.cData",
    "app.user_data.MealDataLobby", "app.user_data.MealDataLobby.cData",
    "app.user_data.MealDataLifeArea", "app.user_data.MealDataLifeArea.cData",
    "app.user_data.MealSkillData", "app.user_data.MealSkillData.cData",
    "app.user_data.MealSkillRandomTable", "app.user_data.MealSkillRandomTable.cData",
    "app.user_data.FacilityDiningSetting", "app.user_data.FacilitySetting",
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
            .. "(" .. table.concat(params, ", ") .. ") -> "
            .. tostring(safe(function() return m:get_return_type():get_full_name() end))
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
local add_randoms = true

local function current_menu()
    local list = {}
    for _, m in ipairs(data.lobby) do
        if m.resolved then list[#list + 1] = m end
    end
    if #list == 0 then return nil end
    if menu_index > #list then menu_index = 1 end
    return list[menu_index], #list
end

local function record_attempt(rec)
    attempts[#attempts + 1] = rec
    while #attempts > MAX_ATTEMPTS do table.remove(attempts, 1) end
    dump_json(OUT_APPLY, { attempts = attempts, menu_index = menu_index })
end

local COPY_SIGNATURES = {
    MealData = "copyFrom(app.user_data.MealData.cData, System.Boolean)",
    MealDataLobby = "copyFrom(app.user_data.MealDataLobby.cData, System.Boolean)",
    MealDataLifeArea = "copyFrom(app.user_data.MealDataLifeArea.cData, System.Boolean)",
}

-- A) facility path: the facility applies the meal itself. No eat event, no
--    item consumption.
local function apply_menu()
    if #data.lobby == 0 then pcall(dump_meals) end
    local menu, total = current_menu()
    if menu == nil then
        lastStatus = "apply menu: no resolved lobby menu (press Dump master data)"
        return
    end
    local dining = data.dining
    local rec = {
        action = "setMealEffectLobby",
        menu = menu.menu,
        menu_value = menu.menu_value,
        dining_present = dining ~= nil,
        before = meal_state(),
    }
    if dining == nil then
        rec.fail = "no_dining_instance (FacilityManager:get_Dining returned nil)"
        record_attempt(rec)
        lastStatus = "apply menu: " .. tostring(rec.fail)
        return
    end
    rec.enable_eat = safe_str(call_method(dining, "EnableEat"))
    rec.is_meal_effect_set = safe_str(field_value(dining, "_IsMealEffectSet"))
    local ok, err = call_void(dining,
        "setMealEffectLobby(app.DiningDef.LOBBY_MENU_ID)", menu.menu_value)
    rec.call_ok = ok
    rec.call_error = err
    rec.after = meal_state()
    pending_verify = { frames = VERIFY_FRAMES, done = {}, readings = {} }
    record_attempt(rec)
    lastStatus = string.format("apply menu %s (%d/%d): call=%s",
        tostring(menu.menu), menu_index, total, tostring(ok))
    log.info("[MealApplyProbe2] " .. lastStatus)
end

-- B) build the effect from the menu's record, add its random buffs, attach it.
local function build_and_apply()
    if #data.lobby == 0 then pcall(dump_meals) end
    local menu, total = current_menu()
    if menu == nil then
        lastStatus = "build: no resolved lobby menu"
        return
    end
    local cd = data.lobby_cd[tostring(menu.menu_value)]
    if cd == nil then
        cd = static_value("app.MealUtil", "getMealDataLobby(app.DiningDef.LOBBY_MENU_ID)", menu.menu_value)
    end
    if cd == nil then
        lastStatus = "build: menu record not resolved"
        return
    end

    local rec = {
        action = "build_and_apply",
        menu = menu.menu,
        menu_value = menu.menu_value,
        random_buffs = add_randoms,
        record = primitive_summary(cd, 20),
        before = meal_state(),
    }

    local effect = safe(function() return sdk.create_instance("app.cMealEffect") end)
    if effect == nil then
        rec.fail = "no_instance:cMealEffect"
        record_attempt(rec)
        lastStatus = rec.fail
        return
    end
    safe(function() effect:add_ref() end)
    rec.effect_pointer = tostring(effect)

    local copy_sig = COPY_SIGNATURES.MealDataLobby
    local copied, copy_err = call_void(effect, copy_sig, cd, false)
    rec.copy = { ok = copied, error = copy_err, signature = copy_sig }
    rec.effect_after_copy = effect_summary(effect)

    local added, add_errors = 0, {}
    if add_randoms then
        for _, tbl in ipairs(array_values(call_method(cd, "get_RandomTable"), 8)) do
            local num = tonumber(tbl)
            if num then
                local ok, err = call_void(effect,
                    "addRandomTableParam(app.MealDef.RANDOM_SKILL_TBL_Fixed)", num)
                if ok then added = added + 1 else add_errors[#add_errors + 1] = tostring(err) end
            end
        end
    end
    rec.random_added = added
    rec.random_errors = add_errors
    rec.effect_after_randoms = effect_summary(effect)

    local meal, msrc = meal_object()
    if not meal then
        rec.fail = "no_meal_object:" .. tostring(msrc)
        record_attempt(rec)
        lastStatus = rec.fail
        return
    end
    local attached, attach_err = call_void(meal,
        "setMealEffect(app.cMealEffect, System.Boolean)", effect, false)
    rec.attach = { ok = attached, error = attach_err }
    rec.after_attach = meal_state()

    -- timer: the record's _Time is minutes; mirror the real eat (70 min)
    local minutes = tonumber(rec.record._Time) or 70
    local timer_ok, timer_err = call_void(meal, "setDurationTimer(System.Single)", minutes * 60)
    local timer_active_ok, timer_active_err = call_void(meal, "setTimerActive(System.Boolean)", true)
    local effect_active_ok, effect_active_err = call_void(meal, "setEffectActive(System.Boolean)", true)
    rec.timer = {
        minutes = minutes,
        duration_ok = timer_ok, duration_error = timer_err,
        timer_active_ok = timer_active_ok, timer_active_error = timer_active_err,
        effect_active_ok = effect_active_ok, effect_active_error = effect_active_err,
    }
    rec.after = meal_state()
    pending_verify = { frames = VERIFY_FRAMES, done = {}, readings = {} }
    record_attempt(rec)
    lastStatus = string.format("build+apply %s: copy=%s randoms=%d attach=%s",
        tostring(menu.menu), tostring(copied), added, tostring(attached))
    log.info("[MealApplyProbe2] " .. lastStatus)
end

-- C) build only: shows what copyFrom + randoms produce before any attach.
local function build_only()
    if #data.lobby == 0 then pcall(dump_meals) end
    local menu = current_menu()
    if menu == nil then
        lastStatus = "build only: no resolved lobby menu"
        return
    end
    local cd = data.lobby_cd[tostring(menu.menu_value)]
    if cd == nil then
        lastStatus = "build only: menu record not resolved"
        return
    end
    local effect = safe(function() return sdk.create_instance("app.cMealEffect") end)
    if effect == nil then
        lastStatus = "build only: create_instance failed"
        return
    end
    safe(function() effect:add_ref() end)
    local rec = {
        action = "build_only",
        menu = menu.menu,
        menu_value = menu.menu_value,
        record = primitive_summary(cd, 20),
        before = meal_state(),
    }
    rec.copy = { ok = call_void(effect, COPY_SIGNATURES.MealDataLobby, cd, false) }
    rec.effect_after_copy = effect_summary(effect)
    local added = 0
    for _, tbl in ipairs(array_values(call_method(cd, "get_RandomTable"), 8)) do
        local num = tonumber(tbl)
        if num then
            local ok = call_void(effect, "addRandomTableParam(app.MealDef.RANDOM_SKILL_TBL_Fixed)", num)
            if ok then added = added + 1 end
        end
    end
    rec.random_added = added
    rec.effect_after_randoms = effect_summary(effect)
    record_attempt(rec)
    lastStatus = string.format("build only %s: skills %s -> %s, randoms=%d",
        tostring(menu.menu),
        tostring(rec.effect_after_copy.fields.SKILL_NUM),
        tostring(rec.effect_after_randoms.fields.SKILL_NUM), added)
    log.info("[MealApplyProbe2] " .. lastStatus)
end

local ACTIONS = { menu = apply_menu, build = build_and_apply, dry = build_only }

local function request_action(name)
    if ACTIONS[name] == nil then return end
    if pending_action ~= nil then
        lastStatus = "busy: " .. tostring(pending_action)
        return
    end
    pending_action = name
    lastStatus = "queued: " .. name .. " (runs next frame)"
end

local function cycle_menu(delta)
    if #data.lobby == 0 then pcall(dump_meals) end
    local _, total = current_menu()
    if total == nil then
        lastStatus = "no resolved menus (press Dump master data)"
        return
    end
    menu_index = ((menu_index - 1 + delta) % total) + 1
    local m = current_menu()
    lastStatus = string.format("menu %d/%d: %s (record %s)",
        menu_index, total, tostring(m and m.menu), tostring(m and m.meal and m.meal._Index))
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
        dump_json(OUT_APPLY, { attempts = attempts, verify = pending_verify.readings })
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
    imgui.text("phase 2: meal tables + game apply path (no hooks)")
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
    local menu, total = current_menu()
    imgui.text(string.format("menu %d/%d: %s  (record %s)",
        menu_index, total or 0,
        menu and tostring(menu.menu) or "?",
        menu and tostring(menu.meal and menu.meal._Index) or "?"))
    if imgui.button("< Prev menu") then cycle_menu(-1) end
    imgui.same_line()
    if imgui.button("Next menu >") then cycle_menu(1) end
    imgui.same_line()
    if imgui.button(add_randoms and "Randoms: on" or "Randoms: off") then
        add_randoms = not add_randoms
    end

    imgui.separator()
    if imgui.button("Apply menu (facility)") then request_action("menu") end
    imgui.same_line()
    if imgui.button("Build + apply") then request_action("build") end
    imgui.same_line()
    if imgui.button("Build only") then request_action("dry") end
    imgui.text(string.format("meals=%d lobby=%d area=%d skills=%d random=%d attempts=%d",
        #data.meals, #data.lobby_meals, #data.life_area_meals,
        #data.skills, #data.random, #attempts))

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
    imgui.text("1) Dump types, Dump master data (read-only).")
    imgui.text("2) Cycle to a menu, press Build only to see the effect values.")
    imgui.text("3) Press Build + apply; check HP/stamina/attack/defence/skills.")
    imgui.text("4) Try Apply menu (facility) too, and repeat in a quest at camp.")
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
        .. " (meal tables + apply path; no hooks)")
else
    log.info("[MealApplyProbe2] duplicate load ignored")
end
