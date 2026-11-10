--
-- meal_buffet.lua v0.1.0 — apply any canteen meal to your hunter on demand
--
-- What it does:
--   * lists the canteen's meal sets (read from the game's own master data:
--     app.user_data.MealDataLobby), with each set's fixed food skills shown by
--     name;
--   * lets you take the two random extra buffs either as the game rolls them,
--     as a specific buff you pick, or not at all;
--   * applies the result to your own hunter with the game's own objects:
--       effect = app.cMealEffect (new instance)
--       effect:copyFrom(app.user_data.MealDataLobby.cData, false)
--       effect:addRandomTableParam(tableId)  or  effect:addRandomData(cData)
--       hunterMeal:setMealEffect(effect, false)
--       then the timer/flags a real eat leaves behind
--         _DurationTimer = _TimerMax = minutes * 60, both active flags true
--   * shows the meal that is currently on the hunter, with its skill names.
--
-- Proven on the current build by reframework/meal_apply_probe2.lua: the
-- applied meal lists the same food skills in game as a real canteen meal.
-- No voucher and no ingredients are consumed; nothing is eaten, the state is
-- applied directly, so it works in the hub, at camp, and during a quest.
--
-- Load: <game>\reframework\autorun\meal_buffet.lua, then REFramework menu
--   (Insert) -> Script Generated UI -> "Meal Buffet".
-- Footprint: no hooks, no per-frame work. Every SDK call is pcall-guarded.
-- Writes happen only on "Apply meal" / "Clear meal", and only on the
-- user-controlled hunter.
--

local re = re
local sdk = sdk
local json = json
local log = log
local imgui = imgui
local unpack = unpack or table.unpack

local VERSION = "0.1.1"
local CONFIG_FILE = "meal_buffet.json"

local ALREADY_LOADED = _G.MEAL_BUFFET_LOADED == true
_G.MEAL_BUFFET_LOADED = true

-- The four village meals are the first four canteen menus; the rest are
-- special/event sets. Labels only: every value (skills, timers, stats) always
-- comes from the game's master data.
local MENU_LABELS = {
    MENU_00 = "Kunafa",
    MENU_01 = "Azuz",
    MENU_02 = "Slid",
    MENU_03 = "Suja",
}

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

local lastStatus = "(idle)"
local pending_action = nil
local verify_frames = 0
local verify_pending = nil

-- ---------------------------------------------------------------------------
-- helpers (same shapes the probes prove on this build)
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

local function write_field(obj, typeName, name, value)
    if obj == nil then return false, "no_object" end
    local ok = safe(function() obj:set_field(name, value) return true end)
    if ok then return true, "set_field" end
    local td = safe(sdk.find_type_definition, typeName)
    if not td then return false, "no_type" end
    local ok2 = safe(function()
        sdk.set_native_field(obj, td, name, value)
        return true
    end)
    return ok2 == true, ok2 and "set_native_field" or "write_failed"
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

local function enum_names(enumName)
    local td = safe(sdk.find_type_definition, enumName)
    local out = {}
    if not td then return out end
    for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
        if safe(function() return f:is_static() end) then
            local name = safe(function() return f:get_name() end)
            local v = safe(function() return f:get_data(nil) end)
            if name and v ~= nil then out[tostring(v)] = name end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- text
-- ---------------------------------------------------------------------------

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

local skill_name_cache = {}

local function localized(guid)
    resolve_text_helpers()
    if guid == nil or get_message_m == false then return nil end
    return safe(function() return get_message_m:call(nil, guid) end)
end

-- One line, at most `max` characters: descriptions come from the game's
-- message table and can be long.
local function short(text, max)
    if text == nil then return nil end
    local t = tostring(text):gsub("%s+", " ")
    max = max or 110
    if #t > max then t = t:sub(1, max - 3) .. "..." end
    return t
end

local function meal_skill_name(id)
    local key = tostring(id)
    if skill_name_cache[key] ~= nil then return skill_name_cache[key] end
    resolve_text_helpers()
    local out = nil
    if id ~= nil and get_meal_skill_name_m ~= false and get_message_m ~= false then
        local guid = safe(function() return get_meal_skill_name_m:call(nil, id) end)
        if guid ~= nil then
            out = safe(function() return get_message_m:call(nil, guid) end)
        end
    end
    skill_name_cache[key] = out
    return out
end

-- ---------------------------------------------------------------------------
-- local hunter
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
            if st and call_method(st, "get_IsUserControl") == true
                and call_method(st, "get_IsNpc") ~= true then
                return st, "user_control"
            end
        end
    end
    return nil, "no_user_controlled_status"
end

local function meal_object()
    local st, src = local_status()
    if not st then return nil, src end
    local meal = field_value(st, "_MealEffect")
    if meal == nil then return nil, "no_meal_object" end
    if not tostring(src):find("^user_control") then return nil, "not_user_control" end
    return meal, src, st
end

-- ---------------------------------------------------------------------------
-- master data
-- ---------------------------------------------------------------------------

local data = {
    ready = false,
    meals = {},          -- ordered by canteen menu: label, fixed skills, tables
    random_pool = {},    -- all random buffs: table, skill, name, weight
    pool_by_table = {},  -- table id -> { pool entries }
    by_menu = {},        -- menu enum name -> meal
}

local function read_table(ud, max)
    local vals = table_values(ud)
    local n = collection_count(vals)
    local out = { entries = {} }
    if not n then return out end
    local base = 0
    if n > 0 and collection_get(vals, 0) == nil then base = 1 end
    local limit = n
    if max and limit > max then limit = max end
    for i = 0, limit - 1 do
        local v = collection_get(vals, base + i)
        if v == nil then break end
        out.entries[#out.entries + 1] = v
    end
    return out
end

local function load_data()
    local vm = safe(function() return sdk.get_managed_singleton("app.VariousDataManager") end)
    if not vm then return false, "no_various_manager" end
    local setting = field_value(vm, "_Setting")
    local facility = setting and field_value(setting, "_FacilitySetting")
    local dining = facility and field_value(facility, "_FacilityDiningSetting")
    if not dining then return false, "no_dining_setting" end

    -- random buff pool
    local pool = read_table(field_value(dining, "_MealSkillRandomTable"), 400)
    data.random_pool, data.pool_by_table = {}, {}
    for i, cd in ipairs(pool.entries) do
        local id = call_method(cd, "get_MealSkill")
        local tbl = safe_str(call_method(cd, "get_RandomTable"))
        local rec = {
            index = i - 1,
            table = tbl,
            skill = safe_str(id),
            name = meal_skill_name(tonumber(safe_str(id) or 0) or 0) or ("skill " .. tostring(safe_str(id))),
            weight = safe_str(field_value(cd, "_RandomValue")),
            cdata = cd,
        }
        data.random_pool[#data.random_pool + 1] = rec
        local key = tostring(tbl)
        data.pool_by_table[key] = data.pool_by_table[key] or {}
        table.insert(data.pool_by_table[key], rec)
    end

    -- meal skill table: id -> name + description (the mod shows the text of
    -- the extra buffs, which keeps the picker readable)
    local skill_table = read_table(field_value(dining, "_MealSkill"), 200)
    data.skill_info = {}
    for _, cd in ipairs(skill_table.entries) do
        local id = call_method(cd, "get_MealSkill")
        local key = tostring(safe_str(id))
        if id ~= nil then
            local guid = call_method(cd, "get_Explain")
            data.skill_info[key] = {
                id = tonumber(safe_str(id)),
                name = meal_skill_name(tonumber(safe_str(id)) or 0),
                desc = guid and localized(guid) or nil,
            }
        end
    end

    -- canteen menu enum -> meal record
    local menu_names = enum_names("app.DiningDef.LOBBY_MENU_ID")
    data.meals, data.by_menu = {}, {}
    for menuValue = 0, 12 do
        local enumName = menu_names[tostring(menuValue)]
        local cd = static_value("app.MealUtil", "getMealDataLobby(app.DiningDef.LOBBY_MENU_ID)", menuValue)
        if cd ~= nil then
            local skills = array_values(call_method(cd, "get_MealSkill"), 8)
            local tables = array_values(call_method(cd, "get_RandomTable"), 4)
            local meal = {
                menu_value = menuValue,
                menu_enum = enumName or ("MENU_" .. tostring(menuValue)),
                label = MENU_LABELS[enumName or ""] or ("Special " .. tostring(menuValue)),
                fixed_skills = skills,
                fixed_names = {},
                random_tables = tables,
                minutes = tonumber(safe_str(field_value(cd, "_EffectiveMinutes"))) or 70,
                health = safe_str(field_value(cd, "_Health")),
                stamina = safe_str(field_value(cd, "_Stamina")),
                attack = safe_str(field_value(cd, "_Attack")),
                defence = safe_str(field_value(cd, "_Defence")),
                cdata = cd,
            }
            for k, id in ipairs(skills) do
                local n = meal_skill_name(tonumber(id) or 0)
                if n and n ~= "-" then meal.fixed_names[#meal.fixed_names + 1] = n end
            end
            data.meals[#data.meals + 1] = meal
            data.by_menu[tostring(menuValue)] = meal
        end
    end

    if #data.meals == 0 then return false, "no_meal_records" end
    data.ready = true
    return true, "ok"
end

-- ---------------------------------------------------------------------------
-- selection + config
-- ---------------------------------------------------------------------------

local sel_meal = 1
local slots = {}          -- per slot: -1 = game roll, 0 = none, n = pool index
local randoms_enabled = true
local descriptions_on = true

local function selected_meal()
    if #data.meals == 0 then return nil end
    if sel_meal > #data.meals then sel_meal = 1 end
    return data.meals[sel_meal]
end

-- Buffs available to this meal: the union of the pools its random tables name.
local function meal_pool(meal)
    local out, seen = {}, {}
    for _, tbl in ipairs(meal.random_tables or {}) do
        for _, rec in ipairs(data.pool_by_table[tostring(tbl)] or {}) do
            if not seen[rec.index] then
                seen[rec.index] = true
                out[#out + 1] = rec
            end
        end
    end
    return out
end

local function floored_slots()
    while #slots < 4 do slots[#slots + 1] = -1 end
    return slots
end

local function load_config()
    local cfg = safe(function() return json.load_file(CONFIG_FILE) end)
    if type(cfg) ~= "table" then return end
    if type(cfg.meal) == "number" then sel_meal = math.max(1, math.floor(cfg.meal)) end
    if type(cfg.slots) == "table" then
        slots = {}
        for i = 1, 4 do
            local v = cfg.slots[i]
            slots[i] = type(v) == "number" and v or -1
        end
    end
    if type(cfg.randoms_enabled) == "boolean" then randoms_enabled = cfg.randoms_enabled end
    if type(cfg.descriptions) == "boolean" then descriptions_on = cfg.descriptions end
end

local function save_config()
    safe(function()
        json.dump_file(CONFIG_FILE, {
            meal = sel_meal,
            slots = { slots[1] or -1, slots[2] or -1, slots[3] or -1, slots[4] or -1 },
            randoms_enabled = randoms_enabled,
            descriptions = descriptions_on,
        })
    end)
end

-- ---------------------------------------------------------------------------
-- current meal readout
-- ---------------------------------------------------------------------------

local function skill_description(id)
    if id == nil or data.skill_info == nil then return nil end
    local rec = data.skill_info[tostring(id)]
    return rec and rec.desc or nil
end

local function current_skills()
    local meal = meal_object()
    if not meal then return {} end
    local effect = field_value(meal, "_MealEffect")
    if not effect then return {} end
    local out = {}
    for _, id in ipairs(array_values(field_value(effect, "_SkillEnum"), 8)) do
        local num = tonumber(id)
        if num and num ~= 0 then
            out[#out + 1] = {
                id = num,
                name = meal_skill_name(num) or ("skill " .. tostring(num)),
            }
        end
    end
    return out
end

local function current_line()
    local meal, src = meal_object()
    if not meal then return "meal: unavailable (" .. tostring(src) .. ")" end
    return string.format("active=%s  timer=%s / %s  hp=+%s  stam=+%s",
        tostring(field_value(meal, "_IsEffectActive")),
        tostring(field_value(meal, "_DurationTimer")),
        tostring(field_value(meal, "_TimerMax")),
        tostring(field_value(meal, "_MaxHealthAdd")),
        tostring(field_value(meal, "_MaxStaminaAdd")))
end

-- ---------------------------------------------------------------------------
-- apply / clear
-- ---------------------------------------------------------------------------

local function apply_meal()
    if not data.ready then
        local ok, err = load_data()
        if not ok then lastStatus = "apply: " .. tostring(err) return end
    end
    local meal = selected_meal()
    if meal == nil then lastStatus = "apply: no meal data" return end

    local hunter, src = meal_object()
    if not hunter then lastStatus = "apply refused: " .. tostring(src) return end

    local effect = safe(function() return sdk.create_instance("app.cMealEffect") end)
    if effect == nil then lastStatus = "apply: cMealEffect instance failed" return end
    safe(function() effect:add_ref() end)

    local okCopy, copyErr = call_void(effect,
        "copyFrom(app.user_data.MealDataLobby.cData, System.Boolean)", meal.cdata, false)
    if not okCopy then
        lastStatus = "apply: copyFrom failed (" .. tostring(copyErr) .. ")"
        return
    end

    -- random buffs, one per table slot
    local applied_random, roll_errors = {}, {}
    if randoms_enabled then
        for i, tbl in ipairs(meal.random_tables or {}) do
            local pick = slots[i] or -1
            if pick == 0 then
                -- explicitly no buff in this slot
            elseif pick > 0 then
                local pool = meal_pool(meal)
                local rec = pool[pick]
                if rec then
                    local ok, err = call_void(effect,
                        "addRandomData(app.user_data.MealSkillRandomTable.cData)", rec.cdata)
                    if not ok then
                        -- fallback: add the skill alone (no per-buff stat line)
                        local sid = tonumber(rec.skill)
                        if sid then
                            ok = call_void(effect, "addSkill(app.MealDef.SKILL)", sid)
                        end
                    end
                    if ok then
                        applied_random[#applied_random + 1] = rec.name
                    else
                        roll_errors[#roll_errors + 1] = tostring(err)
                    end
                end
            else
                local num = tonumber(tbl)
                if num then
                    local ok, err = call_void(effect,
                        "addRandomTableParam(app.MealDef.RANDOM_SKILL_TBL_Fixed)", num)
                    if not ok then roll_errors[#roll_errors + 1] = tostring(err) end
                end
            end
        end
    end

    local attached, attachErr = call_void(hunter,
        "setMealEffect(app.cMealEffect, System.Boolean)", effect, false)
    if not attached then
        lastStatus = "apply: setMealEffect failed (" .. tostring(attachErr) .. ")"
        return
    end

    -- Mirror the state a real canteen eat leaves behind.
    local seconds = (tonumber(meal.minutes) or 70) * 60
    call_void(hunter, "setDurationTimer(System.Single)", seconds)
    call_void(hunter, "setTimerActive(System.Boolean)", true)
    call_void(hunter, "setEffectActive(System.Boolean)", true)
    write_field(hunter, MEAL_TYPE, "_DurationTimer", seconds)
    write_field(hunter, MEAL_TYPE, "_TimerMax", seconds)
    write_field(hunter, MEAL_TYPE, "_IsTimerActive", true)
    write_field(hunter, MEAL_TYPE, "_IsEffectActive", true)

    verify_pending = { frames = 15, count = 0 }
    save_config()

    local names = {}
    for _, n in ipairs(meal.fixed_names) do names[#names + 1] = n end
    for _, n in ipairs(applied_random) do names[#names + 1] = n end
    lastStatus = string.format("applied %s: %s%s",
        meal.label,
        table.concat(names, ", "),
        #roll_errors > 0 and ("  (" .. #roll_errors .. " random slot error)") or "")
    log.info("[MealBuffet] " .. lastStatus)
end

local function clear_meal()
    local hunter, src = meal_object()
    if not hunter then lastStatus = "clear refused: " .. tostring(src) return end
    local n = 0
    for _, f in ipairs(STRIP_FIELDS) do
        if field_value(hunter, f.name) ~= nil then
            local ok = write_field(hunter, MEAL_TYPE, f.name, f.value)
            if ok then n = n + 1 end
        end
    end
    lastStatus = string.format("cleared %d/%d meal fields", n, #STRIP_FIELDS)
    log.info("[MealBuffet] " .. lastStatus)
end

local ACTIONS = { apply = apply_meal, clear = clear_meal }

local function request_action(name)
    if ACTIONS[name] == nil then return end
    if pending_action ~= nil then
        lastStatus = "busy: " .. tostring(pending_action)
        return
    end
    pending_action = name
end

-- ---------------------------------------------------------------------------
-- frame callback: runs a queued action, then one verification read
-- ---------------------------------------------------------------------------

local function on_frame()
    if pending_action ~= nil then
        local name = pending_action
        pending_action = nil
        local ok, err = pcall(ACTIONS[name])
        if not ok then lastStatus = "error (" .. tostring(name) .. "): " .. tostring(err) end
        return
    end
    if verify_pending == nil then return end
    verify_pending.count = verify_pending.count + 1
    if verify_pending.count >= verify_pending.frames then
        verify_pending = nil
        local active = current_skills()
        local meal = meal_object()
        if meal and #active > 0 then
            local names = {}
            for _, rec in ipairs(active) do names[#names + 1] = rec.name end
            lastStatus = string.format("confirmed: %d skills active (%s)",
                #active, table.concat(names, ", "))
        end
    end
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

local function slot_label(meal, slot_index)
    local pick = slots[slot_index] or -1
    if pick == 0 then return "none" end
    if pick > 0 then
        local rec = meal_pool(meal)[pick]
        return rec and rec.name or "?"
    end
    return "game roll"
end

local function draw_ui()
    if not imgui.tree_node("Meal Buffet v" .. VERSION) then return end

    if not data.ready then
        local ok, err = load_data()
        if not ok then
            imgui.text("meal data not available: " .. tostring(err))
            imgui.text("enter a save (hub or camp), then reopen this panel")
            imgui.tree_pop()
            return
        end
    end

    imgui.text(current_line())
    local active = current_skills()
    if #active > 0 then
        imgui.text("active skills:")
        for _, rec in ipairs(active) do
            imgui.text("   " .. rec.name)
            local d = descriptions_on and skill_description(rec.id) or nil
            if d then imgui.text("      " .. short(d, 130)) end
        end
    else
        imgui.text("active skills: (none)")
    end
    imgui.separator()

    local meal = selected_meal()
    if meal == nil then
        imgui.text("no meal data")
        imgui.tree_pop()
        return
    end

    if imgui.button("< Prev") then
        sel_meal = ((sel_meal - 2) % #data.meals) + 1
        save_config()
    end
    imgui.same_line()
    imgui.text(string.format("%d/%d  %s  (%s)", sel_meal, #data.meals, meal.label, meal.menu_enum))
    imgui.same_line()
    if imgui.button("Next >") then
        sel_meal = (sel_meal % #data.meals) + 1
        save_config()
    end

    imgui.text(string.format("base: hp +%s  stam +%s  atk +%s  def +%s  %s min",
        tostring(meal.health), tostring(meal.stamina), tostring(meal.attack),
        tostring(meal.defence), tostring(meal.minutes)))
    imgui.text("fixed skills: ")
    for _, name in ipairs(meal.fixed_names) do
        imgui.text("   " .. name)
    end

    imgui.separator()
    if imgui.button(randoms_enabled and "Extra buffs: on" or "Extra buffs: off") then
        randoms_enabled = not randoms_enabled
        save_config()
    end
    imgui.same_line()
    if imgui.button(descriptions_on and "Descriptions: on" or "Descriptions: off") then
        descriptions_on = not descriptions_on
        save_config()
    end
    imgui.text("extra buffs (one per slot):")
    for i, _ in ipairs(meal.random_tables or {}) do
        imgui.text("   slot " .. i .. ": " .. slot_label(meal, i))
        imgui.same_line()
        if imgui.button("<##s" .. i) then
            local pool = meal_pool(meal)
            local pick = slots[i] or -1
            pick = pick - 1
            if pick < -1 then pick = #pool end
            slots[i] = pick
            save_config()
        end
        imgui.same_line()
        if imgui.button(">##s" .. i) then
            local pool = meal_pool(meal)
            local pick = slots[i] or -1
            pick = pick + 1
            if pick > #pool then pick = -1 end
            slots[i] = pick
            save_config()
        end
        local pick = slots[i] or -1
        if descriptions_on and pick > 0 then
            local rec = meal_pool(meal)[pick]
            local d = rec and skill_description(rec.skill) or nil
            if d then imgui.text("      " .. short(d, 130)) end
        end
    end

    imgui.separator()
    if imgui.button("Apply meal") then request_action("apply") end
    imgui.same_line()
    if imgui.button("Clear meal") then request_action("clear") end
    imgui.same_line()
    if imgui.button("Refresh data") then
        data.ready = false
        local ok, err = load_data()
        lastStatus = ok and "data refreshed" or ("refresh failed: " .. tostring(err))
    end

    imgui.separator()
    imgui.text("status: " .. tostring(lastStatus))
    imgui.separator()
    imgui.text("no voucher, no ingredients: the meal state is applied directly.")
    imgui.text("works in the hub, at camp, and during a quest.")
    imgui.tree_pop()
end

-- ---------------------------------------------------------------------------

if not ALREADY_LOADED then
    floored_slots()
    load_config()
    re.on_frame(function()
        local ok, err = pcall(on_frame)
        if not ok then log.warn("[MealBuffet] on_frame: " .. tostring(err)) end
    end)
    re.on_draw_ui(function()
        local ok, err = pcall(draw_ui)
        if not ok then log.warn("[MealBuffet] draw_ui: " .. tostring(err)) end
    end)
    log.info("[MealBuffet] loaded v" .. VERSION .. " (no hooks, UI only)")
else
    log.info("[MealBuffet] duplicate load ignored")
end
