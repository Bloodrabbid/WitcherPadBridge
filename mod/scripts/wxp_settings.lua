-- WitcherPadBridge :: a Gamepad block inside the game's own options screen.
--
-- Registered from an added file, not by editing a shipped one: hwdepsettings.lua's pattern is
-- makeClass(base) + RegisterLuaSetting(instance), and the options panel simply lists whatever the
-- manager knows about, filtered by GetCategory(). Using the existing "Gameplay" category means no
-- shipped script has to change and a Steam file verification cannot undo this.
--
-- Values are mirrored into <game>/System/wxp_config.ini, which the bridge polls; the engine's own
-- registry persistence (Write/ReadSettingIniEntry) keeps them across restarts.

local CFG = "wxp_config.ini"

local function log(s) if wxp_log then wxp_log("cfg: " .. tostring(s)) end end

-- Labels are literal strings: the talk table has no entries for us, and adding some would mean
-- shipping a modified TLK. Pick the language from an existing localized string -- UTF-8 Cyrillic
-- lead bytes are 0xD0/0xD1, which Latin-script locales do not produce. Resolved lazily: at load
-- time the talk table is not populated yet, but GetSettingName is only called once the options
-- screen is built.
local lang = nil

local function L(en, ru)
  if lang == nil then
    local ok, s = pcall(function()
      return g_TalkTable:GetSimpleString(g_tOptionDescriptions.InvertMouse)
    end)
    if ok and type(s) == "string" and string.len(s) > 0 then
      if string.find(s, "[\208\209]") then lang = "ru" else lang = "en" end
      log("label language = " .. lang)
    end
  end
  if lang == "ru" then return ru end
  return en
end

-- name -> { setting object, ini key, how the slider value maps to the ini value }
wxp_settings = {}

local function cfg_write()
  local f = io.open(CFG, "w")
  if f == nil then return end
  f:write("# written by the Gamepad section of the in-game options\n")
  for i = 1, table.getn(wxp_settings) do
    local e = wxp_settings[i]
    local v = e.obj:GetValue()
    if e.map then v = e.map(v) end
    f:write(e.key .. " = " .. tostring(v) .. "\n")
  end
  f:close()
end

wxp_cfg_write = cfg_write

-- One slider or checkbox. `map` converts the integer the slider carries into the value the bridge
-- expects (the engine only offers integer steps, so deadzones and curves are stored scaled).
local function define(class_name, key, label_en, label_ru, kind, lo, hi, default, map, names)
  local base = CCheckBoxSetting
  if kind == "range" then base = CContinousSetting end
  local C = makeClass(base)
  function C:new() return C:create() end
  function C:GetClassName() return class_name end
  function C:GetCategory() return "Gameplay" end
  function C:GetSettingName() return L(label_en, label_ru) end
  function C:GetDefaultValue() return default end
  if kind == "range" then
    function C:GetRange(pHWCaps) return lo, hi end
    -- `names` turns a short slider into a choice: the engine only offers integer steps, and a
    -- three-step slider that reads "off / on attack / on button" is a perfectly good picker.
    if names then
      function C:GetValueName(fValue)
        local n = names[fValue + 1]
        if n then return L(n[1], n[2]) end
        return tostring(fValue)
      end
    else
      function C:GetValueName(fValue) return tostring(fValue) end
    end
  end
  function C:ApplyChanges(pHWCaps)
    self:ApplyChangesInternal()
    pcall(cfg_write)
  end
  local obj = C:new()
  RegisterLuaSetting(obj)
  -- Read() restores the stored value and only falls back to GetDefaultValue when the registry
  -- has no entry at all. Ask first, and on a setting the player has never touched put the
  -- documented default in ourselves: AimSpeed came up 12 against a default of 22 on its first
  -- run here, which would have shipped a mod whose ini says 2200 and whose menu says 1200.
  local stored = false
  pcall(function() stored = ReadSettingIniEntry(class_name, nil) and true or false end)
  pcall(function() obj:Read() end)
  if not stored then pcall(function() obj:SetValue(default, nil) end) end
  table.insert(wxp_settings, {obj = obj, key = key, map = map})
  return obj
end

-- PauseButton is the one key the bridge reads as a word, so the slider position has to come
-- back out as one. Order matches PAUSE_BTN_* on both bridges.
local pause_names = { "touchpad", "menu", "back", "l3", "r3", "lt", "rt", "none" }
local function pause_btn(v) return pause_names[v + 1] or "touchpad" end

local function hundredths(v) return v / 100 end
local function tenths(v)     return v / 10 end
local function hundreds(v)   return v * 100 end

local ok, err = pcall(function()
  if wxp_settings_done then return end
  wxp_settings_done = true

  define("WxpGamepadEnabled", "Enabled",
         "Gamepad support", "Поддержка геймпада", "check", 0, 1, 1)
  define("WxpGamepadSensX", "SensitivityX",
         "Gamepad: camera speed X", "Геймпад: скорость камеры X", "range", 2, 30, 14, hundreds)
  define("WxpGamepadSensY", "SensitivityY",
         "Gamepad: camera speed Y", "Геймпад: скорость камеры Y", "range", 2, 30, 9, hundreds)
  define("WxpGamepadInvertY", "InvertY",
         "Gamepad: invert camera Y", "Геймпад: инверсия камеры по Y", "check", 0, 1, 0)
  define("WxpGamepadCurve", "CameraCurve",
         "Gamepad: camera response curve", "Геймпад: кривая отклика камеры", "range", 10, 30, 17, tenths)
  define("WxpGamepadDeadL", "DeadzoneLeft",
         "Gamepad: left stick deadzone", "Геймпад: мёртвая зона левого стика", "range", 5, 40, 20, hundredths)
  define("WxpGamepadDeadR", "DeadzoneRight",
         "Gamepad: right stick deadzone", "Геймпад: мёртвая зона правого стика", "range", 5, 40, 16, hundredths)
  define("WxpGamepadMenuSens", "MenuSensitivity",
         "Gamepad: menu cursor speed", "Геймпад: скорость курсора в меню", "range", 2, 30, 7, hundreds)

  -- The assist turns the camera for you, and doing that unasked is unpleasant however well it
  -- aims -- so the trigger is a setting, with a mode where it only ever moves the view while a
  -- button is held. Which button is AimButton in gamepad.ini; R3 by default.
  define("WxpGamepadAim", "AimAssist",
         "Gamepad: aim assist", "Геймпад: автонаведение", "range", 0, 2, 1, nil,
         { { "off",        "выкл" },
           { "on attack",  "при атаке" },
           { "on button",  "по кнопке" } })
  define("WxpGamepadAimSpeed", "AimSpeed",
         "Gamepad: aim assist speed", "Геймпад: скорость автонаведения", "range", 6, 36, 22, hundreds)

  -- Active pause (Space) had no button at all. The touchpad click is the middle button on a
  -- DualSense; an Xbox pad has none, and the bridge falls back to Menu by itself there.
  define("WxpGamepadPause", "PauseButton",
         "Gamepad: active pause button", "Геймпад: кнопка активной паузы", "range", 0, 7, 0,
         pause_btn,
         { { "touchpad", "тачпад" }, { "Menu", "Menu" },   { "Back", "Back" },
           { "L3", "L3" },           { "R3", "R3" },       { "LT", "LT" },
           { "RT", "RT" },           { "none", "нет" } })

  cfg_write()
  log("registered " .. table.getn(wxp_settings) .. " settings")
end)

if not ok then log("ERROR " .. tostring(err)) end
