--
-- meal_apply_probe.lua v1 — discovery probe for the Meal Buffet mod
--
-- Goal: apply any canteen meal to the local hunter on demand, anywhere
-- (hub, camp, training grounds, mid-quest), without a voucher, choosing the
-- base meal and the extra random meal skills.
--
-- Phase 1 answers four questions on this build:
--   1. what the meal/dining/canteen type surface looks like (fields, method
--      signatures) so the apply path can be found,
--   2. what the meal master data contains: the base meals and their fixed
--      skill sets, plus the random meal-skill pool (and its weights),
--   3. which game call actually performs a canteen eat, and with which args
--      (hooks on the dining/meal classes; every distinct call signature is
--      recorded once with a count),
--   4. what a real eat writes: a full meal-state snapshot before/after a
--      normal eat and after a voucher eat (diff of the two JSONs).
--
-- It also carries a self-contained experiment for the write fallback: clone
-- the fields of a real meal, strip it, write the clone back, and re-read at
-- +15 and +120 frames. If the clone comes back (stats and food skills), the
-- mod can apply a meal without the game's eat event.
--
-- Load: <game>\reframework\autorun\meal_apply_probe.lua, then REFramework
--   menu (Insert) -> Script Generated UI -> "Meal Buffet Probe".
--   Reload: REFramework menu -> Script -> Reset scripts.
-- Footprint: hooks are registered only when "Arm hooks" is pressed; the
--   frame callback only runs while a verification is scheduled. Nothing runs
--   at load. Read-only except the explicit clone/strip buttons.
--
-- Lineage: helper shapes (safe wrappers, field descriptor reads, local hunter
--   resolution, hook arg capture) follow this author's meal_probe and
--   kill_probe (MIT ancestry: Hunt Dumper by thieleju); meal master-data paths
--   follow _CatLib (read-only reference, no code copied).
--
-- Every SDK call is pcall-guarded: this script never throws into the game.
--

local re = re
local sdk = sdk
local json = json
local log = log
local imgui = imgui

local PROBE_VERSION = 1

local OUT_TYPES   = "meal_apply_probe_types.json"
local OUT_MASTER  = "meal_apply_probe_master.json"
local OUT_STATE   = "meal_apply_probe_state.json"
local OUT_CAPTURE = "meal_apply_probe_capture.json"
local OUT_APPLY   = "meal_apply_probe_apply.json"

-- Re-running the script must not register a second set of callbacks/hooks.
local ALREADY_LOADED = _G.MEAL_APPLY_PROBE_LOADED == true
_G.MEAL_APPLY_PROBE_LOADED = true

local MAX_HOOKS = 80
local MAX_SIGNATURES = 300
local MAX_MASTER_ENTRIES = 40
local VERIFY_FRAMES = { 15, 120 }

local lastStatus = "(idle)"
local armed = false
local pending_verify = nil

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

local function type_name(obj)
    if obj == nil then return nil end
    local td = safe(function() return obj:get_type_definition() end)
    return td and safe(function() return td:get_full_name() end) or nil
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

local function typecall(typeName, methodName, obj, ...)
    local td = safe(sdk.find_type_definition, typeName)
    if not td then return nil end
    local m = safe(function() return td:get_method(methodName .. "()") end)
        or safe(function() return td:get_method(methodName) end)
    if not m then return nil end
    return safe(function() return m:call(obj, ...) end)
end

-- Read an instance field through its descriptor: obj:get_field() returns nil
-- for several Hunter/Wilds structs, get_data(obj) does not.
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

-- Lists and dictionary value views share get_Count/get_Item on this build.
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
    if get_item then return safe(function() return get_item:call(c, i) end) end
    return array_get(c, i)
end

-- _Values is the values view of a via.Dictionary (proven by _CatLib).
local function dict_values(dict)
    if dict == nil then return nil end
    return field_value(dict, "_Values") or dict
end

local function is_managed(obj)
    if obj == nil then return false end
    if sdk.is_managed_object == nil then return true end
    return safe(sdk.is_managed_object, obj) == true
end

-- ---------------------------------------------------------------------------
-- local hunter resolution (same rule as buff_stripper: never getMasterPlayer)
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
    if not meal then return nil, "no_meal_object" end
    return meal, src, st
end

-- ---------------------------------------------------------------------------
-- generic value dumping
-- ---------------------------------------------------------------------------

local PRIMITIVE = {
    Boolean = true, Single = true, Double = true, Int32 = true, UInt32 = true,
    Int16 = true, UInt16 = true, Byte = true, SByte = true, Int64 = true,
    UInt64 = true, String = true,
}

-- Primitive fields + primitive 0-arg getters. No object getter is called, so
-- nothing extra is allocated by the dump itself.
local function value_summary(obj, maxGetters)
    local out = { type = type_name(obj) }
    if obj == nil then return out end
    local td = safe(function() return obj:get_type_definition() end)
    if not td then return out end

    local data, getters, objectFields = {}, {}, {}
    for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
        local fname = safe(function() return f:get_name() end)
        local ftype = safe_str(safe(function() return f:get_type():get_name() end))
        if fname then
            if PRIMITIVE[ftype] then
                data[fname] = safe_str(safe(function()
                    local is_static = safe(function() return f:is_static() end)
                    return f:get_data(is_static and nil or obj)
                end))
            elseif not fname:find("^<") then
                objectFields[#objectFields + 1] = fname .. ":" .. tostring(ftype)
            end
        end
    end

    local n = 0
    for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
        if maxGetters and n >= maxGetters then break end
        local mname = safe(function() return m:get_name() end) or ""
        local nparams = safe(function() return m:get_num_params() end) or 0
        local ret = safe_str(safe(function() return m:get_return_type():get_name() end))
        if mname:find("^get_") and nparams == 0 and ret and PRIMITIVE[ret] then
            local v = safe(function() return m:call(obj) end)
            if v ~= nil then
                getters[mname] = safe_str(v)
                n = n + 1
            end
        end
    end

    out.fields = data
    out.getters = getters
    if #objectFields > 0 then out.object_fields = objectFields end
    return out
end

local function describe_method(m)
    local params, full_params = {}, {}
    local n = safe(function() return m:get_num_params() end) or 0
    local pts = safe(function() return m:get_param_types() end) or {}
    for i = 1, n do
        local t = pts[i]
        local tn = safe_str(safe(function() return t:get_name() end)) or "?"
        params[#params + 1] = tn
        full_params[#full_params + 1] = tn
    end
    return {
        name = safe(function() return m:get_name() end),
        full = safe(function() return m:get_full_name() end),
        ret = safe_str(safe(function() return m:get_return_type():get_name() end)),
        params = params,
        signature = (safe(function() return m:get_name() end) or "?")
            .. "(" .. table.concat(full_params, ", ") .. ")",
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
                static = safe(function() return f:is_static() end),
            }
        end
    end

    local methods = safe(function() return td:get_methods() end)
    if methods then
        entry.methods = {}
        for _, m in ipairs(methods) do
            entry.methods[#entry.methods + 1] = describe_method(m)
        end
    end
    return entry
end

-- ---------------------------------------------------------------------------
-- type surface (phase 1, question 1)
-- ---------------------------------------------------------------------------

local TYPES = {
    -- meal state on the hunter
    "app.cHunterStatus", "app.cHunterMealEffect", "app.cMealEffect",
    "app.cHunterMealSkillParamInfo", "app.cHunterMealSkillParamInfo.cInfo",
    "app.cHunterItemBuff", "app.cHunterAttackPower", "app.cHunterDefencePower",
    "app.cHunterCritical", "app.cHunterHealth", "app.cHunterStamina",
    -- definitions / master data
    "app.MealDef", "app.MealDef.SKILL",
    "app.user_data.MealSkillData", "app.user_data.MealSkillData.cData",
    "app.user_data.MealSkillRandomTable", "app.user_data.MealSkillRandomTable.cData",
    "app.user_data.FacilityDiningSetting", "app.user_data.FacilityDiningSetting.cData",
    "app.user_data.FacilitySetting", "app.user_data.FacilitySetting.cData",
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
            if name and v ~= nil then out.values[#out.values + 1] = { name = name, value = safe_str(v) } end
        end
    end
    return out
end

local function dump_types()
    local out = { probe_version = PROBE_VERSION, kinds = {}, enums = {},
        wall = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    local hits = {}
    for _, name in ipairs(TYPES) do
        local e = dump_type(name)
        out.kinds[#out.kinds + 1] = e
        if e.exists then hits[#hits + 1] = name end
    end
    for _, name in ipairs(ENUMS) do
        out.enums[#out.enums + 1] = dump_enum(name)
    end
    json.dump_file(OUT_TYPES, out)
    lastStatus = string.format("types: %d/%d exist -> %s", #hits, #TYPES, OUT_TYPES)
    log.info("[MealApplyProbe] " .. lastStatus)
    log.info("[MealApplyProbe] existing: " .. table.concat(hits, ", "))
    return out
end

-- ---------------------------------------------------------------------------
-- master data (phase 1, question 2)
-- ---------------------------------------------------------------------------

local function various_manager()
    return safe(function() return sdk.get_managed_singleton("app.VariousDataManager") end)
end

-- various -> _Setting -> _FacilitySetting -> _FacilityDiningSetting
local function dining_setting()
    local vm = various_manager()
    if not vm then return nil, "no_various_manager" end
    local setting = field_value(vm, "_Setting")
    if not setting then return nil, "no_setting" end
    local facility = field_value(setting, "_FacilitySetting")
    if not facility then return nil, "no_facility_setting" end
    local dining = field_value(facility, "_FacilityDiningSetting")
    if not dining then return nil, "no_facility_dining_setting" end
    return dining, "ok", { various = vm, setting = setting, facility = facility }
end

local get_meal_skill_name_m = nil
local get_message_m = nil

local function meal_skill_name(id)
    if id == nil or id == 0 then return nil end
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
    if get_meal_skill_name_m == false or get_message_m == false then return nil end
    local guid = safe(function() return get_meal_skill_name_m:call(nil, id) end)
    if guid == nil then return nil end
    return safe(function() return get_message_m:call(nil, guid) end)
end

local function dump_table(obj, fieldName, maxEntries)
    local rec = { field = fieldName }
    local v = field_value(obj, fieldName)
    if v == nil then
        rec.miss = true
        return rec
    end
    local vt = type(v)
    if vt == "number" or vt == "boolean" or vt == "string" then
        rec.value = v
        rec.primitive = true
        return rec
    end
    rec.type = type_name(v)
    local values = dict_values(v)
    local n = collection_count(values)
    rec.count = n
    if not n then
        rec.note = "not a collection (object)"
        rec.summary = value_summary(v, 20)
        return rec
    end
    rec.entries = {}
    local limit = math.min(n, maxEntries or MAX_MASTER_ENTRIES)
    for i = 0, limit - 1 do
        local item = collection_get(values, i)
        if item == nil then break end
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

local function dump_master()
    local out = { probe_version = PROBE_VERSION, wall = os.date("!%Y-%m-%dT%H:%M:%SZ"), tables = {} }
    local dining, src, chain = dining_setting()
    if not dining then
        out.fail = src
        json.dump_file(OUT_MASTER, out)
        lastStatus = "master: " .. tostring(src)
        log.warn("[MealApplyProbe] " .. lastStatus)
        return out
    end

    out.chain = {
        various = type_name(chain.various),
        setting = type_name(chain.setting),
        facility = type_name(chain.facility),
        dining = type_name(dining),
    }

    local td = safe(function() return dining:get_type_definition() end)
    for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
        local fname = safe(function() return f:get_name() end)
        if fname then
            out.tables[#out.tables + 1] = dump_table(dining, fname, MAX_MASTER_ENTRIES)
        end
    end

    -- Explicitly dump the two tables the mod needs even if the loop above
    -- missed them (kept separate so a rename is visible in the JSON).
    local meal_skills = dump_table(dining, "_MealSkill", MAX_MASTER_ENTRIES)
    local random_skills = dump_table(dining, "_MealSkillRandomTable", MAX_MASTER_ENTRIES)
    out.meal_skill_table = meal_skills
    out.random_table = random_skills

    json.dump_file(OUT_MASTER, out)
    lastStatus = string.format("master: %d tables, meal skills=%s, random=%s -> %s",
        #out.tables,
        tostring(meal_skills.count),
        tostring(random_skills.count),
        OUT_MASTER)
    log.info("[MealApplyProbe] " .. lastStatus)
    return out
end

-- ---------------------------------------------------------------------------
-- quest state (for labelling mid-quest vs out-of-quest runs)
--
-- cQuestPlaying is not reachable as a singleton; its instance is captured
-- from update() and dropped on exit() (proven by meal_probe).
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
-- meal state snapshots (phase 1, question 4)
-- ---------------------------------------------------------------------------

local function skill_list_summary(paramInfo)
    local out = {}
    if paramInfo == nil then return out end
    out.param_info = value_summary(paramInfo, 30)
    local list = field_value(paramInfo, "_InfoList")
    out.info_list_type = type_name(list)
    local n = collection_count(list)
    out.count = n
    if not n then return out end
    out.entries = {}
    for i = 0, n - 1 do
        local item = collection_get(list, i)
        if item == nil then break end
        local e = value_summary(item, 20)
        e.index = i
        out.entries[#out.entries + 1] = e
    end
    return out
end

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

local function meal_state(label)
    local out = { label = label, wall = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    local meal, src, st = meal_object()
    out.src = src
    if not meal then
        out.fail = src
        if st then out.stats = stats_snapshot(st) end
        return out
    end
    out.meal_type = type_name(meal)
    out.fields = value_summary(meal, 60)

    local inner = field_value(meal, "_MealEffect")
    out.inner = value_summary(inner, 60)
    out.skills = skill_list_summary(field_value(meal, "_SkillParamInfo"))
    out.stats = stats_snapshot(st)
    out.quest = quest_state_report()
    return out
end

-- ---------------------------------------------------------------------------
-- call capture (phase 1, question 3)
-- ---------------------------------------------------------------------------

local HOOK_TYPES = {
    "app.FacilityManager", "app.cFacilityManager",
    "app.FacilityDiningManager", "app.cFacilityDiningManager",
    "app.FacilityDining", "app.cFacilityDining",
    "app.DiningManager", "app.cDiningManager",
    "app.MealManager", "app.cMealManager", "app.MealUtil", "app.cMealUtil",
    "app.CampManager", "app.cCampManager", "app.CampUtil",
    "app.GuiDining", "app.cGuiDining", "app.GuiMeal", "app.cGuiMeal",
    "app.GuiRestaurant", "app.cGuiRestaurant",
    "app.cHunterMealEffect", "app.cMealEffect", "app.cHunterMealSkillParamInfo",
}

-- Method names worth hooking. Getters, per-frame and teardown methods are
-- skipped so the capture stays readable.
local HOOK_PATTERN = "apply|eat|order|cook|dining|meal|serve|consume|voucher|decide|select"
local HOOK_SKIP = {
    "^get_", "^is_", "^update", "^lateUpdate", "^draw", "^calc", "^onFrame",
    "^initialize", "^finalize", "^%.ctor", "^%.dtor", "^create", "^reset",
    "^clear",
}

local captures = { hooks = {}, events = {}, seen = {} }

local function name_is_hookable(name)
    if name == nil then return false end
    local lower = name:lower()
    for _, pat in ipairs(HOOK_SKIP) do
        if lower:find(pat) then return false end
    end
    if lower:find("^set_") and not lower:find("meal") and not lower:find("voucher")
        and not lower:find("dining") then
        return false
    end
    return lower:find(HOOK_PATTERN) ~= nil
end

-- Convert one raw hook argument to something readable. Declared parameter
-- types are recorded too, so an ambiguous value can be resolved afterwards.
local function arg_str(v, declared)
    local t = declared or ""
    if t == "Boolean" then
        local b = safe(sdk.to_bool, v)
        if b ~= nil then return "bool:" .. tostring(b) end
    elseif t == "Single" or t == "Double" then
        local f = safe(sdk.to_float, v)
        if f == nil then f = safe(sdk.to_double, v) end
        if f ~= nil then return string.format("float:%.5f", f) end
    elseif t:find("Int", 1, true) or t:find("UInt", 1, true)
        or t:find("Byte", 1, true) or t:find("SByte", 1, true)
        or t:find("Def.", 1, true) then
        -- app.*Def.* enums are passed as plain integers on this build
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

local function record_signature(full, ret, params, argstrings)
    local key = full .. "|" .. table.concat(argstrings, ",")
    local hit = captures.seen[key]
    if hit then
        hit.count = hit.count + 1
        return
    end
    local rec = {
        method = full,
        ret = ret,
        params = params,
        args = argstrings,
        count = 1,
        wall = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
    captures.seen[key] = rec
    captures.events[#captures.events + 1] = rec
    if #captures.events > MAX_SIGNATURES then
        local drop = table.remove(captures.events, 1)
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
    local registered, skipped = 0, 0
    for _, typeName in ipairs(HOOK_TYPES) do
        if registered >= MAX_HOOKS then break end
        local td = safe(sdk.find_type_definition, typeName)
        if td then
            for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
                if registered >= MAX_HOOKS then break end
                local mname = safe(function() return m:get_name() end)
                if name_is_hookable(mname) then
                    local desc = describe_method(m)
                    local full = desc.full or (typeName .. "." .. tostring(mname))
                    local ok = safe(function()
                        sdk.hook(m, function(args)
                            if not armed then return end
                            safe(function()
                                local this = safe(sdk.to_managed_object, args[2])
                                local this_type = (this and is_managed(this)) and type_name(this) or nil
                                local argstrings = {}
                                for i, ptype in ipairs(desc.params) do
                                    local raw = args[i + 2]
                                    argstrings[#argstrings + 1] = arg_str(raw, ptype)
                                end
                                if this_type then
                                    table.insert(argstrings, 1, "this:" .. this_type)
                                end
                                record_signature(full, desc.ret, desc.params, argstrings)
                            end)
                        end, nil)
                        return true
                    end)
                    if ok then
                        registered = registered + 1
                        captures.hooks[#captures.hooks + 1] = {
                            method = full,
                            params = desc.params,
                            ret = desc.ret,
                        }
                    else
                        skipped = skipped + 1
                    end
                end
            end
        end
    end
    armed = true
    lastStatus = string.format("hooks armed: %d registered, %d failed (max %d)",
        registered, skipped, MAX_HOOKS)
    log.info("[MealApplyProbe] " .. lastStatus)
end

local function dump_capture()
    local out = {
        probe_version = PROBE_VERSION,
        wall = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        armed = armed,
        hooks = captures.hooks,
        events = captures.events,
        quest = quest_state_report(),
    }
    json.dump_file(OUT_CAPTURE, out)
    lastStatus = string.format("capture: %d hooks, %d distinct signatures -> %s",
        #captures.hooks, #captures.events, OUT_CAPTURE)
    log.info("[MealApplyProbe] " .. lastStatus)
    return out
end

-- ---------------------------------------------------------------------------
-- clone / strip experiment (write fallback, phase 1 bonus question)
--
-- Clone keeps the live objects (Lua reference + add_ref) so the meal effect
-- block, and its skill list, cannot be collected while the test runs.
-- ---------------------------------------------------------------------------

local MEAL_TYPE = "app.cHunterMealEffect"

local STRIP_FIELDS = {
    { name = "_IsTimerActive",     value = false },
    { name = "_IsEffectActive",    value = false },
    { name = "_DurationTimer",     value = 0.0 },
    { name = "_MaxHealthAdd",      value = 0.0 },
    { name = "_MaxStaminaAdd",     value = 0.0 },
    { name = "_TempIsTimerActive", value = false },
    { name = "_TempIsEffectActive", value = false },
}

local clone = nil

local function clone_fields(obj)
    local out = {}
    if obj == nil then return out end
    local td = safe(function() return obj:get_type_definition() end)
    for _, f in ipairs(safe(function() return td and td:get_fields() end) or {}) do
        local fname = safe(function() return f:get_name() end)
        local ftype = safe_str(safe(function() return f:get_type():get_name() end))
        local is_static = safe(function() return f:is_static() end)
        if fname and not is_static and PRIMITIVE[ftype] then
            out[#out + 1] = { name = fname, value = safe(function() return f:get_data(obj) end) }
        end
    end
    return out
end

local function clone_meal()
    local meal, src = meal_object()
    if not meal then
        lastStatus = "clone: " .. tostring(src)
        log.warn("[MealApplyProbe] " .. lastStatus)
        return nil
    end
    local inner = field_value(meal, "_MealEffect")
    local param_info = field_value(meal, "_SkillParamInfo")
    safe(function() meal:add_ref() end)
    if inner then safe(function() inner:add_ref() end) end
    if param_info then safe(function() param_info:add_ref() end) end

    clone = {
        meal = meal,
        inner = inner,
        param_info = param_info,
        meal_fields = clone_fields(meal),
        inner_fields = clone_fields(inner),
        param_fields = clone_fields(param_info),
        wall = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        src = src,
        snapshot = meal_state("clone"),
    }
    lastStatus = string.format("clone: saved %d meal fields, %d inner fields, %d param fields @ %s",
        #clone.meal_fields, #clone.inner_fields, #clone.param_fields, clone.wall)
    log.info("[MealApplyProbe] " .. lastStatus)
    return clone
end

local function write_fields(obj, typeName, fields)
    local n, missing = 0, {}
    for _, rec in ipairs(fields or {}) do
        local current = field_value(obj, rec.name)
        if current == nil then
            missing[#missing + 1] = rec.name
        else
            local ok = write_field(obj, typeName, rec.name, rec.value)
            if ok then n = n + 1 end
        end
    end
    return n, missing
end

local function strip_meal()
    local meal, src = meal_object()
    if not meal then
        lastStatus = "strip: " .. tostring(src)
        log.warn("[MealApplyProbe] " .. lastStatus)
        return
    end
    local n, missing = 0, {}
    for _, sf in ipairs(STRIP_FIELDS) do
        if field_value(meal, sf.name) == nil then
            missing[#missing + 1] = sf.name
        else
            local ok = write_field(meal, MEAL_TYPE, sf.name, sf.value)
            if ok then n = n + 1 end
        end
    end
    lastStatus = string.format("strip: %d/%d fields written%s",
        n, #STRIP_FIELDS, #missing > 0 and (" missing: " .. table.concat(missing, ", ")) or "")
    log.info("[MealApplyProbe] " .. lastStatus)
end

local function apply_clone()
    if clone == nil then
        lastStatus = "apply clone: nothing cloned yet"
        log.warn("[MealApplyProbe] " .. lastStatus)
        return
    end
    local meal, src = meal_object()
    if not meal then
        lastStatus = "apply clone: " .. tostring(src)
        log.warn("[MealApplyProbe] " .. lastStatus)
        return
    end
    local out = {
        probe_version = PROBE_VERSION,
        wall = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        clone_wall = clone.wall,
        src = src,
        before = meal_state("before_apply"),
        writes = {},
    }

    local n1, miss1 = write_fields(meal, MEAL_TYPE, clone.meal_fields)
    local n2, miss2 = 0, {}
    if is_managed(clone.inner) then
        n2, miss2 = write_fields(clone.inner, "app.cMealEffect", clone.inner_fields)
        write_field(meal, MEAL_TYPE, "_MealEffect", clone.inner)
    end
    local n3 = 0
    if is_managed(clone.param_info) then
        local ok = write_field(meal, MEAL_TYPE, "_SkillParamInfo", clone.param_info)
        if ok then n3 = 1 end
    end

    out.writes = {
        meal_fields = n1,
        meal_missing = miss1,
        inner_fields = n2,
        inner_missing = miss2,
        param_info_written = n3,
        inner_live = is_managed(clone.inner),
        param_info_live = is_managed(clone.param_info),
    }
    out.after_immediate = meal_state("after_apply")
    json.dump_file(OUT_APPLY, out)

    pending_verify = { frames = VERIFY_FRAMES, done = {}, readings = {} }
    lastStatus = string.format("apply clone: %d+%d fields, param=%s, verifying +15/+120",
        n1, n2, tostring(n3 == 1))
    log.info("[MealApplyProbe] " .. lastStatus)
    return out
end

-- ---------------------------------------------------------------------------
-- frame callback: only alive while a verification is scheduled
-- ---------------------------------------------------------------------------

local function on_frame()
    if pending_verify == nil then return end
    pending_verify.count = (pending_verify.count or 0) + 1
    for i, target in ipairs(pending_verify.frames) do
        if not pending_verify.done[i] and pending_verify.count >= target then
            pending_verify.done[i] = true
            local r = meal_state("after_" .. target .. "f")
            pending_verify.readings[#pending_verify.readings + 1] = r
            log.info(string.format("[MealApplyProbe] verify +%df: %s",
                target,
                tostring(r.fields and r.fields.fields and r.fields.fields._DurationTimer)))
        end
    end
    if #pending_verify.done >= #pending_verify.frames then
        local out = json.load_file(OUT_APPLY) or {}
        out.verify = pending_verify.readings
        json.dump_file(OUT_APPLY, out)
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
    return string.format("meal: active=%s timer=%s/=%s hp=+%s stam=+%s",
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
        if not ok then lastStatus = "dump_types error: " .. tostring(err) end
    end
    imgui.same_line()
    if imgui.button("Dump master data") then
        local ok, err = pcall(dump_master)
        if not ok then lastStatus = "dump_master error: " .. tostring(err) end
    end

    if imgui.button("Snapshot state") then
        local ok, err = pcall(function()
            local snap = meal_state("manual")
            json.dump_file(OUT_STATE, snap)
            lastStatus = "state -> " .. OUT_STATE
        end)
        if not ok then lastStatus = "snapshot error: " .. tostring(err) end
    end
    imgui.same_line()
    if imgui.button("Dump capture") then
        local ok, err = pcall(dump_capture)
        if not ok then lastStatus = "dump_capture error: " .. tostring(err) end
    end

    imgui.separator()
    if imgui.button(armed and "Hooks armed (capture on)" or "Arm hooks") then
        local ok, err = pcall(arm_hooks)
        if not ok then lastStatus = "arm_hooks error: " .. tostring(err) end
    end
    imgui.same_line()
    if imgui.button("Clear capture") then
        captures = { hooks = {}, events = {}, seen = {} }
        lastStatus = "capture cleared"
    end
    imgui.text(string.format("captured: %d hooks, %d signatures",
        #captures.hooks, #captures.events))

    imgui.separator()
    if imgui.button("Clone meal") then
        local ok, err = pcall(clone_meal)
        if not ok then lastStatus = "clone error: " .. tostring(err) end
    end
    imgui.same_line()
    if imgui.button("Strip meal") then
        local ok, err = pcall(strip_meal)
        if not ok then lastStatus = "strip error: " .. tostring(err) end
    end
    imgui.same_line()
    if imgui.button("Apply clone") then
        local ok, err = pcall(apply_clone)
        if not ok then lastStatus = "apply clone error: " .. tostring(err) end
    end
    imgui.text(clone and ("clone: " .. clone.wall .. "  fields=" .. #clone.meal_fields)
        or "clone: none")

    imgui.separator()
    imgui.text("status: " .. tostring(lastStatus))
    if pending_verify then
        imgui.text(string.format("verifying: frame %d / %d",
            pending_verify.count or 0, pending_verify.frames[#pending_verify.frames]))
    end
    imgui.separator()
    imgui.text("1) Dump types + Dump master data")
    imgui.text("2) Arm hooks, eat a meal, Snapshot state, Dump capture")
    imgui.text("3) Strip meal, eat a voucher meal, Snapshot state, Dump capture")
    imgui.text("4) Clone meal, Strip, Apply clone, check stats + food skills")
    imgui.tree_pop()
end

-- ---------------------------------------------------------------------------
-- registration
-- ---------------------------------------------------------------------------

local function register_quest_hooks()
    safe(function()
        local t = sdk.find_type_definition("app.cQuestPlaying")
        if not t then
            log.warn("[MealApplyProbe] app.cQuestPlaying not found; quest label unavailable")
            return
        end
        local m = t:get_method("update()")
        if m then
            sdk.hook(m, function(args)
                quest_state = sdk.to_managed_object(args[2])
            end, nil)
        end
        local mx = t:get_method("exit()")
        if mx then
            sdk.hook(mx, function() quest_state = nil end, nil)
        end
    end)
end

if not ALREADY_LOADED then
    re.on_frame(function()
        local ok, err = pcall(on_frame)
        if not ok then log.warn("[MealApplyProbe] on_frame: " .. tostring(err)) end
    end)
    re.on_draw_ui(function()
        local ok, err = pcall(draw_ui)
        if not ok then log.warn("[MealApplyProbe] draw_ui: " .. tostring(err)) end
    end)
    register_quest_hooks()
    log.info("[MealApplyProbe] loaded v" .. tostring(PROBE_VERSION)
        .. " (discovery only; hooks register when armed)")
else
    log.info("[MealApplyProbe] duplicate load ignored (callbacks already registered)")
end
