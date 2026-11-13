--
-- meal_buffet.lua v0.3.0 — apply any canteen meal or consumable buff to your
-- hunter on demand
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
--   * can refresh the last applied meal while outside a quest (hub/camp), after
--     it expires or has 20 minutes left.
--   * consumables: activates the game's own item buffs (drugs, seeds, pills,
--     powders, drinks) with
--       app.cHunterItemBuff:activateItemBuff(type, 1.0, timeScale)
--     where timeScale is 1.0 or the Item Prolonger multiplier. No item is
--     consumed and nothing has to be in the pouch.
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

local VERSION = "0.3.0"
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
local pending_con = nil
local verify_frames = 0
local verify_pending = nil

-- ---------------------------------------------------------------------------
-- consumable buffs
-- ---------------------------------------------------------------------------
-- The game owns the buff list and the base durations: activateItemBuff takes
-- (type, effect rate, time scale) and applies its own base time multiplied by
-- the scale. `secs` below is only the UI preview of that base, measured on the
-- current build (probe v3/v4); the applied time always comes from the game.

local ITEM_BUFF_ENUM = "app.HunterDef.ITEM_BUFF_TYPE"

local CONSUMABLES = {
    -- enum            group      label               secs  effect
    { enum = "KIJIN_DRINK",   group = "Drugs",   label = "Demondrug",        secs = 1800, effect = "Attack up",                  struct = "_KijinDrink" },
    { enum = "KIJIN_DRINK_G", group = "Drugs",   label = "Mega Demondrug",   secs = 1800, effect = "Attack up (stronger)",       struct = "_KijinDrink_G" },
    { enum = "KOUKA",         group = "Drugs",   label = "Armorskin",        secs = 1800, effect = "Defence up",                 struct = "_KoukaDrink" },
    { enum = "KOUKA_G",       group = "Drugs",   label = "Mega Armorskin",   secs = 1800, effect = "Defence up (stronger)",      struct = "_KoukaDrink_G" },
    { enum = "KAIRIKI",       group = "Seeds",   label = "Might Seed",       secs = 180,  effect = "Attack up",                  field = "_Kairiki_Timer" },
    { enum = "NINTAI",        group = "Seeds",   label = "Adamant Seed",     secs = 180,  effect = "Defence up",                 field = "_Nintai_Timer" },
    { enum = "KAIRIKI_G",     group = "Pills",   label = "Might Pill",       secs = 21,   effect = "Attack up (short, strong)",  field = "_Kairiki_G_Timer" },
    { enum = "NINTAI_G",      group = "Pills",   label = "Adamant Pill",     secs = 90,   effect = "Defence up (short, strong)", field = "_Nintai_G_Timer" },
    { enum = "KIJIN_POWDER",  group = "Powders", label = "Demon Powder",     secs = 180,  effect = "Attack up (area)",           field = "_KijinPowder_Timer" },
    { enum = "KOUKA_POWDER",  group = "Powders", label = "Hardshell Powder", secs = 180,  effect = "Defence up (area)",          field = "_KoukaPowder_Timer" },
    { enum = "DASH_JUICE",    group = "Drinks",  label = "Dash Juice",       secs = 180,  effect = "Stamina drain down",         field = "_DashJuice_Timer" },
    { enum = "IMMUNIZER",     group = "Drinks",  label = "Immunizer",        secs = 300,  effect = "Red health recovery",        field = "_Immunizer_Timer" },
    { enum = "HOT_DRINK",     group = "Drinks",  label = "Hot Drink",        secs = 600,  effect = "Cold resistance",            field = "_HotDrink_Timer" },
    { enum = "COOLER_DRINK",  group = "Drinks",  label = "Cool Drink",       secs = 600,  effect = "Heat resistance",            field = "_CoolerDrink_Timer" },
}

-- Buffs that occupy the same slot: applying one removes the other.
local CON_EXCLUSIVE = {
    KIJIN_DRINK = "atk_drink", KIJIN_DRINK_G = "atk_drink",
    KOUKA = "def_drink",       KOUKA_G = "def_drink",
    KAIRIKI = "atk_seed",      KAIRIKI_G = "atk_seed",
    NINTAI = "def_seed",       NINTAI_G = "def_seed",
}

-- One built-in set plus four user slots. A slot stores the ticked buffs when
-- you press "Save selection"; slots are not named.
local STANDARD_PRESET = { "KIJIN_DRINK_G", "KOUKA_G", "KAIRIKI", "NINTAI",
                          "KIJIN_POWDER", "KOUKA_POWDER", "DASH_JUICE" }

local CUSTOM_SLOTS = 4
local custom_presets = { {}, {}, {}, {} }

-- index 1 = Standard, 2..CUSTOM_SLOTS+1 = the user slots
local function preset_at(i)
    if i == 1 then return "Standard", STANDARD_PRESET end
    local slot = i - 1
    local list = custom_presets[slot]
    if list and #list > 0 then return "Set " .. slot, list end
    return "Set " .. slot, nil
end

local function preset_count()
    return CUSTOM_SLOTS + 1
end

local CON_GROUPS = { "Drugs", "Seeds", "Pills", "Powders", "Drinks" }

-- Item Prolonger (Enduring Jewel): +10 / +25 / +50 %
local PROLONGER_RATE = { [0] = 1.0, [1] = 1.1, [2] = 1.25, [3] = 1.5 }

local con = {
    ready = false,
    enum = {},          -- enum name -> value
    rate = 1.0,         -- Item Prolonger multiplier on the hunter right now
    level = 0,
    error = nil,
}

local con_selected = {}       -- enum name -> true
local prolonger_on = true     -- apply the multiplier when activating
local prolonger_level = nil   -- nil = follow the hunter's skill
local panel = "meals"         -- "meals" | "consumables"
local auto_on = false         -- apply a preset when a quest starts
local auto_drinks = false     -- apply Hot/Cool Drink in hot/cold areas
local auto_preset = 1         -- 1 = Standard, 2..5 = user slots
local auto_tick = 0
local auto_in_quest = false
local auto_drink_done = false   -- one drink per quest
local auto_start_frames = 0     -- frames since the quest started
local auto_meal_refresh = false -- re-apply the meal while outside a quest
local auto_meal_cooldown = 0    -- frames; avoids retry storms if apply fails
local meal_cleared = false      -- user pressed Clear meal: do not fight it
local last_meal_menu = nil      -- menu enum of the last applied meal

-- Refresh the meal when this many seconds (or less) are left on its timer.
local MEAL_REFRESH_BELOW = 1200


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

local function local_character()
    local pm = safe(function() return sdk.get_managed_singleton("app.PlayerManager") end)
    if not pm then return nil, nil, "no_player_manager" end
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
                return ch, st, "user_control"
            end
        end
    end
    return nil, nil, "no_user_controlled_status"
end

local function local_status()
    local _, st, src = local_character()
    if not st then return nil, src end
    return st, src
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

-- The last meal that was applied, by its menu enum, so auto refresh keeps the
-- meal you actually ate instead of whatever the picker is previewing.
local function meal_by_menu(name)
    if name == nil then return nil end
    for _, meal in ipairs(data.meals) do
        if meal.menu_enum == name then return meal end
    end
    return nil
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
    if type(cfg.prolonger_on) == "boolean" then prolonger_on = cfg.prolonger_on end
    if type(cfg.prolonger_level) == "number" then
        local lv = math.floor(cfg.prolonger_level)
        if lv >= 0 and lv <= 3 then prolonger_level = lv end
    end
    if cfg.panel == "consumables" or cfg.panel == "meals" then panel = cfg.panel end
    if type(cfg.auto_on) == "boolean" then auto_on = cfg.auto_on end
    if type(cfg.auto_drinks) == "boolean" then auto_drinks = cfg.auto_drinks end
    if type(cfg.auto_meal_refresh) == "boolean" then auto_meal_refresh = cfg.auto_meal_refresh end
    if type(cfg.last_meal_menu) == "string" then last_meal_menu = cfg.last_meal_menu end
    if type(cfg.auto_preset) == "number" then
        local idx = math.floor(cfg.auto_preset)
        if idx >= 1 and idx <= preset_count() then auto_preset = idx end
    end
    if type(cfg.consumables) == "table" then
        con_selected = {}
        for name, v in pairs(cfg.consumables) do
            if type(name) == "string" and v == true then con_selected[name] = true end
        end
    end
    if type(cfg.custom_presets) == "table" then
        local valid = {}
        for _, spec in ipairs(CONSUMABLES) do valid[spec.enum] = true end
        custom_presets = {}
        for slot = 1, CUSTOM_SLOTS do
            local list = {}
            local saved = cfg.custom_presets[slot]
            if type(saved) == "table" then
                for _, name in ipairs(saved) do
                    if valid[name] then list[#list + 1] = name end
                end
            end
            custom_presets[slot] = list
        end
    end
end

local function save_config()
    safe(function()
        local sel = {}
        for name, v in pairs(con_selected) do
            if v then sel[name] = true end
        end
        json.dump_file(CONFIG_FILE, {
            meal = sel_meal,
            slots = { slots[1] or -1, slots[2] or -1, slots[3] or -1, slots[4] or -1 },
            randoms_enabled = randoms_enabled,
            descriptions = descriptions_on,
            consumables = sel,
            prolonger_on = prolonger_on,
            prolonger_level = prolonger_level,
            panel = panel,
            auto_on = auto_on,
            auto_drinks = auto_drinks,
            auto_meal_refresh = auto_meal_refresh,
            last_meal_menu = last_meal_menu,
            auto_preset = auto_preset,
            custom_presets = custom_presets,
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

local function apply_meal(menu)
    if not data.ready then
        local ok, err = load_data()
        if not ok then lastStatus = "apply: " .. tostring(err) return end
    end
    local meal = meal_by_menu(menu) or selected_meal()
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
    last_meal_menu = meal.menu_enum
    meal_cleared = false
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
    if n > 0 then meal_cleared = true end
    lastStatus = string.format("cleared %d/%d meal fields", n, #STRIP_FIELDS)
    log.info("[MealBuffet] " .. lastStatus)
end

local function apply_last_meal()
    apply_meal(last_meal_menu)
end

local ACTIONS = { apply = apply_meal, apply_last = apply_last_meal, clear = clear_meal }

-- ---------------------------------------------------------------------------
-- consumable buffs: apply / clear
-- ---------------------------------------------------------------------------

local function consumable_spec(name)
    for _, spec in ipairs(CONSUMABLES) do
        if spec.enum == name then return spec end
    end
    return nil
end

local function item_buff()
    local st, src = local_status()
    if not st then return nil, src end
    local ib = field_value(st, "_ItemBuff")
    if ib == nil then return nil, "no_item_buff" end
    return ib, src, st
end

local function load_consumable_data()
    local map = enum_names(ITEM_BUFF_ENUM)
    if next(map) == nil then
        con.error = "enum not found: " .. ITEM_BUFF_ENUM
        return false, con.error
    end
    con.enum = {}
    for value, name in pairs(map) do
        con.enum[tostring(name)] = tonumber(value)
    end
    local rate = 1.0
    local st = local_status()
    if st then
        local skill = field_value(st, "_Skill")
        local r = skill and call_method(skill, "getSkillItemUsePowerUpTimeRate")
        if type(r) == "number" and r > 0 then rate = r end
    end
    con.rate = rate
    con.level = 0
    for lv = 3, 0, -1 do
        if math.abs(PROLONGER_RATE[lv] - rate) < 0.001 then
            con.level = lv
            break
        end
    end
    con.ready = true
    con.error = nil
    return true
end

-- Time scale passed to the game: 1.0, or the Item Prolonger multiplier.
local function con_scale()
    if not prolonger_on then return 1.0 end
    if prolonger_level ~= nil then return PROLONGER_RATE[prolonger_level] or 1.0 end
    return con.rate or 1.0
end

local function consumable_timer(spec, ib)
    if spec.struct then
        local s = field_value(ib, spec.struct)
        return s and field_value(s, "_Timer") or nil
    end
    return field_value(ib, spec.field)
end

local function active_consumables()
    local ib = item_buff()
    if not ib then return {} end
    local out = {}
    for _, spec in ipairs(CONSUMABLES) do
        local t = tonumber(consumable_timer(spec, ib))
        if t and t > 0 then
            out[#out + 1] = { spec = spec, timer = t }
        end
    end
    return out
end

local function apply_consumable(spec, ib)
    local v = con.enum[spec.enum]
    if v == nil then return false, "enum_missing" end
    -- same-slot buffs replace each other instead of stacking
    local group = CON_EXCLUSIVE[spec.enum]
    if group then
        for _, other in ipairs(CONSUMABLES) do
            if other.enum ~= spec.enum and CON_EXCLUSIVE[other.enum] == group then
                local ov = con.enum[other.enum]
                if ov then
                    call_void(ib, "deactivateItemBuff(app.HunterDef.ITEM_BUFF_TYPE)", ov)
                end
            end
        end
    end
    return call_void(ib,
        "activateItemBuff(app.HunterDef.ITEM_BUFF_TYPE, System.Single, System.Single)",
        v, 1.0, con_scale())
end

local function apply_consumables(names, label)
    if not con.ready then
        local ok, err = load_consumable_data()
        if not ok then lastStatus = "consumables: " .. tostring(err) return end
    end
    local ib, src = item_buff()
    if not ib then lastStatus = "consumables refused: " .. tostring(src) return end
    local applied, failed = {}, {}
    for _, name in ipairs(names) do
        local spec = consumable_spec(name)
        if spec then
            local ok, err = apply_consumable(spec, ib)
            if ok then
                applied[#applied + 1] = spec.label
            else
                failed[#failed + 1] = spec.label .. " (" .. tostring(err) .. ")"
            end
        end
    end
    local scale = con_scale()
    lastStatus = string.format("%s: applied %d buff%s%s%s",
        label or "consumables", #applied, #applied == 1 and "" or "s",
        scale ~= 1.0 and string.format(" (Item Prolonger x%.2f)", scale) or "",
        #failed > 0 and ("  failed: " .. table.concat(failed, ", ")) or "")
    log.info("[MealBuffet] " .. lastStatus)
end

local function clear_consumables(names, label)
    if not con.ready then
        local ok, err = load_consumable_data()
        if not ok then lastStatus = "consumables: " .. tostring(err) return end
    end
    local ib, src = item_buff()
    if not ib then lastStatus = "clear refused: " .. tostring(src) return end
    local n = 0
    for _, name in ipairs(names) do
        local spec = consumable_spec(name)
        local v = spec and con.enum[spec.enum]
        if v then
            if call_void(ib, "deactivateItemBuff(app.HunterDef.ITEM_BUFF_TYPE)", v) then
                n = n + 1
            end
        end
    end
    lastStatus = string.format("%s: cleared %d buff%s",
        label or "consumables", n, n == 1 and "" or "s")
    log.info("[MealBuffet] " .. lastStatus)
end

local function all_consumable_names()
    local out = {}
    for _, spec in ipairs(CONSUMABLES) do out[#out + 1] = spec.enum end
    return out
end

local function selected_consumable_names()
    local out = {}
    for _, spec in ipairs(CONSUMABLES) do
        if con_selected[spec.enum] then out[#out + 1] = spec.enum end
    end
    return out
end

local function request_con(names, clear, label)
    if names == nil or #names == 0 then
        lastStatus = "nothing selected"
        return
    end
    if pending_con ~= nil or pending_action ~= nil then
        lastStatus = "busy: " .. tostring(pending_con and "consumables" or pending_action)
        return
    end
    pending_con = { names = names, clear = clear == true, label = label }
end


local function request_action(name)
    if ACTIONS[name] == nil then return end
    if pending_action ~= nil then
        lastStatus = "busy: " .. tostring(pending_action)
        return
    end
    pending_action = name
end

-- ---------------------------------------------------------------------------
-- auto-apply on quest start
-- ---------------------------------------------------------------------------

-- No hook: app.MissionManager.get_IsPlayingQuest() is polled a few times a
-- second while a toggle is on. On the rising edge the chosen preset is
-- applied; the Hot/Cool Drink pick is delayed up to 15 s so the area flags
-- have time to resolve, and is applied at most once per quest.
-- Resolve an enum value back to its field name (REFramework does not expose
-- Enum.GetName, but the static fields carry the values).
local function enum_name_for(typeName, value)
    local td = safe(sdk.find_type_definition, typeName)
    if td == nil or value == nil then return nil end
    for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
        if safe(function() return f:is_static() end) then
            local v = safe(function() return f:get_data(nil) end)
            if v ~= nil and v == value then
                return safe(function() return f:get_name() end)
            end
        end
    end
    return nil
end

-- Resolve a getter's value against the enum type the method itself declares
-- as its return type (guessing type names picked the wrong enum before).
local function method_enum(obj, methodName)
    local td = safe(function() return obj:get_type_definition() end)
    if td == nil then return nil end
    local m = safe(function() return td:get_method(methodName .. "()") end)
        or safe(function() return td:get_method(methodName) end)
    if m == nil then return nil end
    local v = safe(function() return m:call(obj) end)
    if v == nil then return nil end
    local rt = safe(function() return m:get_return_type() end)
    local rt_name = rt and safe(function() return rt:get_full_name() end)
    local name = rt_name and enum_name_for(rt_name, v) or nil
    return v, name, rt_name
end

-- Locale id -> drink. Prefix match, so ST103_BC / ST103_VLG / ST103 all hit.
-- Special quest locales (ST4xx) can be listed next to the open maps.
local STAGE_DRINK = {
    ST103 = "COOLER_DRINK", -- Oilwell Basin
    ST104 = "HOT_DRINK",    -- Iceshard Cliffs
    ST402 = "HOT_DRINK",    -- Omega Planetes arena
}

local function stage_drink(name)
    if name == nil then return nil end
    local n = string.upper(tostring(name)):gsub("[^A-Z0-9]", "")
    for code, drink in pairs(STAGE_DRINK) do
        if n:find(code) then return drink end
    end
    return nil
end

-- The quest supplies a stage/environment too; used when the life-area code is
-- not one of the known maps yet.
local function quest_map()
    local mm = safe(function() return sdk.get_managed_singleton("app.MissionManager") end)
    local aqd = mm and call_method(mm, "get_ActiveQuestData")
    if aqd == nil then return nil end
    local stage_v, stage_name, stage_type = method_enum(aqd, "getStage")
    local env_v, env_name, env_type = method_enum(aqd, "getEnvironmentType")
    if stage_v == nil and env_v == nil then return nil end
    return {
        stage = stage_name, stage_value = stage_v, stage_type = stage_type,
        env = env_name, env_value = env_v, env_type = env_type,
    }
end

local function map_drink_name(name)
    if name == nil then return nil end
    local known = stage_drink(name)
    if known then return known end
    -- tolerant match: drop spaces/underscores ("ST 103", "ST103_BC")
    local n = string.upper(tostring(name)):gsub("[^A-Z0-9]", "")
    if n:find("OILWELL") or n:find("LAVA") or n:find("VOLCAN")
        or n:find("HOT") or n:find("HEAT") or n:find("SCORCH") then
        return "COOLER_DRINK"
    end
    if n:find("ICE") or n:find("SNOW") or n:find("COLD") or n:find("FREEZ") then
        return "HOT_DRINK"
    end
    return nil
end

-- Fallback: the character's own area flags (used when the map is unknown).
local function area_drink()
    local ch = local_character()
    if ch == nil then return nil end
    if call_method(ch, "get_IsInHotArea") == true then return "COOLER_DRINK" end
    if call_method(ch, "get_IsInColdArea") == true then return "HOT_DRINK" end
    return nil
end

-- Which drink the current map wants, and a short source label for the status.
local function current_drink()
    local info = quest_map()
    -- The quest's stage is the locale id (ST1xx): the map signal.
    local want = info and map_drink_name(info.stage)
    if want then return want, tostring(info.stage) .. " " .. tostring(info.stage_value) end
    want = info and map_drink_name(info.env)
    if want then return want, tostring(info.env) end
    want = area_drink()
    if want then return want, "area" end
    return nil
end

local function try_auto_drink()
    if not auto_drinks or auto_drink_done then return end
    auto_start_frames = auto_start_frames + 30
    if auto_start_frames > 900 then -- 15 s: stop looking, no drink this quest
        auto_drink_done = true
        return
    end
    local want, source = current_drink()
    if want == nil then return end
    local spec = consumable_spec(want)
    if spec == nil then
        auto_drink_done = true
        return
    end
    local ib = item_buff()
    if ib == nil then return end
    if pending_con ~= nil or pending_action ~= nil then return end
    auto_drink_done = true
    pending_con = {
        names = { want }, clear = false,
        label = source and ("auto " .. spec.label .. " [" .. tostring(source) .. "]")
            or ("auto " .. spec.label),
    }
end

-- Outside a quest only: re-apply the last meal when it expired or is about to.
local function try_auto_meal(in_quest)
    if not auto_meal_refresh or meal_cleared then return end
    if in_quest ~= false then return end -- nil = unknown (loading), skip too
    if auto_meal_cooldown > 0 then return end
    if pending_action ~= nil or pending_con ~= nil then return end
    local meal = meal_object()
    if meal == nil then return end
    local active = field_value(meal, "_IsEffectActive") == true
    local timer = tonumber(field_value(meal, "_DurationTimer")) or 0
    if active and timer > MEAL_REFRESH_BELOW then return end
    auto_meal_cooldown = 120 -- 2 s at 60 fps; enough to survive a failed apply
    pending_action = "apply_last"
end

local function poll_auto_quest()
    local mm = safe(function() return sdk.get_managed_singleton("app.MissionManager") end)
    if mm == nil then return end
    local in_quest = call_method(mm, "get_IsPlayingQuest")
    if in_quest == nil then in_quest = call_method(mm, "get_IsActiveQuest") end
    local ok_meal, err_meal = pcall(try_auto_meal, in_quest)
    if not ok_meal then log.warn("[MealBuffet] auto meal: " .. tostring(err_meal)) end
    if in_quest ~= true then
        auto_in_quest = false
        auto_drink_done = false
        auto_start_frames = 0
        return
    end
    if auto_in_quest then
        try_auto_drink()
        return
    end
    if item_buff() == nil then return end -- hunter not ready yet: retry next poll
    auto_in_quest = true
    auto_drink_done = false
    auto_start_frames = 0
    if auto_on and pending_con == nil and pending_action == nil then
        local name, buffs = preset_at(auto_preset)
        if buffs ~= nil and #buffs > 0 then
            pending_con = { names = buffs, clear = false, label = "auto " .. name }
        end
    end
end

-- ---------------------------------------------------------------------------
-- frame callback: runs a queued action, then one verification read
-- ---------------------------------------------------------------------------

local function on_frame()
    auto_tick = auto_tick + 1
    if auto_meal_cooldown > 0 then auto_meal_cooldown = auto_meal_cooldown - 1 end
    if (auto_on or auto_drinks or auto_meal_refresh) and (auto_tick % 30) == 0 then
        if (auto_on or auto_drinks) and not con.ready then load_consumable_data() end
        local ok, err = pcall(poll_auto_quest)
        if not ok then log.warn("[MealBuffet] auto: " .. tostring(err)) end
    end
    if pending_con ~= nil then
        local job = pending_con
        pending_con = nil
        local ok, err = pcall(function()
            if job.clear then
                clear_consumables(job.names, job.label)
            else
                apply_consumables(job.names, job.label)
            end
        end)
        if not ok then lastStatus = "error (consumables): " .. tostring(err) end
        return
    end
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

local function fmt_duration(sec)
    sec = math.max(0, math.floor(tonumber(sec) or 0))
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

local function draw_meal_section()
    if not data.ready then
        local ok, err = load_data()
        if not ok then
            imgui.text("meal data not available: " .. tostring(err))
            imgui.text("enter a save (hub or camp), then reopen this panel")
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
    local refresh_changed, refresh_value = imgui.checkbox(
        "Auto refresh outside quest", auto_meal_refresh)
    if refresh_changed then
        auto_meal_refresh = refresh_value
        if refresh_value then meal_cleared = false end
        save_config()
    end
    imgui.same_line()
    imgui.text(string.format("(reapply at %s left)", fmt_duration(MEAL_REFRESH_BELOW)))
    if auto_meal_refresh and meal_cleared then
        imgui.text("   paused after Clear meal; press Apply meal to resume")
    end

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
    imgui.text("no voucher, no ingredients: the meal state is applied directly.")
    imgui.text("works in the hub, at camp, and during a quest.")
end

local function draw_consumables_section()
    if not con.ready then load_consumable_data() end
    if not con.ready then
        imgui.text("consumable data not available: " .. tostring(con.error))
        imgui.text("enter a save (hub or camp), then reopen this panel")
        return
    end

    local active = active_consumables()
    if #active > 0 then
        imgui.text("active item buffs:")
        for _, rec in ipairs(active) do
            imgui.text(string.format("   %-20s %s", rec.spec.label, fmt_duration(rec.timer)))
        end
    else
        imgui.text("active item buffs: (none)")
    end
    imgui.separator()

    imgui.text("presets:")
    if imgui.button("Standard") then request_con(STANDARD_PRESET, false, "Standard") end
    imgui.same_line()
    if imgui.button("Clear all buffs") then request_con(all_consumable_names(), true) end

    for slot = 1, CUSTOM_SLOTS do
        local list = custom_presets[slot] or {}
        imgui.text(string.format("Set %d (%d buff%s)", slot, #list, #list == 1 and "" or "s"))
        imgui.same_line()
        if imgui.button("Apply##ps" .. slot) then
            request_con(list, false, "Set " .. slot)
        end
        imgui.same_line()
        if imgui.button("Save selection##ps" .. slot) then
            local names = selected_consumable_names()
            if #names == 0 then
                lastStatus = "tick the buffs first, then save"
            else
                custom_presets[slot] = names
                save_config()
                lastStatus = string.format("saved %d buff%s to set %d",
                    #names, #names == 1 and "" or "s", slot)
            end
        end
        imgui.same_line()
        if imgui.button("Clear##ps" .. slot) then
            custom_presets[slot] = {}
            save_config()
            lastStatus = "cleared set " .. slot
        end
    end
    imgui.separator()

    if imgui.button(auto_on and "Auto preset on quest start: on" or "Auto preset on quest start: off") then
        auto_on = not auto_on
        auto_in_quest = false
        save_config()
    end
    imgui.same_line()
    local auto_name, auto_buffs = preset_at(auto_preset)
    imgui.text(string.format("preset %s%s", auto_name,
        (auto_buffs == nil or #auto_buffs == 0) and " (empty)" or ""))
    imgui.same_line()
    if imgui.button("<##ap") then
        auto_preset = ((auto_preset - 2) % preset_count()) + 1
        save_config()
    end
    imgui.same_line()
    if imgui.button(">##ap") then
        auto_preset = (auto_preset % preset_count()) + 1
        save_config()
    end

    if imgui.button(auto_drinks and "Auto Hot/Cool Drink on quest start: on"
        or "Auto Hot/Cool Drink on quest start: off") then
        auto_drinks = not auto_drinks
        save_config()
    end
    imgui.same_line()
    local info_now = quest_map()
    if info_now and info_now.stage then
        imgui.text(string.format("stage: %s [%s]", tostring(info_now.stage),
            tostring(info_now.stage_value)))
    end
    imgui.separator()

    -- Item Prolonger (Enduring Jewel): scales the buff's own base duration.
    local changed, value = imgui.checkbox("Item Prolonger", prolonger_on)
    if changed then prolonger_on = value save_config() end
    imgui.same_line()
    if prolonger_level == nil then
        imgui.text(string.format("auto: Lv%d  x%.2f", con.level, con.rate))
    else
        imgui.text(string.format("manual: Lv%d  x%.2f", prolonger_level,
            PROLONGER_RATE[prolonger_level] or 1.0))
    end
    imgui.same_line()
    if imgui.button("<##plv") then
        local lv = prolonger_level or con.level
        prolonger_level = (lv + 3) % 4
        save_config()
    end
    imgui.same_line()
    if imgui.button(">##plv") then
        local lv = prolonger_level or con.level
        prolonger_level = (lv + 1) % 4
        save_config()
    end
    imgui.same_line()
    if imgui.button("auto##plv") then
        prolonger_level = nil
        save_config()
    end

    local scale = con_scale()
    local ib = item_buff()
    imgui.separator()
    for _, group in ipairs(CON_GROUPS) do
        imgui.text(group)
        for _, spec in ipairs(CONSUMABLES) do
            if spec.group == group then
                local sel, checked = imgui.checkbox("##sel" .. spec.enum,
                    con_selected[spec.enum] == true)
                if sel then
                    con_selected[spec.enum] = checked or nil
                    save_config()
                end
                imgui.same_line()
                imgui.text(string.format("%s  -  %s  -  %s",
                    spec.label, spec.effect, fmt_duration(spec.secs * scale)))
                imgui.same_line()
                if imgui.button("Apply##ap" .. spec.enum) then
                    request_con({ spec.enum }, false)
                end
                local t = ib and tonumber(consumable_timer(spec, ib)) or nil
                if t and t > 0 then
                    imgui.same_line()
                    imgui.text("left " .. fmt_duration(t))
                    imgui.same_line()
                    if imgui.button("Clear##cl" .. spec.enum) then
                        request_con({ spec.enum }, true)
                    end
                end
            end
        end
    end

    imgui.separator()
    local selected = selected_consumable_names()
    if imgui.button(string.format("Apply selected (%d)", #selected)) then
        request_con(selected, false)
    end
    imgui.same_line()
    if imgui.button("Clear selected") then request_con(selected, true) end
    imgui.same_line()
    if imgui.button("Refresh") then
        con.ready = false
        local ok, err = load_consumable_data()
        lastStatus = ok and "consumable data refreshed" or ("refresh failed: " .. tostring(err))
    end

    imgui.separator()
    imgui.text("no item is consumed; nothing has to be in your pouch.")
    imgui.text("duration comes from the game; Item Prolonger adds its bonus when on.")
end

local function draw_ui()
    if not imgui.tree_node("Meal Buffet v" .. VERSION) then return end

    if imgui.button(panel == "meals" and "[ Meals ]" or "Meals") then
        panel = "meals"
        save_config()
    end
    imgui.same_line()
    if imgui.button(panel == "consumables" and "[ Consumables ]" or "Consumables") then
        panel = "consumables"
        save_config()
    end
    imgui.separator()

    if panel == "consumables" then
        draw_consumables_section()
    else
        draw_meal_section()
    end

    imgui.separator()
    imgui.text("status: " .. tostring(lastStatus))
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
