-- WitcherPadBridge :: runtime layer
-- Loaded from debug.luc, which runs before the GUI and gameplay scripts exist. Hooks are
-- installed in two deferred steps: wait for the class global to appear, then wait for the
-- method to be assigned onto it. Everything is pcall-wrapped so a mistake here can never
-- stop the game from booting.

local LOG   = "wxp_gamepad.log"
local STATE = "wxp_state.ini"
local CMD   = "wxp_cmd.txt"
local LOGMAX = 512 * 1024

-- Version stamp. tools/package.sh rewrites this line when it builds a release, so a log file
-- says which build produced it -- the first question about any report from another machine.
local VERSION = "dev"

-- Timestamps: without them "and then it stopped working" cannot be lined up with anything in
-- the bridge log next to it. os.date is not guaranteed to be in this engine's Lua, so ask once
-- and carry on plain if it is not.
local have_date = pcall(function() return os.date("%H:%M:%S") end)
local function stamp()
  if not have_date then return "" end
  local ok, s = pcall(function() return os.date("%H:%M:%S") end)
  if ok and s then return s .. "  " end
  return ""
end

function wxp_log(s)
  local f = io.open(LOG, "a")
  if f then f:write(stamp() .. tostring(s) .. "\n") f:close() end
end

-- Keep one previous log. Played for a week with the REPL on, this file would otherwise be the
-- largest thing anyone is ever asked to send back.
local function log_rotate()
  local f = io.open(LOG, "r")
  if f == nil then return end
  local ok, size = pcall(function() return f:seek("end") end)
  f:close()
  if ok and size and size > LOGMAX then
    pcall(function() os.remove(LOG .. ".1") end)
    pcall(function() os.rename(LOG, LOG .. ".1") end)
  end
end

wxp_panelmgr = nil     -- live CGuiInGamePanelManager instance
wxp_module   = nil     -- live CNWCModule instance
wxp_mode     = "world" -- "world" | "ui"; assume gameplay until a panel says otherwise
wxp_panel    = "-"     -- name of the panel that is currently up
wxp_focus    = nil     -- control that currently holds gamepad focus
wxp_items    = {}      -- focusable controls of the panel we are navigating

wxp_tick_n = 0

-- The bridge treats this file's mtime as proof that Lua is alive: no tick for 3 s means the
-- game is at the main menu (no module heartbeat) and it should drive the cursor instead of
-- sending navigation intents. So rewrite it about once a second even when nothing changed.
local function write_state()
  wxp_tick_n = wxp_tick_n + 1
  local sect, foc = "-", "-"
  if wxp_ui then
    local s = wxp_ui.sections and wxp_ui.sections[wxp_ui.si]
    if s then sect = string.gsub(tostring(s.name), "[\r\n]+", " ") end
    -- Control names can carry the text they were built from, and a save game's caption has a
    -- newline in it -- which would split one key across two lines of this ini file.
    if wxp_ui.focus and wxp_ui.focus.m_Name then
      foc = string.gsub(tostring(wxp_ui.focus.m_Name), "[\r\n]+", " ")
    end
    -- wxp_ui only knows what it saw at its last refresh, so trust it while a screen is up and
    -- fall back to whatever poll_state decided otherwise.
    if wxp_mode == "world" then wxp_panel = "-"
    elseif wxp_ui.panel and wxp_ui.panel ~= "-" then wxp_panel = wxp_ui.panel end
  end
  local f = io.open(STATE, "w")
  if f then
    f:write("Mode=" .. wxp_mode .. "\n")
    f:write("Panel=" .. wxp_panel .. "\n")
    f:write("Section=" .. sect .. "\n")
    f:write("Focus=" .. foc .. "\n")
    f:write("Tick=" .. wxp_tick_n .. "\n")
    f:close()
  end
end

-- ---------------------------------------------------------------- deferred hooks

-- Replace class[name] with a wrapper the moment the game assigns it.
local function wrap_when_defined(class, name, make_wrapper)
  local mt = getmetatable(class)
  if mt == nil then mt = {} end
  local prev = mt.__newindex
  mt.__newindex = function(t, k, v)
    if k == name and type(v) == "function" then
      rawset(t, k, make_wrapper(v))
      pcall(function() wxp_log("hook installed: " .. name) end)
      return
    end
    if prev then prev(t, k, v) else rawset(t, k, v) end
  end
  setmetatable(class, mt)
  if type(rawget(class, name)) == "function" then
    rawset(class, name, make_wrapper(rawget(class, name)))
    pcall(function() wxp_log("hook installed (immediate): " .. name) end)
  end
end

-- ---------------------------------------------------------------- inspection helpers
-- These are globals on purpose: the command channel below evaluates arbitrary Lua, and
-- these are what that Lua is expected to call.

function wxp_type(v)
  local t = type(v)
  if t ~= "table" and t ~= "userdata" then return t end
  local ok, cn = pcall(function() return v:GetClassName() end)
  if ok and type(cn) == "string" then return t .. ":" .. cn end
  return t
end

-- Every key of a table plus everything its metatable's __index exposes.
function wxp_keys(o, depth)
  local out, seen = {}, {}
  local function add(k, v)
    if seen[k] then return end
    seen[k] = true
    table.insert(out, tostring(k) .. "(" .. wxp_type(v) .. ")")
  end
  local t = o
  local n = 0
  while t and n < (depth or 4) do
    if type(t) == "table" then
      for k, v in pairs(t) do add(k, v) end
    end
    local mt = getmetatable(t)
    if mt == nil then break end
    t = rawget(mt, "__index")
    n = n + 1
  end
  table.sort(out)
  return table.concat(out, " ")
end

function wxp_p(...)
  local parts = {}
  for i = 1, arg.n do table.insert(parts, tostring(arg[i])) end
  wxp_log("   " .. table.concat(parts, "  "))
end

-- Aurora-space position of a control, derived from the definition it was built from.
function wxp_pos(c)
  if c == nil then return nil end
  local ok, v = pcall(function()
    return CDefineGUIPanel:GetScreenVector(nil, c.lm_Definition)
  end)
  if ok and v then return v end
  return nil
end

-- ---------------------------------------------------------------- command channel
-- The bridge (or a test shell) drops a line of Lua into System/wxp_cmd.txt; we run it on the
-- next gameplay tick and log the result. isKeyDown never sees injected keys, so a file is the
-- only channel that actually works in both directions.

local cmd_div = 0

local function poll_cmd()
  cmd_div = cmd_div + 1
  if cmd_div < 3 then return end
  cmd_div = 0
  local f = io.open(CMD, "r")
  if f == nil then return end
  local body = f:read("*a")
  f:close()
  -- Truncate first: if os.remove is unavailable the empty file still reads as "no command".
  local w = io.open(CMD, "w")
  if w then w:close() end
  pcall(function() os.remove(CMD) end)
  if body == nil or string.len(body) < 2 then return end
  wxp_log("--- cmd: " .. body)
  local fn, err = loadstring(body)
  if fn == nil then wxp_log("!! compile: " .. tostring(err)) return end
  local ok, res = pcall(fn)
  if not ok then wxp_log("!! run: " .. tostring(res))
  elseif res ~= nil then wxp_log("=> " .. tostring(res))
  else wxp_log("=> ok") end
end

-- ---------------------------------------------------------------- mode reporting

-- Panel hotkeys are handled engine-side and never reach the Lua TogglePanel, so ask the
-- engine directly instead of reading the Lua manager's bookkeeping.
local function poll_state()
  local gi = g_GuiInGame
  -- No in-game GUI means no module: we are in the main menu, which is nothing but UI. Report it
  -- as such, otherwise the bridge stays in its gameplay layout and the sticks send WASD at a
  -- screen that has no world behind it.
  if gi == nil then
    if wxp_mode ~= "ui" then
      wxp_mode = "ui"
      if wxp_panel == "-" then wxp_panel = "MainMenu" end
      write_state()
      wxp_log("state -> mode=ui (main menu)")
    end
    return
  end
  local open = false
  local ok2, r = pcall(function() return gi:IsAnyPanelOpen() end)
  if ok2 and r then open = true end
  -- A conversation is not a "panel" to the engine, but for the pad it is very much UI.
  if not open then
    local ok3, d = pcall(function() return gi.lm_pDialogPanel and gi.lm_pDialogPanel.lm_bLowerActive end)
    if ok3 and d then open = true end
  end
  local mode = "world"
  if open then mode = "ui" end
  if mode ~= wxp_mode then
    wxp_mode = mode
    write_state()
    wxp_log("state -> mode=" .. mode)
  end
end

-- ---------------------------------------------------------------- navigation channel
-- The bridge rewrites System/wxp_nav.txt as "<seq> <intent>" on every pad event. seq restarts
-- at 1 when the bridge restarts, so compare for inequality, never for growth.

local NAV = "wxp_nav.txt"
local nav_seq, nav_div = nil, 0

local function poll_nav()
  nav_div = nav_div + 1
  if nav_div < 3 then return end
  nav_div = 0
  local f = io.open(NAV, "r")
  if f == nil then return end
  local line = f:read("*l")
  f:close()
  if line == nil then return end
  local _, _, seq, intent = string.find(line, "(%d+)%s+(%S+)")
  if seq == nil or intent == nil then return end
  if seq == nav_seq then return end
  nav_seq = seq
  if wxp_intent == nil then wxp_log("nav: " .. intent .. " (ui layer not loaded)") return end
  local ok, r = pcall(function() return wxp_intent(intent) end)
  if ok then wxp_log("nav " .. intent .. " -> " .. tostring(r))
  else wxp_log("nav " .. intent .. " !! " .. tostring(r)) end
end

-- ---------------------------------------------------------------- gameplay tick

local hb_count, hb_t0, state_t = 0, nil, nil

-- Everything the tick does lives in a global so the file can be re-run with
-- g_Lua:PlayFile("wxp_gamepad") and take effect without re-wrapping OnHeartbeat.
function wxp_heartbeat(self)
  -- The ticker panel calls this with no self; only the module's own heartbeat carries one.
  if self ~= nil then wxp_module = self end
  hb_count = hb_count + 1
  if hb_t0 == nil then
    hb_t0 = os.clock()
    wxp_log("heartbeat: first tick")
    if wxp_ui == nil and wxp_load_ui then wxp_load_ui() end
  end
  -- Combat targeting only matters once a game is running, and CGuiInGame has to exist before it
  -- can hook the enemy feed, so load it on the first tick that has one.
  if wxp_combat == nil and g_GuiInGame ~= nil and wxp_load_combat then wxp_load_combat() end
  if wxp_combat and wxp_mode == "world" then pcall(function() wxp_combat.tick() end) end
  poll_state()
  poll_nav()
  poll_cmd()
  local now = os.clock()
  if state_t == nil or now - state_t >= 1 or now < state_t then
    state_t = now
    write_state()
  end
end

local function on_module_class(class)
  wrap_when_defined(class, "OnHeartbeat", function(orig)
    return function(self, nDeltaT)
      pcall(function() wxp_heartbeat(self) end)
      return orig(self, nDeltaT)
    end
  end)
end

-- ---------------------------------------------------------------- panel manager hooks

local function on_panelmgr_class(class)
  wrap_when_defined(class, "TogglePanel", function(orig)
    return function(self, sPanel, bOn, bIgnore)
      local r = orig(self, sPanel, bOn, bIgnore)
      pcall(function()
        wxp_panelmgr = self
        wxp_log("TogglePanel " .. tostring(sPanel) .. " on=" .. tostring(bOn))
      end)
      return r
    end
  end)
  wrap_when_defined(class, "SwitchPanel", function(orig)
    return function(self, nPos, sNew)
      pcall(function()
        wxp_panelmgr = self
        wxp_log("SwitchPanel pos=" .. tostring(nPos) .. " -> " .. tostring(sNew))
      end)
      return orig(self, nPos, sNew)
    end
  end)
end

local function on_guiingame_class(class)
  wrap_when_defined(class, "TogglePanel", function(orig)
    return function(self, sPanel, bOn)
      pcall(function() wxp_log("CGuiInGame:TogglePanel " .. tostring(sPanel) .. " on=" .. tostring(bOn)) end)
      return orig(self, sPanel, bOn)
    end
  end)
end

-- ---------------------------------------------------------------- main menu autoload (test aid)

-- The module heartbeat only exists once a game is loaded, so at the main menu nothing drives the
-- runtime and the pad has nothing to talk to. A panel that registers for per-frame updates ticks
-- everywhere, menu included; it carries no texture and no controls, so it draws nothing.
function wxp_make_ticker()
  if wxp_ticker then return true end
  if CLuaPanel == nil or defineGUIPanel == nil then return false end
  local ok2, err2 = pcall(function()
    local C = makeClass(CLuaPanel)
    function C:new()
      local o = C:create()
      defineGUIPanel({Name = "WxpTicker", AutoToggleDisabled = true,
                      Position = {X = 0, Y = 0, Z = 0}}, o)
      g_Lua:RegisterHandler(o.lm_pPanel, "OnUpdate")
      o.lm_pPanel:RegisterUpdate()
      return o
    end
    function C:OnUpdate(deltaT)
      pcall(function() wxp_heartbeat(nil) end)
    end
    wxp_ticker = C:new()
  end)
  if not ok2 then wxp_log("ticker failed: " .. tostring(err2)) return false end
  wxp_log("ticker: per-frame update registered")
  return true
end

local function on_mainmenu_class(class)
  wrap_when_defined(class, "OnPostAttachmentInitialize", function(orig)
    return function(self)
      local r = orig(self)
      pcall(function()
        wxp_mainmenu = self
        wxp_make_ticker()
        if wxp_ui == nil and wxp_load_ui then wxp_load_ui() end
        local f = io.open("wxp_autoload.txt", "r")
        if not f then return end
        f:close()
        os.remove("wxp_autoload.txt")
        wxp_log("autoload: main menu ready, trying QuickLoad")
        local lss = GetLoadSaveSystem()
        if lss == nil then wxp_log("autoload: no load/save system") return end
        lss:QuickLoad()
        wxp_log("autoload: QuickLoad returned")
      end)
      return r
    end
  end)
end

-- ---------------------------------------------------------------- arming

-- The focus layer needs the GUI classes, which do not exist yet at debug.luc time; loading it
-- is deferred to the first gameplay tick.
function wxp_load_settings()
  local ok2, err2 = pcall(function() g_Lua:PlayFile("wxp_settings") end)
  if not ok2 then wxp_log("settings load failed: " .. tostring(err2)) end
end

function wxp_load_wheel()
  local ok2, err2 = pcall(function() g_Lua:PlayFile("wxp_signwheel") end)
  if not ok2 then wxp_log("wheel load failed: " .. tostring(err2)) end
  return wxp_wheel ~= nil
end

function wxp_load_ui()
  local ok2, err2 = pcall(function() g_Lua:PlayFile("wxp_ui") end)
  if not ok2 then wxp_log("ui load failed: " .. tostring(err2)) end
  return wxp_ui ~= nil
end

function wxp_load_combat()
  local ok2, err2 = pcall(function() g_Lua:PlayFile("wxp_combat") end)
  if not ok2 then wxp_log("combat load failed: " .. tostring(err2)) end
  return wxp_combat ~= nil
end

pcall(log_rotate)
do
  -- The engine formats time in its own zone, which need not match the one the bridge log uses.
  -- The epoch is the same number on both sides, so print it and the two logs can be aligned
  -- exactly instead of approximately.
  local okt, epoch = pcall(function() return os.time() end)
  wxp_log("==== WitcherPadBridge Lua layer " .. VERSION
          .. "   epoch " .. (okt and tostring(epoch) or "?") .. " ====")
end

local ok, err = pcall(function()
  if wxp_armed then
    wxp_log("=== wxp_gamepad reloaded (hooks already in place) ===")
    return
  end
  wxp_armed = true
  local env = getfenv()
  local watch = {
    CGuiInGame             = on_guiingame_class,
    CGuiInGamePanelManager = on_panelmgr_class,
    CNWCModule             = on_module_class,
    CMainMenuPanel         = on_mainmenu_class,
    -- Last class defined in hwdepsettings' Gameplay block: by the time it appears the setting
    -- base classes and RegisterLuaSetting all exist, so our own settings can join the list.
    CInvertMouseSetting    = function() wxp_load_settings() end
  }
  -- Each handler is isolated: a failure in one integration must not stop the others from
  -- installing, and least of all the gameplay tick that carries the whole runtime.
  local function fire(name, fn, value)
    local okf, errf = pcall(function() fn(value) end)
    if not okf then wxp_log("hook " .. tostring(name) .. " failed: " .. tostring(errf)) end
  end

  local mt = getmetatable(env)
  if mt == nil then mt = {} end
  local prev = mt.__newindex
  mt.__newindex = function(t, k, v)
    if prev then prev(t, k, v) else rawset(t, k, v) end
    local fn = watch[k]
    if fn then
      watch[k] = nil
      wxp_log("global appeared: " .. tostring(k))
      fire(k, fn, v)
    end
  end
  setmetatable(env, mt)
  wxp_log("=== wxp_gamepad armed (v12) ===")
  -- What the layer can see of its own installation. "Nothing happens" is nearly always one of
  -- these three: no wxp_ui, no write access, or a stale debug.luc that never called us.
  local okd, d = pcall(function() return os.date("%Y-%m-%d %H:%M:%S") end)
  wxp_log("    date " .. (okd and tostring(d) or "unknown") .. "   log " .. LOG)
  -- Both load lazily on the first gameplay tick, so "false" here is normal; what matters is
  -- that they turn true later. If they never do, the .luc files are missing or failed to load.
  wxp_log("    modules at arm time: ui=" .. tostring(wxp_ui ~= nil)
          .. " combat=" .. tostring(wxp_combat ~= nil) .. " (both load on the first tick)")
  -- Snapshot first: the handlers below assign globals, which re-enters __newindex.
  local present = {}
  for name, fn in pairs(watch) do
    if type(env[name]) == "table" then table.insert(present, name) end
  end
  for i = 1, table.getn(present) do
    local name = present[i]
    local fn = watch[name]
    watch[name] = nil
    wxp_log("global already present: " .. name)
    fire(name, fn, env[name])
  end
  write_state()
end)

if not ok then wxp_log("ERROR: " .. tostring(err)) end

