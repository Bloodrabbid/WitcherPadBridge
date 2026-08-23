-- WitcherPadBridge :: on-screen sign wheel.
--
-- The bridge already makes the signs selectable (hold LB, flick the right stick, it injects the
-- 1..5 keys the engine binds signs to). This adds the thing the player actually looks at: five
-- icons in a ring with the aimed one lit, driven by the signmenu:/sign: intents.
--
-- The panel is built from a definition table exactly the way the shipped gui_defs_* files do it,
-- reusing the HUD's own sign atlas (ui_hud_signs, registered by gui_defs_hud_v2 under the "RMB"
-- id), so nothing new has to be shipped and the icons match the rest of the interface.

wxp_wheel = {}
local W = wxp_wheel

-- Clockwise from "up". The index is also the engine's sign key (1..5), which is what the bridge
-- reports, so the two never need translating.
local SIGNS = {"Aard", "Quen", "Yrden", "Igni", "Axi"}
local RADIUS = 190      -- in the 1280x1024 "perfect resolution" space definitions are authored in
local ICON   = 96

-- Columns of the HUD sign atlas, measured on screen: 0 is the resting icon, 1 a slightly brighter
-- mouse-over, 2 the bright yellow "selected" art, 3 the grey unavailable one. Only one is ever
-- shown at a time -- stacking them blends instead of replacing.
local L_READY, L_AIMED, L_UNKNOWN = 0, 2, 3

W.panel   = nil
W.shown   = false
W.sector  = 0
W.known   = nil

local function log(s) if wxp_log then wxp_log("wheel: " .. tostring(s)) end end

local function layer(name, sign, idx)
  return {
    Name = name,
    Texture = g_GuiLayoutManager:GetTexCoord("RMB", sign, idx),
    Animations = CDefineGUIPanel.m_DefaultVanishableLayer
  }
end

local function build_definition()
  local controls = {}
  for i = 1, table.getn(SIGNS) do
    local name = SIGNS[i]
    local a = (i - 1) * 2 * math.pi / table.getn(SIGNS)
    -- A control's anchor is its corner, so shift by half an icon to sit on the ring.
    local x = RADIUS * math.sin(a) - ICON / 2
    local y = RADIUS * math.cos(a) - ICON / 2
    controls[name] = {
      Type = "Default",
      IgnoreHitCheck = true,
      Position = {X = x, Y = y, Z = 3, PerfRes = true},
      Size = {X = ICON, Y = ICON, PerfRes = true},
      TextureLayers = {
        layer("MainLayer", name, L_UNKNOWN),
        layer("Ready", name, L_READY),
        layer("Aimed", name, L_AIMED)
      }
    }
  end
  return {
    Name = "WxpSignWheel",
    AutoToggleDisabled = true,
    Position = {OrientCenterScreen = {X = 0, Y = 0, Z = 60}},
    Controls = controls
  }
end

-- The HUD's own sign strip is the authority on what is selected and what Geralt even knows.
local function rmb()
  return g_GuiInGame and g_GuiInGame.lm_pInGameRMBList
end

-- Which signs Geralt actually has, worked out the same way gui_new_rmblist does: ask the player
-- for its known spells and let spells.2da map each id to a sign name. The strip's own cached
-- count is not usable here -- it stays 0 until the strip updates, which never happens in a save
-- where Geralt knows nothing. nil means "could not tell" and draws every spoke as available.
local function known_set()
  local r = rmb()
  if r == nil or r.lm_pSpells2DA == nil or g_Player == nil then return nil end
  local ok, n = pcall(function() return g_Player:GetCreatureProxy():GetNumberKnownSpells() end)
  if not ok or type(n) ~= "number" then return nil end
  local set = {}
  for i = 1, n do
    local ok2, t = pcall(function()
      local id = g_Player:GetCreatureProxy():GetKnownSpell(i - 1)
      -- Subtype 1 is the alternate (group) cast of a sign, not a sign of its own.
      local _, _, sub = r.lm_pSpells2DA:GetCExoStringEntry(id, "SpellSubtype", 0)
      if 0 + sub == 1 then return nil end
      local _, _, s = r.lm_pSpells2DA:GetCExoStringEntry(id, "SpellType", 0)
      return s
    end)
    if ok2 and type(t) == "string" then set[t] = true end
  end
  return set
end

local function state_of(i)
  if W.known ~= nil and not W.known[SIGNS[i]] then return "MainLayer" end
  if i == W.sector then return "Aimed" end
  return "Ready"
end

local function paint()
  for i = 1, table.getn(SIGNS) do
    local c = W.panel.m_Controls[SIGNS[i]]
    if c then
      local want = state_of(i)
      c:PlayAnimation("MainLayer", want == "MainLayer" and "Show" or "Hide", false, 1)
      c:PlayAnimation("Ready", want == "Ready" and "Show" or "Hide", false, 1)
      c:PlayAnimation("Aimed", want == "Aimed" and "Show" or "Hide", false, 1)
    end
  end
end

-- Built on first use: at script load time neither the layout manager's atlas nor g_GuiInGame
-- exists yet.
function W.create()
  if W.panel then return true end
  if g_GuiLayoutManager == nil or CDefineGUIPanel == nil or defineGUIPanel == nil then return false end
  local ok, err = pcall(function()
    W.panel = defineGUIPanel(build_definition())
  end)
  if not ok or W.panel == nil then
    log("create failed: " .. tostring(err))
    W.panel = nil
    return false
  end
  W.sector = 0
  W.known = nil
  paint()
  W.panel:ToggleOff()
  log("panel created")
  return true
end

function W.highlight(n)
  if W.panel == nil then return end
  W.sector = n
  paint()
end

function W.current()
  local r = rmb()
  if r and r.lm_nLastSelected and r.lm_nLastSelected > 0 then return r.lm_nLastSelected end
  return 0
end

-- Selecting through the panel rather than through an injected 1..5 key keeps the engine's own
-- rules (sign known, area not safe, not mid-cast) in force, and the HUD updates with us.
function W.select(n)
  local r = rmb()
  if r == nil or n == nil or n < 1 then return false end
  local ok, res = pcall(function() return r:ToggleSpell(n) end)
  return ok and res == true
end

function W.show(bShow)
  if not W.create() then return "no wheel" end
  if bShow == W.shown then return "wheel " .. tostring(W.shown) end
  W.shown = bShow
  if bShow then
    W.known = known_set()
    W.panel:UnToggleOff()
    W.highlight(W.current())
  else
    W.panel:ToggleOff()
    W.highlight(0)
  end
  return "wheel " .. tostring(bShow)
end

log("sign wheel loaded")
