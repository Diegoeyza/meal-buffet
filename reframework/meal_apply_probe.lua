--
-- meal_apply_probe.lua v2 — discovery probe for the Meal Buffet mod
--
-- Goal: apply any canteen meal to the local hunter on demand, anywhere
-- (hub, camp, training grounds, mid-quest), without a voucher, choosing the
-- base meal and the extra random meal skills.
--
-- What this probe must answer in one game session:
--   1. type surface: fields and full method signatures of the meal/dining/
--      canteen classes, so the apply path can be found;
--   2. master data: the base meals with their fixed skill sets, plus the
--      random meal-skill pool and its weights;
--   3. the eat call: which game method performs a canteen eat, with which
--      arguments and which return value (hooks, every distinct signature is
--      recorded once with first/last time and a count);
--   4. the write set: a full meal-state snapshot before/after a real eat, and
--      again after a voucher eat (the snapshots are appended to one file so
--      they can be diffed).
--
-- It also carries the write-path experiment for the fallback: clone the
-- primitive fields of a real meal, strip it, write the clone back, read every
-- field back and verify at +15/+120 frames. This tests the numeric/add/flag
-- path only; rebuilding the food-skill list needs the cInfo shape from the
-- type dump and is the next probe step.
--
-- Load: <game>\reframework\autorun\meal_apply_probe.lua, then REFramework
--   menu (Insert) -> Script Generated UI -> "Meal Buffet Probe".
--   Reload: REFramework menu -> Script -> Reset scripts (Reset recreates the
--   Lua state, so the duplicate-load guard below never blocks a reload).
-- Footprint: two pointer-only hooks on cQuestPlaying (update/exit, to label
--   in-quest vs out-of-quest runs, registered at load, pcall-guarded) plus the
--   capture hooks, which only exist after "Arm hooks" is pressed. The frame
--   callback only runs while a verification is scheduled. Writes happen only
--   on the explicit Clone/Strip/Apply buttons, and only when the resolved
--   hunter is the user-controlled one.
--
-- Lineage: helper shapes (safe wrappers, field descriptor reads, local hunter
--   resolution, hook arg capture) follow this author's meal_probe and
--   kill_probe (MIT ancestry: Hunt Dumper by thieleju); the meal master-data
--   paths follow _CatLib (read-only reference, no code copied).
--
-- Every SDK call is pcall-guarded: this script never throws into the game.
--

local re = re
local sdk = sdk
local json = json
local log = log
local imgui = imgui

local PROBE_VERSION = 2

local OUT_TYPES   = "meal_apply_probe_types.json"
local OUT_MASTER  = "meal_apply_probe_master.json"
local OUT_STATES  = "meal_apply_probe_states.json"
local OUT_CAPTURE = "meal_apply_probe_capture.json"
local OUT_APPLY   = "meal_apply_probe_apply.json"

-- Re-running the script must not register a second set of callbacks/hooks.
-- (Reset scripts destroys the Lua state, so a reload gets a fresh _G.)
local ALREADY_LOADED = _G.MEAL_APPLY_PROBE_LOADED == true
_G.MEAL_APPLY_PROBE_LOADED = true

local PER_TYPE_HOOKS = 12
local MAX_HOOKS = 90
local MAX_SIGNATURES = 300
local MAX_MASTER_ENTRIES = 60
local MAX_STATES = 40
local MAX_ERRORS = 30
local VERIFY_FRAMES = { 15, 120 }

local lastStatus = "(idle)"
local armed = false
local pending_verify = nil
local pending_action = nil   -- "clone" | "strip" | "apply", executed on the next frame
local capture_epoch = 0
local ret_samples = {}      -- method full name -> { values }

local errors = {}
local function note_error(where, err)
    if #errors >= MAX_ERRORS then return end
    errors[#errors + 1] = {
        where = where,
        err = tostring(err),
        wall = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
    log.warn("[MealApplyProbe] " .. tostring(where) .. ": " .. tostring(err))
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
-- small helpers (same shapes meal_probe/kill_probe prove on this build)
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
    if not td then return nil end
    return safe(function() return td:get_full_name() end)
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

-- typecall is only ever called with (type, method, object): no varargs, so the
-- call closure does not need to forward any. (Using `...` inside a nested
-- closure is a LuaJIT compile error: "cannot use '...' outside a vararg
-- function".)
local function typecall(typeName, methodName, obj)
    local td = safe(sdk.find_type_definition, typeName)
    if not td then return nil end
    local m = safe(function() return td:get_method(methodName .. "()") end)
        or safe(function() return td:get_method(methodName) end)
    if not m then return nil end
    return safe(function() return m:call(obj) end)
end

-- Field descriptor read: obj:get_field() returns nil for several Hunter/Wilds
-- structs, get_data(obj) does not. Static fields take nil.
local function field_value(obj, fieldName)
    if obj == nil then return nil end
    local td = safe(function() return obj:get_type_definition() end)
    if not td then return nil end
    for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
        if safe(function() return f:get_name() end) == fieldName then
            local is_static = safe(function() return f:is_static() end)
            return safe(function() return f:get_data(is_static and nil or obj) end)
        end
    end
    return nil
end

local function write_field(obj, typeName, fieldName, value)
    if obj == nil then return false, "no_object" end
    local ok = safe(function() obj:set_field(fieldName, value) return true end)
    if ok then return true, "set_field" end
    local td = safe(sdk.find_type_definition, typeName)
    if not td then return false, "no_type" end
    local ok2 = safe(function()
        sdk.set_native_field(obj, td, fieldName, value)
        return true
    end)
    return ok2 == true, ok2 and "set_native_field" or "write_failed"
end

local function array_get(arr, i)
    local v = safe(function() return arr[i] end)
    if v == nil then
        local td = safe(function() return arr:get_type_definition() end)
        local m = td and safe(function() return td:get_method("get_Item(System.Int32)") end)
        if m then v = safe(function() return m:call(arr, i) end) end
    end
    return v
end

local function collection_count(c)
    local n = safe(function() return c:get_Count() end)
    if n == nil then
        local get_count = safe(function() return c.get_Count end)
        if get_count then n = safe(function() return get_count:call(c) end) end
    end
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
    return array_get(c, i)
end

-- _Values is the values view of a via.Dictionary (proven by _CatLib).
local function dict_values(dict)
    if dict == nil then return nil end
    return field_value(dict, "_Values") or dict
end

-- Fail closed: a missing helper or a non-object means "not managed". The old
-- "true when the helper is missing" behaviour could write a stale pointer into
-- live state.
local function is_managed(obj)
    if obj == nil then return false end
    if sdk.is_managed_object ~= nil then
        return safe(sdk.is_managed_object, obj) == true
    end
    if type(obj) ~= "userdata" then return false end
    return safe(function() return obj:get_type_definition() end) ~= nil
end

-- ---------------------------------------------------------------------------
-- local hunter resolution (never getMasterPlayer for writes)
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
    return field_value(inst, "<Character>k__BackingField")
        or field_value(inst, "_Character")
end

local function local_status()
    local pm = safe(function() return sdk.get_managed_singleton("app.PlayerManager") end)
    if not pm then return nil, "no_player_manager" end
    local arr = instanced_array(pm)
    if arr then
        for i = 0, 7 do
            local inst = array_get(arr, i)
            if inst == nil then break end
            local pi = call_method(inst, "get_PlayerInfo")
            local ch = character_of(inst, pi)
            local st = ch and call_method(ch, "get_HunterStatus")
            if st then
                local is_user = call_method(st, "get_IsUserControl")
                local is_npc = call_method(st, "get_IsNpc")
                if is_user == true and is_npc ~= true then
                    return st, "user_control"
                end
            end
        end
    end
    local mp = typecall("app.PlayerManager", "getMasterPlayer", pm)
    local ch = mp and (field_value(mp, "<Character>k__BackingField")
        or call_method(mp, "get_Character"))
    local st = ch and call_method(ch, "get_HunterStatus")
    if st then return st, "master_fallback" end
    return nil, "no_status"
end

local function meal_object()
    local st, src = local_status()
    if not st then return nil, src end
    local meal = field_value(st, "_MealEffect")
    if meal == nil then
        -- Field-name fallback: scan cHunterStatus for a field whose value is a
        -- meal effect object. A rename then degrades to a slower path instead
        -- of a session with no data.
        local td = safe(function() return st:get_type_definition() end)
        for _, f in ipairs(safe(function() return td and td:get_fields() end) or {}) do
            local is_static = safe(function() return f:is_static() end)
            local v = safe(function() return f:get_data(is_static and nil or st) end)
            local tn = v and type_name(v)
            if tn == "app.cHunterMealEffect" or tn == "app.cMealEffect" then
                return v, src .. "+scan:" .. tostring(safe(function() return f:get_name() end)), st
            end
        end
        return nil, "no_meal_object"
    end
    return meal, src, st
end

-- Write paths only ever touch the user-controlled hunter. In a link party the
-- master player is the host, so the fallback is refused with a reason.
local function meal_object_for_write()
    local meal, src, st = meal_object()
    if not meal then return nil, src end
    if not tostring(src):find("^user_control") then
        return nil, "not_user_control(" .. tostring(src) .. ")"
    end
    return meal, src, st
end

-- ---------------------------------------------------------------------------
-- generic value dumping
--
-- Every instance field is read through its descriptor and kept when the value
-- is a primitive; that includes enums (which come back as integers), booleans,
-- numbers and strings. Object-valued fields are recorded by type only.
-- ---------------------------------------------------------------------------

local function value_summary(obj, maxGetters, knownGetters)
    local out = { type = type_name(obj), fields = {}, getters = {}, object_fields = {} }
    if obj == nil then return out end
    local td = safe(function() return obj:get_type_definition() end)
    if not td then return out end

    for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
        local fname = safe(function() return f:get_name() end)
        if fname then
            local is_static = safe(function() return f:is_static() end)
            local v = safe(function() return f:get_data(is_static and nil or obj) end)
            if is_primitive(v) then
                out.fields[fname] = v
            elseif v ~= nil then
                out.object_fields[fname] = type_name(v) or tostring(v)
            end
        end
    end

    local n = 0
    for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
        if maxGetters and n >= maxGetters then break end
        local mname = safe(function() return m:get_name() end) or ""
        local nparams = safe(function() return m:get_num_params() end) or 0
        if mname:find("^get_") and nparams == 0 then
            local v = safe(function() return m:call(obj) end)
            if is_primitive(v) then
                out.getters[mname] = v
                n = n + 1
            end
        end
    end

    -- The meal getters the mod cares about are always captured, whatever the
    -- generic cap did.
    for _, gname in ipairs(knownGetters or {}) do
        if out.getters[gname] == nil then
            local v = safe(function() return obj:call(gname) end)
            if is_primitive(v) then out.getters[gname] = v end
        end
    end
    return out
end

-- Read-back helper: proves a write actually landed.
local function readback_after_write(obj, fields)
    local out = {}
    for _, rec in ipairs(fields or {}) do
        out[rec.name] = safe_str(field_value(obj, rec.name))
    end
    return out
end

local function describe_method(m, declaringType)
    local params, full_params = {}, {}
    local n = safe(function() return m:get_num_params() end) or 0
    local pts = safe(function() return m:get_param_types() end) or {}
    for i = 1, n do
        local t = pts[i]
        local short = safe_str(safe(function() return t:get_name() end)) or "?"
        local full = safe_str(safe(function() return t:get_full_name() end)) or short
        params[#params + 1] = short
        full_params[#full_params + 1] = full
    end
    local name = safe(function() return m:get_name() end)
    -- Method:is_static() is not proven on this build; nil means "decide at
    -- hook time" by checking whether args[2] is an object of the declaring
    -- type, which is what the hook body does.
    local static = safe(function() return m:is_static() end)
    if static ~= nil then static = static == true end
    return {
        name = name,
        full = safe(function() return m:get_full_name() end),
        declaring = declaringType,
        static = static,
        ret = safe_str(safe(function() return m:get_return_type():get_full_name() end)),
        params = full_params,
        params_short = params,
        signature = (name or "?") .. "(" .. table.concat(full_params, ", ") .. ")",
    }
end

local function dump_type(typeName)
    local td = safe(sdk.find_type_definition, typeName)
    local entry = { name = typeName, exists = td ~= nil }
    if not td then return entry end
    entry.full_name = safe(function() return td:get_full_name() end)

    local fields = safe(function() return td:get_fields() end)
    if fields then
        entry.fields = {}
        for _, f in ipairs(fields) do
            entry.fields[#entry.fields + 1] = {
                name = safe(function() return f:get_name() end),
                type = safe_str(safe(function() return f:get_type():get_name() end)),
                type_full = safe_str(safe(function() return f:get_type():get_full_name() end)),
                static = safe(function() return f:is_static() end),
            }
        end
    end

    local methods = safe(function() return td:get_methods() end)
    if methods then
        entry.methods = {}
        entry.methods_total = #methods
        local limit = #methods
        if limit > 200 then
            limit = 200
            entry.methods_truncated = true
        end
        for i = 1, limit do
            entry.methods[#entry.methods + 1] = describe_method(methods[i], typeName)
        end
    end
    return entry
end

-- ---------------------------------------------------------------------------
-- type surface (question 1)
-- ---------------------------------------------------------------------------

local TYPES = {
    -- meal state on the hunter (first: these are the write targets)
    "app.cHunterMealEffect", "app.cMealEffect", "app.cHunterMealSkillParamInfo",
    "app.cHunterMealSkillParamInfo.cInfo", "app.cHunterStatus",
    "app.cHunterItemBuff", "app.cHunterAttackPower", "app.cHunterDefencePower",
    "app.cHunterCritical", "app.cHunterHealth", "app.cHunterStamina",
    -- definitions / data
    "app.MealDef", "app.user_data.MealSkillData", "app.user_data.MealSkillData.cData",
    "app.user_data.MealSkillRandomTable", "app.user_data.MealSkillRandomTable.cData",
    "app.user_data.FacilityDiningSetting", "app.user_data.FacilityDiningSetting.cData",
    "app.user_data.FacilitySetting", "app.user_data.FacilitySetting.cData",
    "app.user_data.MealData", "app.user_data.MealData.cData",
    "app.user_data.MealSetData", "app.user_data.MealSetData.cData",
    "app.user_data.MealMenuData", "app.user_data.MealMenuData.cData",
    "app.user_data.DiningData", "app.user_data.DiningData.cData",
    "app.user_data.CourseData", "app.user_data.CourseData.cData",
    "app.user_data.MealVoucherData", "app.user_data.MealVoucherData.cData",
    -- dining / canteen / order path candidates
    "app.FacilityManager", "app.cFacilityManager",
    "app.FacilityDiningManager", "app.cFacilityDiningManager",
    "app.FacilityDining", "app.cFacilityDining",
    "app.DiningManager", "app.cDiningManager", "app.DiningDef",
    "app.MealManager", "app.cMealManager", "app.MealUtil", "app.cMealUtil",
    "app.CampManager", "app.cCampManager", "app.CampUtil",
    "app.GuiDining", "app.cGuiDining", "app.GuiMeal", "app.cGuiMeal",
    "app.GuiRestaurant", "app.cGuiRestaurant",
    -- environment
    "app.PlayerManager", "app.VariousDataManager", "app.QuestManager",
    "app.cQuestPlaying", "app.MessageUtil",
}

local ENUMS = {
    "app.MealDef.SKILL", "app.MealDef.MEAL_ID", "app.MealDef.MEAL_TYPE",
    "app.MealDef.VOUCHER", "app.ItemDef.ID",
}

local function dump_enum(enumName)
    local td = safe(sdk.find_type_definition, enumName)
    local out = { name = enumName, exists = td ~= nil, values = {} }
    if not td then return out end
    for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
        if safe(function() return f:is_static() end) then
            local name = safe(function() return f:get_name() end)
            local v = safe(function() return f:get_data(nil) end)
            if name and v ~= nil then
                out.values[#out.values + 1] = { name = name, value = safe_str(v) }
            end
        end
    end
    return out
end

local function dump_types()
    local out = { kinds = {}, enums = {} }
    local hits = {}
    for _, name in ipairs(TYPES) do
        local ok, e = pcall(dump_type, name)
        if ok then
            out.kinds[#out.kinds + 1] = e
            if e.exists then hits[#hits + 1] = name end
        else
            note_error("dump_type " .. name, e)
            out.kinds[#out.kinds + 1] = { name = name, error = tostring(e) }
        end
    end
    for _, name in ipairs(ENUMS) do
        local ok, e = pcall(dump_enum, name)
        if ok then
            out.enums[#out.enums + 1] = e
        else
            note_error("dump_enum " .. name, e)
        end
    end
    dump_json(OUT_TYPES, out)
    lastStatus = string.format("types: %d/%d exist -> %s", #hits, #TYPES, OUT_TYPES)
    log.info("[MealApplyProbe] " .. lastStatus)
    log.info("[MealApplyProbe] existing: " .. table.concat(hits, ", "))
    return out
end

-- ---------------------------------------------------------------------------
-- master data (question 2)
-- ---------------------------------------------------------------------------

local dbg = {
    various = nil,
    setting = nil,
    facility = nil,
    dining = nil,
}

local function resolve_data_chain()
    local vm = safe(function() return sdk.get_managed_singleton("app.VariousDataManager") end)
    if not vm then return nil, "no_various_manager" end
    dbg.various = vm
    local setting = field_value(vm, "_Setting")
    if not setting then return nil, "no_setting" end
    dbg.setting = setting
    local facility = field_value(setting, "_FacilitySetting")
    if not facility then return nil, "no_facility_setting" end
    dbg.facility = facility
    local dining = field_value(facility, "_FacilityDiningSetting")
    if not dining then return nil, "no_facility_dining_setting" end
    dbg.dining = dining
    return dining, "ok"
end

local get_meal_skill_name_m = nil
local get_message_m = nil

local function resolve_text_helpers()
    if get_meal_skill_name_m == nil then
        local mu = safe(sdk.find_type_definition, "app.MessageUtil")
        get_meal_skill_name_m = mu and safe(function()
            return mu:get_method("getMealSkillName(app.MealDef.SKILL)")
        end) or false
        if get_meal_skill_name_m == false and mu then
            -- fall back to the bare name if this build spells it differently
            get_meal_skill_name_m = safe(function() return mu:get_method("getMealSkillName") end) or false
        end
    end
    if get_message_m == nil then
        local gm = safe(sdk.find_type_definition, "via.gui.message")
        get_message_m = gm and safe(function() return gm:get_method("get(System.Guid)") end) or false
    end
end

local function meal_skill_name(id)
    if id == nil then return nil end
    resolve_text_helpers()
    if get_meal_skill_name_m == false or get_message_m == false then return nil end
    local guid = safe(function() return get_meal_skill_name_m:call(nil, id) end)
    if guid == nil then return nil end
    return safe(function() return get_message_m:call(nil, guid) end)
end

-- One data table: a collection of cData records (via _Values) or an array.
local function dump_table(obj, fieldName, maxEntries)
    resolve_text_helpers()
    local rec = { field = fieldName }
    local v = field_value(obj, fieldName)
    if v == nil then
        rec.miss = true
        return rec
    end
    if is_primitive(v) then
        rec.value = v
        rec.primitive = true
        return rec
    end
    rec.type = type_name(v)
    local values = dict_values(v)
    local n = collection_count(values)
    rec.count = n
    if not n then
        rec.note = "not a collection"
        rec.summary = value_summary(v, 20)
        return rec
    end
    rec.entries = {}
    local limit = n
    if maxEntries and limit > maxEntries then limit = maxEntries end
    -- 0-based is the proven indexer; one 1-based retry covers a build that
    -- exposes a different collection view, and the failure is recorded so an
    -- empty entries list is never mistaken for an empty table.
    local base = 0
    local first = (n > 0) and collection_get(values, 0) or nil
    if first == nil and n > 0 then
        base = 1
        first = collection_get(values, 1)
    end
    rec.index_base = base
    if first == nil and n > 0 then
        rec.fetch_failed = true
        return rec
    end
    for i = 0, limit - 1 do
        local item = collection_get(values, base + i)
        if item == nil then
            if i == 0 and first ~= nil then item = first end
            if item == nil then
                rec.fetch_failed_at = i
                break
            end
        end
        local e = value_summary(item, 40)
        e.index = i
        local skill = safe(function() return item:call("get_MealSkill") end)
        if skill ~= nil then
            e.meal_skill = safe_str(skill)
            e.name = meal_skill_name(skill)
            local desc_guid = safe(function() return item:call("get_Explain") end)
            if desc_guid ~= nil and get_message_m and get_message_m ~= false then
                e.description = safe(function() return get_message_m:call(nil, desc_guid) end)
            end
        end
        rec.entries[#rec.entries + 1] = e
    end
    return rec
end

-- Shallow field map of a data node (name, type, collection size). Used on
-- _Setting and _FacilitySetting so the base-meal table can be found even if it
-- lives outside _FacilityDiningSetting. Names and counts only: entries are
-- dumped for the dining node itself, which keeps this pass cheap.
local function dump_node(obj, label)
    local out = { label = label, type = type_name(obj), fields = {} }
    if obj == nil then
        out.miss = true
        return out
    end
    local td = safe(function() return obj:get_type_definition() end)
    for _, f in ipairs(safe(function() return td and td:get_fields() end) or {}) do
        local fname = safe(function() return f:get_name() end)
        if fname then
            local is_static = safe(function() return f:is_static() end)
            local v = safe(function() return f:get_data(is_static and nil or obj) end)
            local rec = { name = fname, type = type_name(v) }
            if is_primitive(v) then
                rec.value = v
            else
                rec.count = collection_count(dict_values(v))
            end
            out.fields[#out.fields + 1] = rec
        end
    end
    return out
end

-- Which candidate manager objects are actually live singletons on this build.
-- A type can exist without a singleton, so this is checked separately from
-- dump_types.
local SINGLETON_CANDIDATES = {
    "app.VariousDataManager", "app.PlayerManager", "app.SaveDataManager",
    "app.GameFlowManager", "app.MissionManager", "app.GUIManager",
    "app.NpcManager", "app.OtomoManager", "app.PorterManager",
    "app.FacilityManager", "app.cFacilityManager",
    "app.FacilityDiningManager", "app.cFacilityDiningManager",
    "app.DiningManager", "app.cDiningManager",
    "app.MealManager", "app.cMealManager", "app.MealUtil", "app.cMealUtil",
    "app.CampManager", "app.cCampManager", "app.RestaurantManager",
    "app.CanteenManager", "app.HunterManager", "app.QuestManager",
}

local function probe_singletons()
    local out = {}
    for _, name in ipairs(SINGLETON_CANDIDATES) do
        local obj = safe(function() return sdk.get_managed_singleton(name) end)
        out[name] = {
            exists = obj ~= nil,
            type = obj and type_name(obj) or nil,
        }
    end
    return out
end

local function dump_master()
    local out = { nodes = {}, tables = {} }
    local dining, src = resolve_data_chain()
    if not dining then
        out.fail = src
        dump_json(OUT_MASTER, out)
        lastStatus = "master: " .. tostring(src)
        log.warn("[MealApplyProbe] " .. lastStatus)
        return out
    end

    out.chain = {
        various = type_name(dbg.various),
        setting = type_name(dbg.setting),
        facility = type_name(dbg.facility),
        dining = type_name(dining),
    }

    for _, node in ipairs({
        { label = "VariousDataManager._Setting", obj = dbg.setting },
        { label = "_Setting._FacilitySetting", obj = dbg.facility },
    }) do
        local ok, rec = pcall(dump_node, node.obj, node.label)
        if ok then
            out.nodes[#out.nodes + 1] = rec
        else
            note_error("dump_node " .. node.label, rec)
        end
    end

    local td = safe(function() return dining:get_type_definition() end)
    for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
        local fname = safe(function() return f:get_name() end)
        if fname then
            -- smaller sample for the "find the table" pass; the two tables the
            -- mod actually needs are dumped in full below
            local ok, rec = pcall(dump_table, dining, fname, 20)
            if ok then
                out.tables[#out.tables + 1] = rec
            else
                note_error("dump_table " .. tostring(fname), rec)
                out.tables[#out.tables + 1] = { field = fname, error = tostring(rec) }
            end
        end
    end

    local meal_skills = dump_table(dining, "_MealSkill", MAX_MASTER_ENTRIES)
    local random_skills = dump_table(dining, "_MealSkillRandomTable", MAX_MASTER_ENTRIES)
    out.meal_skill_table = meal_skills
    out.random_table = random_skills
    out.singletons = probe_singletons()

    dump_json(OUT_MASTER, out)
    lastStatus = string.format("master: %d tables, meal=%s random=%s -> %s",
        #out.tables, tostring(meal_skills.count), tostring(random_skills.count), OUT_MASTER)
    log.info("[MealApplyProbe] " .. lastStatus)
    return out
end

-- ---------------------------------------------------------------------------
-- quest state (labels mid-quest vs out-of-quest runs)
--
-- cQuestPlaying is not reachable as a singleton; its instance is captured from
-- update() and dropped on exit() (proven by meal_probe). The hook bodies are
-- pcall-guarded so a build change cannot log an error every frame.
-- ---------------------------------------------------------------------------

local quest_state = nil

local function quest_state_report()
    local out = { in_quest = false }
    if quest_state == nil then
        out.reason = "no_quest_state"
        return out
    end
    if not is_managed(quest_state) then
        quest_state = nil
        out.reason = "stale"
        return out
    end
    out.in_quest = true
    out.type = type_name(quest_state)
    out.is_meal_effect_active = safe_str(safe(function()
        return quest_state:call("isMealEffectActive")
    end))
    return out
end

-- ---------------------------------------------------------------------------
-- meal snapshots (question 4)
--
-- Snapshots are appended to one file, each with a user-chosen tag, so a
-- before/after normal eat and a after-voucher eat can be diffed in place.
-- ---------------------------------------------------------------------------

local SNAPSHOT_TAGS = {
    "before", "after_eat", "after_voucher", "after_strip", "after_apply", "mid_quest",
}
local snapshot_tag_index = 1
local states = nil       -- loaded lazily, appended in memory

local KNOWN_MEAL_GETTERS = {
    "get_AttackAdd", "get_DefenceAdd", "get_AttrResistAdd",
    "get_IsActiveGuts_S", "get_IsActiveGuts_L", "get_IsActiveHeroic",
    "get_IsUnevenActive_S", "get_IsUnevenActive_L",
    "get_IsActiveRestBuff", "get_IsActiveCoolHot",
    "get_DurationTimer", "get_MaxHealthAdd", "get_MaxStaminaAdd",
    "get_IsEffectActive",
}

local function stats_snapshot(st)
    local out = {}
    if st == nil then return out end
    local ap = call_method(st, "get_AttackPower")
    if ap then out.attack = value_summary(ap, 20) end
    local dp = call_method(st, "get_DefencePower")
    if dp then out.defence = value_summary(dp, 20) end
    local cr = call_method(st, "get_CriticalRate")
    if cr then out.critical = value_summary(cr, 20) end
    local hp = call_method(st, "get_Health") or field_value(st, "_Health")
    if hp then out.health = value_summary(hp, 20) end
    local sp = call_method(st, "get_Stamina") or field_value(st, "_Stamina")
    if sp then out.stamina = value_summary(sp, 20) end
    return out
end

local function skill_entries(paramInfo)
    local out = { count = 0, entries = {} }
    if paramInfo == nil then return out end
    out.type = type_name(paramInfo)
    out.fields = value_summary(paramInfo, 30)
    local list = field_value(paramInfo, "_InfoList")
    out.list_type = type_name(list)
    local n = collection_count(list)
    out.count = n or 0
    if not n then return out end
    for i = 0, n - 1 do
        local item = collection_get(list, i)
        if item == nil then break end
        local e = value_summary(item, 25)
        e.index = i
        out.entries[#out.entries + 1] = e
    end
    return out
end

-- Any field that names a meal/course/voucher, kept separately so the eaten
-- meal can be identified without knowing the exact field names.
local function meal_identifiers(obj)
    local out = {}
    if obj == nil then return out end
    local td = safe(function() return obj:get_type_definition() end)
    for _, f in ipairs(safe(function() return td and td:get_fields() end) or {}) do
        local fname = safe(function() return f:get_name() end) or ""
        if fname:find("[Mm]eal") or fname:find("[Cc]ourse")
            or fname:find("[Vv]oucher") or fname:find("[Mm]enu") then
            local is_static = safe(function() return f:is_static() end)
            local v = safe(function() return f:get_data(is_static and nil or obj) end)
            if is_primitive(v) then out[fname] = v end
        end
    end
    return out
end

local function meal_state(tag)
    local out = { tag = tag, epoch = capture_epoch, wall = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    local meal, src, st = meal_object()
    out.src = src
    out.quest = quest_state_report()
    if st then out.stats = stats_snapshot(st) end
    if not meal then
        out.fail = src
        return out
    end
    out.meal_type = type_name(meal)
    out.pointer = tostring(meal)
    out.fields = value_summary(meal, 80, KNOWN_MEAL_GETTERS)
    out.identifiers = meal_identifiers(meal)

    local inner = field_value(meal, "_MealEffect")
    out.inner = value_summary(inner, 80, KNOWN_MEAL_GETTERS)
    out.inner_identifiers = meal_identifiers(inner)
    out.skills = skill_entries(field_value(meal, "_SkillParamInfo"))
    return out
end

local function load_states()
    if states ~= nil then return end
    local existing = nil
    pcall(function() existing = json.load_file(OUT_STATES) end)
    if type(existing) == "table" and type(existing.states) == "table" then
        states = existing.states
    else
        states = {}
    end
end

local function take_snapshot()
    load_states()
    local tag = SNAPSHOT_TAGS[snapshot_tag_index]
    local snap = meal_state(tag)
    states[#states + 1] = snap
    while #states > MAX_STATES do table.remove(states, 1) end
    dump_json(OUT_STATES, { states = states })
    snapshot_tag_index = snapshot_tag_index % #SNAPSHOT_TAGS + 1
    lastStatus = string.format("snapshot '%s' #%d -> %s (next tag: %s)",
        tag, #states, OUT_STATES, SNAPSHOT_TAGS[snapshot_tag_index])
    log.info("[MealApplyProbe] " .. lastStatus)
    return snap
end

local function cycle_snapshot_tag()
    snapshot_tag_index = snapshot_tag_index % #SNAPSHOT_TAGS + 1
    lastStatus = "snapshot tag: " .. SNAPSHOT_TAGS[snapshot_tag_index]
end

-- ---------------------------------------------------------------------------
-- call capture (question 3)
-- ---------------------------------------------------------------------------

-- Meal-state classes first so the per-type budget cannot be spent elsewhere.
-- `all = true` means: hook every method except getters/setters and teardown,
-- because the call that populates a meal is not guaranteed to have "meal" in
-- its name. The dining/canteen classes are guesses, so they keep the word
-- filter.
local HOOK_TYPES = {
    { name = "app.cHunterMealEffect", all = true },
    { name = "app.cMealEffect", all = true },
    { name = "app.cHunterMealSkillParamInfo", all = true },
    { name = "app.FacilityDining" },
    { name = "app.cFacilityDining" },
    { name = "app.FacilityDiningManager" },
    { name = "app.cFacilityDiningManager" },
    { name = "app.DiningManager" },
    { name = "app.cDiningManager" },
    { name = "app.MealManager" },
    { name = "app.cMealManager" },
    { name = "app.MealUtil" },
    { name = "app.cMealUtil" },
    { name = "app.FacilityManager" },
    { name = "app.cFacilityManager" },
    { name = "app.CampManager" },
    { name = "app.cCampManager" },
    { name = "app.CampUtil" },
    { name = "app.GuiDining" },
    { name = "app.cGuiDining" },
    { name = "app.GuiMeal" },
    { name = "app.cGuiMeal" },
    { name = "app.GuiRestaurant" },
    { name = "app.cGuiRestaurant" },
}

local HOOK_WORDS = {
    "apply", "eat", "order", "cook", "dining", "meal", "serve", "consume",
    "voucher", "decide", "select", "initialize", "create",
}

-- Words that are only interesting when the method name also names a meal
-- concept; otherwise UI selectors and object factories flood the capture.
local RESTRICTED_WORDS = { select = true, decide = true, create = true, initialize = true }
local MEAL_WORDS = { "meal", "dining", "canteen", "cook", "voucher" }

local HOOK_SKIP = {
    "^get_", "^is_", "^set_", "^update", "^lateUpdate", "^draw", "^calc",
    "^onFrame", "^finalize", "^%.ctor", "^%.dtor", "^reset", "^clear",
}

local captures = { hooks = {}, events = {}, seen = {}, by_type = {} }
local evicted = 0

local function contains_any(s, words)
    for _, w in ipairs(words) do
        if s:find(w, 1, true) then return true end
    end
    return false
end

local function name_is_hookable(name, hook_all)
    if name == nil then return false end
    local lower = name:lower()
    for _, pat in ipairs(HOOK_SKIP) do
        if lower:find(pat) then
            -- reset/clear on a meal-shaped class can be the "end the meal"
            -- call; keep them, drop the rest.
            if pat == "^reset" or pat == "^clear" then
                return hook_all or contains_any(lower, MEAL_WORDS)
            end
            return false
        end
    end
    if hook_all then return true end
    -- Lua patterns have no alternation, so the words are matched one by one.
    for _, word in ipairs(HOOK_WORDS) do
        if lower:find(word, 1, true) then
            if RESTRICTED_WORDS[word] then
                return contains_any(lower, MEAL_WORDS)
            end
            return true
        end
    end
    return false
end

-- Convert one raw hook argument to something readable. The declared type is
-- the full type name, so enums (app.*Def.*) are treated as integers.
local function arg_str(v, declared)
    local t = declared or ""
    if t:find("Boolean", 1, true) then
        local b = safe(sdk.to_bool, v)
        if b ~= nil then return "bool:" .. tostring(b) end
    elseif t:find("Single", 1, true) or t:find("Double", 1, true) then
        local f = safe(sdk.to_float, v)
        if f == nil then f = safe(sdk.to_double, v) end
        if f ~= nil then return string.format("float:%.5f", f) end
    elseif t:find("Int", 1, true) or t:find("UInt", 1, true)
        or t:find("Byte", 1, true) or t:find("SByte", 1, true)
        or t:find("Def.", 1, true) then
        local n = safe(sdk.to_int64, v)
        if n ~= nil then return "int:" .. tostring(n) end
    end
    local mo = safe(sdk.to_managed_object, v)
    if mo ~= nil and is_managed(mo) then
        return "obj:" .. tostring(type_name(mo))
    end
    local n = safe(sdk.to_int64, v)
    if n ~= nil then return "int:" .. tostring(n) end
    return tostring(safe_str(v))
end

local function record_signature(desc, argstrings, is_instance)
    local key = (desc.full or desc.signature) .. "|" .. table.concat(argstrings, ",")
    local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local hit = captures.seen[key]
    if hit then
        hit.count = hit.count + 1
        hit.last_wall = now
        hit.last_epoch = capture_epoch
        return
    end
    local rec = {
        method = desc.full or desc.signature,
        signature = desc.signature,
        static = (not is_instance),
        ret = desc.ret,
        params = desc.params,
        args = argstrings,
        count = 1,
        first_wall = now,
        first_epoch = capture_epoch,
        last_wall = now,
        last_epoch = capture_epoch,
    }
    captures.seen[key] = rec
    captures.events[#captures.events + 1] = rec
    while #captures.events > MAX_SIGNATURES do
        local drop = table.remove(captures.events, 1)
        evicted = evicted + 1
        if drop then
            for k, v in pairs(captures.seen) do
                if v == drop then captures.seen[k] = nil break end
            end
        end
    end
end

local function arm_hooks()
    if armed then
        lastStatus = "hooks already armed (" .. tostring(#captures.hooks) .. " registered)"
        return
    end
    local registered, failed, dupes = 0, 0, 0
    local seen_full = {}

    for _, hookType in ipairs(HOOK_TYPES) do
        if registered >= MAX_HOOKS then break end
        local typeName = hookType.name
        local td = safe(sdk.find_type_definition, typeName)
        if td then
            local per_type = 0
            captures.by_type[typeName] = captures.by_type[typeName] or { hooked = {}, skipped = 0, candidates = 0 }
            captures.by_type[typeName].all_methods = hookType.all == true
            for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
                if registered >= MAX_HOOKS then break end
                if per_type >= PER_TYPE_HOOKS then
                    captures.by_type[typeName].truncated = true
                    break
                end
                local mname = safe(function() return m:get_name() end)
                if name_is_hookable(mname, hookType.all) then
                    captures.by_type[typeName].candidates = captures.by_type[typeName].candidates + 1
                    local desc = describe_method(m, typeName)
                    local full = desc.full or (typeName .. "." .. tostring(mname))
                    if seen_full[full] then
                        dupes = dupes + 1
                    else
                        seen_full[full] = true
                        local ok = safe(function()
                            sdk.hook(m, function(args)
                                safe(function()
                                    local this = safe(sdk.to_managed_object, args[2])
                                    local this_type = (this and is_managed(this)) and type_name(this) or nil
                                    -- static detection at call time: an instance
                                    -- method receives an object of its declaring
                                    -- type in args[2]; a static one receives its
                                    -- first parameter there instead.
                                    local is_instance
                                    if desc.static == false then
                                        is_instance = true
                                    elseif desc.static == true then
                                        is_instance = false
                                    else
                                        is_instance = this_type ~= nil
                                            and this_type == desc.declaring
                                    end
                                    local base = is_instance and 3 or 2
                                    local argstrings = {}
                                    for i, ptype in ipairs(desc.params) do
                                        local raw = args[base + i - 1]
                                        argstrings[#argstrings + 1] = arg_str(raw, ptype)
                                    end
                                    if is_instance and this_type then
                                        table.insert(argstrings, 1, "this:" .. this_type)
                                    end
                                    record_signature(desc, argstrings, is_instance)
                                end)
                            end, function(retval)
                                safe(function()
                                    local list = ret_samples[full]
                                    if list == nil then
                                        list = {}
                                        ret_samples[full] = list
                                    end
                                    if #list >= 5 then return end
                                    local s = arg_str(retval, desc.ret)
                                    for _, existing in ipairs(list) do
                                        if existing == s then return end
                                    end
                                    list[#list + 1] = s
                                end)
                                return nil
                            end)
                            return true
                        end)
                        if ok then
                            registered = registered + 1
                            per_type = per_type + 1
                            captures.hooks[#captures.hooks + 1] = {
                                method = full,
                                params = desc.params,
                                ret = desc.ret,
                                static = desc.static,
                            }
                            captures.by_type[typeName].hooked[#captures.by_type[typeName].hooked + 1] = full
                        else
                            failed = failed + 1
                        end
                    end
                else
                    captures.by_type[typeName].skipped = captures.by_type[typeName].skipped + 1
                end
            end
        end
    end
    armed = true
    lastStatus = string.format("hooks armed: %d registered, %d dupes, %d failed (max %d)",
        registered, dupes, failed, MAX_HOOKS)
    log.info("[MealApplyProbe] " .. lastStatus)
end

local function dump_capture()
    local out = {
        armed = armed,
        epoch = capture_epoch,
        evicted = evicted,
        hooks = captures.hooks,
        by_type = captures.by_type,
        events = captures.events,
        ret_samples = ret_samples,
        quest = quest_state_report(),
    }
    dump_json(OUT_CAPTURE, out)
    lastStatus = string.format("capture: %d hooks, %d signatures, %d ret methods -> %s",
        #captures.hooks, #captures.events, (function()
            local n = 0
            for _ in pairs(ret_samples) do n = n + 1 end
            return n
        end)(), OUT_CAPTURE)
    log.info("[MealApplyProbe] " .. lastStatus)
    return out
end

-- ---------------------------------------------------------------------------
-- write-path experiment: clone / strip / apply clone
--
-- This tests the numeric/add/flag path. The food-skill list is kept by
-- pointer and copied as plain integers for comparison; rebuilding it from
-- master data needs the cInfo shape from the type dump.
-- ---------------------------------------------------------------------------

local MEAL_TYPE = "app.cHunterMealEffect"

local STRIP_FIELDS = {
    { name = "_IsTimerActive",      value = false },
    { name = "_IsEffectActive",     value = false },
    { name = "_DurationTimer",      value = 0.0 },
    { name = "_MaxHealthAdd",       value = 0.0 },
    { name = "_MaxStaminaAdd",      value = 0.0 },
    { name = "_TempIsTimerActive",  value = false },
    { name = "_TempIsEffectActive", value = false },
}

local clone = nil

local function clone_fields(obj)
    local out = {}
    if obj == nil then return out end
    local td = safe(function() return obj:get_type_definition() end)
    for _, f in ipairs(safe(function() return td and td:get_fields() end) or {}) do
        local fname = safe(function() return f:get_name() end)
        local is_static = safe(function() return f:is_static() end)
        if fname and not is_static then
            local v = safe(function() return f:get_data(obj) end)
            if is_primitive(v) then
                out[#out + 1] = { name = fname, value = v }
            end
        end
    end
    return out
end

local function clone_meal()
    local meal, src = meal_object_for_write()
    if not meal then
        lastStatus = "clone refused: " .. tostring(src)
        log.warn("[MealApplyProbe] " .. lastStatus)
        return nil
    end
    local inner = field_value(meal, "_MealEffect")
    local param_info = field_value(meal, "_SkillParamInfo")
    -- Keep the objects alive while the test runs (Lua ref + explicit add_ref).
    safe(function() meal:add_ref() end)
    if inner then safe(function() inner:add_ref() end) end
    if param_info then safe(function() param_info:add_ref() end) end

    clone = {
        meal = meal,
        inner = inner,
        param_info = param_info,
        meal_pointer = tostring(meal),
        inner_pointer = tostring(inner),
        param_pointer = tostring(param_info),
        meal_fields = clone_fields(meal),
        inner_fields = clone_fields(inner),
        param_fields = clone_fields(param_info),
        skills = skill_entries(param_info),
        wall = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        snapshot = meal_state("clone"),
    }
    lastStatus = string.format("clone: %d meal fields, %d inner fields, %d skill entries",
        #clone.meal_fields, #clone.inner_fields, clone.skills.count)
    log.info("[MealApplyProbe] " .. lastStatus)
    return clone
end

local function write_fields(obj, typeName, fields)
    local written, missing, mismatches = 0, {}, {}
    for _, rec in ipairs(fields or {}) do
        if field_value(obj, rec.name) == nil then
            missing[#missing + 1] = rec.name
        else
            local ok = write_field(obj, typeName, rec.name, rec.value)
            if ok then written = written + 1 end
            local got = field_value(obj, rec.name)
            if tostring(got) ~= tostring(rec.value) then
                mismatches[#mismatches + 1] = {
                    name = rec.name,
                    wanted = tostring(rec.value),
                    got = tostring(got),
                }
            end
        end
    end
    return written, missing, readback_after_write(obj, fields), mismatches
end

local function strip_meal()
    if pending_verify ~= nil then
        lastStatus = "strip: a verification is still running"
        return
    end
    local meal, src = meal_object_for_write()
    if not meal then
        lastStatus = "strip refused: " .. tostring(src)
        log.warn("[MealApplyProbe] " .. lastStatus)
        return
    end
    local out = {
        action = "strip",
        epoch = capture_epoch,
        src = src,
        before = meal_state("before_strip"),
    }
    local n, missing, rb, mismatches = write_fields(meal, MEAL_TYPE, STRIP_FIELDS)
    -- Deliberately untouched by the strip: recorded so "strip worked" is not
    -- ambiguous when the food-skill list still describes the old meal.
    out.writes = {
        fields = n,
        missing = missing,
        readback = rb,
        mismatches = mismatches,
        untouched = {
            _TimerMax = safe_str(field_value(meal, "_TimerMax")),
            skill_param_info = tostring(field_value(meal, "_SkillParamInfo")),
            skill_count = skill_entries(field_value(meal, "_SkillParamInfo")).count,
        },
        pointers = { meal = tostring(meal) },
    }
    out.after = meal_state("after_strip")
    if clone ~= nil then clone.was_stripped = true end
    pending_verify = { frames = VERIFY_FRAMES, done = {}, readings = {}, out = out }
    dump_json(OUT_APPLY, out)
    lastStatus = string.format("strip: %d/%d written, mismatches=%d, verifying +15/+120",
        n, #STRIP_FIELDS, #mismatches)
    log.info("[MealApplyProbe] " .. lastStatus)
    return out
end

local function apply_clone()
    if clone == nil then
        lastStatus = "apply clone: nothing cloned yet"
        log.warn("[MealApplyProbe] " .. lastStatus)
        return
    end
    if pending_verify ~= nil then
        lastStatus = "apply clone: a verification is still running"
        return
    end
    local meal, src = meal_object_for_write()
    if not meal then
        lastStatus = "apply clone refused: " .. tostring(src)
        log.warn("[MealApplyProbe] " .. lastStatus)
        return
    end

    local out = {
        action = "apply_clone",
        epoch = capture_epoch,
        src = src,
        clone_wall = clone.wall,
        clone_was_stripped = clone.was_stripped == true,
        before = meal_state("before_apply"),
        clone_data = {
            meal_pointer = clone.meal_pointer,
            inner_pointer = clone.inner_pointer,
            param_pointer = clone.param_pointer,
            meal_fields = clone.meal_fields,
            inner_fields = clone.inner_fields,
            skills = clone.skills,
        },
        pointers = {
            meal = tostring(meal),
            clone_meal = clone.meal_pointer,
            clone_inner = clone.inner_pointer,
            clone_param = clone.param_pointer,
            same_object = tostring(meal) == clone.meal_pointer,
            inner_live = is_managed(clone.inner),
            param_live = is_managed(clone.param_info),
            inner_type = is_managed(clone.inner) and type_name(clone.inner) or nil,
            param_type = is_managed(clone.param_info) and type_name(clone.param_info) or nil,
            inner_still_attached = tostring(field_value(meal, "_MealEffect")) == clone.inner_pointer,
            param_still_attached = tostring(field_value(meal, "_SkillParamInfo")) == clone.param_pointer,
        },
    }

    local n1, miss1, rb1, mis1 = write_fields(meal, MEAL_TYPE, clone.meal_fields)
    local n2, miss2, rb2, mis2, n3 = 0, {}, {}, {}, 0
    if out.pointers.inner_still_attached and is_managed(clone.inner)
        and type_name(clone.inner) == "app.cMealEffect" then
        n2, miss2, rb2, mis2 = write_fields(clone.inner, "app.cMealEffect", clone.inner_fields)
    elseif is_managed(clone.inner) then
        out.inner_write_skipped = "stale_or_wrong_type"
    end
    if out.pointers.param_still_attached and is_managed(clone.param_info)
        and type_name(clone.param_info) == "app.cHunterMealSkillParamInfo" then
        if write_field(meal, MEAL_TYPE, "_SkillParamInfo", clone.param_info) then n3 = 1 end
    elseif is_managed(clone.param_info) then
        out.param_write_skipped = "stale_or_wrong_type"
    end

    out.writes = {
        meal_fields = n1, meal_missing = miss1, meal_readback = rb1, meal_mismatches = mis1,
        inner_fields = n2, inner_missing = miss2, inner_readback = rb2, inner_mismatches = mis2,
        param_info_written = n3,
    }
    out.after_apply = meal_state("after_apply")
    pending_verify = { frames = VERIFY_FRAMES, done = {}, readings = {}, out = out }
    dump_json(OUT_APPLY, out)
    lastStatus = string.format("apply clone: %d+%d fields, mismatches=%d+%d, verifying +15/+120",
        n1, n2, #mis1, #mis2)
    log.info("[MealApplyProbe] " .. lastStatus)
    return out
end

-- ---------------------------------------------------------------------------
-- frame callback: only alive while a verification is scheduled
-- ---------------------------------------------------------------------------

-- Write actions run on the frame callback, not inside the UI draw pass: the
-- game thread reads the same fields, so a torn write during the render pass is
-- the one avoidable crash path.
local ACTIONS = {
    clone = clone_meal,
    strip = strip_meal,
    apply = apply_clone,
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
            local r = meal_state("after_" .. target .. "f")
            pending_verify.readings[#pending_verify.readings + 1] = r
            log.info(string.format("[MealApplyProbe] verify +%df: timer=%s active=%s hp=%s",
                target,
                tostring(r.fields and r.fields.fields and r.fields.fields._DurationTimer),
                tostring(r.fields and r.fields.fields and r.fields.fields._IsEffectActive),
                tostring(r.fields and r.fields.fields and r.fields.fields._MaxHealthAdd)))
        end
    end
    if #pending_verify.done >= #pending_verify.frames then
        pending_verify.out.verify = pending_verify.readings
        dump_json(OUT_APPLY, pending_verify.out)
        pending_verify = nil
        lastStatus = "apply clone: verification written -> " .. OUT_APPLY
        log.info("[MealApplyProbe] " .. lastStatus)
    end
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

local function meal_line()
    local meal, src = meal_object()
    if not meal then return "meal: unavailable (" .. tostring(src) .. ")" end
    return string.format("meal: active=%s timer=%s/%s hp=+%s stam=+%s",
        tostring(field_value(meal, "_IsEffectActive")),
        tostring(field_value(meal, "_DurationTimer")),
        tostring(field_value(meal, "_TimerMax")),
        tostring(field_value(meal, "_MaxHealthAdd")),
        tostring(field_value(meal, "_MaxStaminaAdd")))
end

local function draw_ui()
    if not imgui.tree_node("Meal Buffet Probe v" .. PROBE_VERSION) then return end
    imgui.text("discovery probe - every SDK call is guarded")
    imgui.text("quest: " .. (quest_state and "in quest" or "out of quest"))
    imgui.text(meal_line())
    imgui.separator()

    if imgui.button("Dump types") then
        local ok, err = pcall(dump_types)
        if not ok then note_error("dump_types", err) lastStatus = "dump_types error" end
    end
    imgui.same_line()
    if imgui.button("Dump master data") then
        local ok, err = pcall(dump_master)
        if not ok then note_error("dump_master", err) lastStatus = "dump_master error" end
    end

    imgui.separator()
    if imgui.button("Snapshot: " .. SNAPSHOT_TAGS[snapshot_tag_index]) then
        local ok, err = pcall(take_snapshot)
        if not ok then note_error("take_snapshot", err) end
    end
    imgui.same_line()
    if imgui.button("Next tag") then cycle_snapshot_tag() end
    imgui.same_line()
    if imgui.button("Mark: eating now") then
        capture_epoch = capture_epoch + 1
        lastStatus = "epoch " .. tostring(capture_epoch) .. " (capture is now labelled)"
    end
    imgui.text("tag: " .. SNAPSHOT_TAGS[snapshot_tag_index]
        .. "  epoch: " .. capture_epoch)

    imgui.separator()
    if imgui.button(armed and "Hooks armed" or "Arm hooks") then
        local ok, err = pcall(arm_hooks)
        if not ok then note_error("arm_hooks", err) end
    end
    imgui.same_line()
    if imgui.button("Dump capture") then
        local ok, err = pcall(dump_capture)
        if not ok then note_error("dump_capture", err) end
    end
    imgui.same_line()
    if imgui.button("Clear capture") then
        -- Keep the hook inventory: hooks stay armed, only the events go.
        captures.events = {}
        captures.seen = {}
        ret_samples = {}
        evicted = 0
        capture_epoch = capture_epoch + 1
        lastStatus = "capture cleared (hooks stay armed, epoch bumped)"
    end
    imgui.text(string.format("captured: %d hooks, %d signatures, %d evicted",
        #captures.hooks, #captures.events, evicted))

    imgui.separator()
    if imgui.button("Clone meal") then request_action("clone") end
    imgui.same_line()
    if imgui.button("Strip meal") then request_action("strip") end
    imgui.same_line()
    if imgui.button("Apply clone") then request_action("apply") end
    imgui.text(clone and ("clone: " .. clone.wall .. "  fields=" .. #clone.meal_fields
        .. "  skills=" .. tostring(clone.skills.count)) or "clone: none")

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
    imgui.text("1) Dump types  +  Dump master data")
    imgui.text("2) Arm hooks. Snapshot (tag=before). Eat at the canteen,")
    imgui.text("   with a voucher if that is the only way. Snapshot again")
    imgui.text("   (tag=after_eat). Dump capture.")
    imgui.text("3) Clone meal -> Strip meal -> Apply clone on that meal;")
    imgui.text("   check max HP/stamina, attack/defence and food skills.")
    imgui.text("4) Repeat step 3 in a quest (camp canteen) for mid-quest.")
    imgui.text("5) Tell the agent, then send the data/*.json files.")
    imgui.tree_pop()
end

-- ---------------------------------------------------------------------------
-- registration
-- ---------------------------------------------------------------------------

local function register_quest_hooks()
    local ok, err = pcall(function()
        local t = sdk.find_type_definition("app.cQuestPlaying")
        if not t then
            log.warn("[MealApplyProbe] app.cQuestPlaying not found; quest label unavailable")
            return
        end
        local m = t:get_method("update()")
        if m then
            sdk.hook(m, function(args)
                local ok2, err2 = pcall(function()
                    quest_state = sdk.to_managed_object(args[2])
                end)
                if not ok2 then note_error("quest.update hook", err2) end
            end, nil)
        end
        local mx = t:get_method("exit()")
        if mx then
            sdk.hook(mx, function()
                local ok2, err2 = pcall(function() quest_state = nil end)
                if not ok2 then note_error("quest.exit hook", err2) end
            end, nil)
        end
    end)
    if not ok then note_error("register_quest_hooks", err) end
end

if not ALREADY_LOADED then
    re.on_frame(function()
        local ok, err = pcall(on_frame)
        if not ok then note_error("on_frame", err) end
    end)
    re.on_draw_ui(function()
        local ok, err = pcall(draw_ui)
        if not ok then note_error("draw_ui", err) end
    end)
    register_quest_hooks()
    log.info("[MealApplyProbe] loaded v" .. tostring(PROBE_VERSION)
        .. " (discovery; capture hooks only after Arm hooks)")
else
    log.info("[MealApplyProbe] duplicate load ignored (callbacks already registered)")
end
