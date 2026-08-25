-- WitcherPadBridge :: gamepad focus navigation for the in-game panels.
--
-- The engine drives its UI entirely from the mouse: hit-testing calls OnMouseEnter/OnMouseLeave
-- on a control and a click calls OnLMouseDown/OnLMouseUp (or OnDoubleClick for item slots).
-- Those are plain Lua methods, so a gamepad focus ring can call them directly -- no cursor
-- geometry, no synthetic clicks, and the game's own highlight/tooltip/sound reactions come
-- along for free.
--
-- Layout comes from control.lm_Definition run through CDefineGUIPanel:GetScreenVector, which
-- yields Aurora units (10.24 x 7.68, y growing upwards). Every in-game sub-panel sits at
-- model position (0,0,z), so those coordinates are directly comparable across sub-panels.

wxp_ui = {}
local U = wxp_ui

U.sections = {}    -- ordered { name = string, items = { {c=control, x=, y=} } }
U.si       = 0     -- index of the active section
U.focus    = nil   -- focused control
U.panel    = "-"   -- name of the panel the sections were built from

local SLOT_OCCUPIED = 2   -- DragSlotState.Occupied
local BTN_DISABLED  = 0   -- StandardButtonState.Disabled

local function log(s) if wxp_log then wxp_log("ui: " .. tostring(s)) end end

-- ---------------------------------------------------------------- geometry

-- lm_Definition is authoritative where it exists; controls the game builds at runtime (the
-- settings rows, for one) have none, so fall back to the model's own attach position.
local function pos_of(c)
  if c.lm_Definition then
    local ok, v = pcall(function()
      return CDefineGUIPanel:GetScreenVector(nil, c.lm_Definition)
    end)
    if ok and v and (v.x ~= 0 or v.y ~= 0) then return v.x, v.y end
  end
  local ok2, m = pcall(function() return c.m_pModel:GetPosition() end)
  if ok2 and m then return m.x, m.y end
  return nil, nil
end

-- The engine hides a control by detaching it from its panel (RemoveFromPanel) and afterwards
-- nothing about the control says so: not the model's visibility or alpha, not its status, not
-- the panel's control table. A screen like the diary keeps two full sets of filter buttons on
-- top of each other and detaches the set that does not belong to the open tab -- collect those
-- and half the focus ring lands on things the player cannot see. Wrapping the two calls on the
-- control's own class is the only way to know; the wrapper is a pass-through that just records
-- the fact.
-- Bumped whenever the wrapper below changes: a class keeps ours forever, including across a
-- reload of this file, so an old one has to be peeled off before a new one goes on. Clearing
-- our own entry uncovers the engine's method again -- it was only ever shadowed, never lost.
local WRAP = 3

local function watch_visibility(c)
  local mt = getmetatable(c)
  local cls = mt and mt.__objectClass
  if cls == nil or rawget(cls, "wxp_wrapped") == WRAP then return end
  rawset(cls, "RemoveFromPanel", nil)
  rawset(cls, "ReAddToPanel", nil)
  local remove, readd = c.RemoveFromPanel, c.ReAddToPanel
  if type(remove) ~= "function" or type(readd) ~= "function" then return end
  rawset(cls, "wxp_wrapped", WRAP)
  -- Both take no arguments; tolua rejects the call outright if extra nils are passed along.
  -- Only ever tag a Lua-side control; a tolua userdata rejects unknown fields outright.
  cls.RemoveFromPanel = function(self)
    if type(self) == "table" then self.wxp_offpanel = true end
    return remove(self)
  end
  cls.ReAddToPanel = function(self)
    if type(self) == "table" then self.wxp_offpanel = nil end
    return readd(self)
  end
end

local function on_panel(c)
  return c.wxp_offpanel ~= true
end

local function add(list, c)
  if c == nil or type(c) ~= "table" then return end
  watch_visibility(c)
  if not on_panel(c) then return end
  local x, y = pos_of(c)
  if x == nil then return end
  -- Controls parked at the origin were never laid out; they are not on screen.
  if x == 0 and y == 0 then return end
  table.insert(list, {c = c, x = x, y = y})
end

local function seg(name, list, listctl, scroll)
  if table.getn(list) > 0 then
    table.insert(U.sections, {name = name, items = list, list = listctl, scroll = scroll})
  end
end

-- Controls of a panel object, sorted so the focus order is stable between rebuilds.
local function panel_controls(obj)
  if obj == nil then return nil end
  local p = obj.lm_pPanel
  if p == nil or type(p.m_Controls) ~= "table" then return nil end
  return p.m_Controls
end

-- ---------------------------------------------------------------- tab strips

-- A CTextTabControl is a control, not a panel: it sits in the screen's m_Controls and owns
-- lm_tTabs, a name -> {Position, Button, Func} map. Its tab buttons live on a panel of its own,
-- so the generic collector never sees them -- they need a section built by hand. The diary
-- carries two strips side by side (four tabs each), the map one.
local function tab_strips(obj)
  local out, names, from = {}, {}, {}
  local cs = panel_controls(obj)
  if cs then
    for k, v in pairs(cs) do
      if type(v) == "table" and type(v.lm_tTabs) == "table" then
        table.insert(names, k) from[k] = v
      end
    end
  end
  -- The map keeps its strip in a field of its own (lm_pTabs) rather than among the panel's
  -- controls, so look there too.
  for k, v in pairs(obj) do
    if type(v) == "table" and type(v.lm_tTabs) == "table" and from[k] == nil then
      table.insert(names, k) from[k] = v
    end
  end
  table.sort(names)
  for i = 1, table.getn(names) do table.insert(out, from[names[i]]) end
  return out
end

-- Every tab of every strip on one screen, in reading order, as a single list.
local function all_tabs(obj)
  local strips = tab_strips(obj)
  local out = {}
  for i = 1, table.getn(strips) do
    local strip = strips[i]
    local rows = {}
    for name, t in pairs(strip.lm_tTabs) do
      if type(t) == "table" then
        table.insert(rows, {strip = strip, name = name, pos = t.Position or 0, tab = t})
      end
    end
    table.sort(rows, function(a, b) return a.pos < b.pos end)
    for j = 1, table.getn(rows) do table.insert(out, rows[j]) end
  end
  return out
end

-- Tab buttons are attached inside the strip's own panel, so their lm_Definition is relative to
-- it; the model position is already absolute and is what the rest of the ring is measured in.
local function tab_pos(btn, strip)
  if btn then
    local ok, m = pcall(function() return btn.m_pModel:GetPosition() end)
    if ok and m and (m.x ~= 0 or m.y ~= 0) then return m.x, m.y end
  end
  if strip then
    local x, y = pos_of(strip)
    if x then return x, y end
  end
  if btn then return pos_of(btn) end
  return nil, nil
end

-- Tab buttons get their own section; a screen that also lists them among its own controls
-- (the diary does, for one of its two strips) would otherwise offer each tab twice.
local SKIP = {}

local function mark_tab_buttons(obj)
  SKIP = {}
  local rows = all_tabs(obj)
  for i = 1, table.getn(rows) do
    local b = rows[i].tab.Button
    if b then SKIP[b] = true end
  end
end

local function build_tabs(obj, label)
  local rows = all_tabs(obj)
  local list = {}
  for i = 1, table.getn(rows) do
    local strip, name, tab = rows[i].strip, rows[i].name, rows[i].tab
    local btn = tab.Button
    local x, y = tab_pos(btn, strip)
    if x then
      table.insert(list, {
        c = btn or strip, x = x, y = y, tabname = name, tabkey = name,
        hi = function(on)
          if on then strip:OnTabMouseEnter(name) else strip:OnTabMouseLeave(name) end
        end,
        act = function() strip:OnTabMouseClick(name) end
      })
    end
  end
  seg(label .. ".tabs", list)
end

-- ---------------------------------------------------------------- section builders

-- Equipment slots give the focus layer almost nothing to work with: SelectButton, HilightSlot
-- and DimmButton are not in this class's binding at all (checked at runtime -- they come back
-- nil), and OnMouseEnter lights only a slot that holds an item. Every slot in the prologue is
-- empty and reports m_Status 0, so focus was invisible across the whole panel: a pixel diff
-- between two different focused slots came back empty. That is what read as "меню снаряжения
-- странно работает" -- the stick moved and the screen did not.
-- SetScale is the one lever the binding does expose, so the focused slot grows instead.
-- Подсказка рисуется у КУРСОРА, а в режиме кольца фокуса курсор припаркован в углу и не
-- двигается -- поэтому она встаёт на одно и то же место и закрывает собой то, что под ним.
-- Сдвинуть её в принципе можно -- CGuiMan:ShowTooltip принимает точку, а панель считает от
-- неё и лишь прижимает к краю экрана, -- но одно фиксированное место хорошо ровно на одном
-- экране: в инвентаре свободен низ, в дневнике он занят. Поэтому сначала простое и верное:
-- подсказка живёт заданное число секунд после появления и уходит. 0 -- не гасить.
local TIP_SECS_DEFAULT = 4

function U.tip(c)
  pcall(function() c:OnTooltip() end)
  U.tip_at = os.clock()
end

local function tip_secs()
  local v = TIP_SECS_DEFAULT
  pcall(function()
    local o = wxp_settings_by_key and wxp_settings_by_key.TooltipHide
    if o then v = o:GetValue() end
  end)
  return v
end

-- Зовётся с каждого heartbeat, пока открыта панель.
function U.tick()
  if U.tip_at == nil then return end
  local secs = tip_secs()
  if secs <= 0 then return end
  if os.clock() - U.tip_at < secs then return end
  U.tip_at = nil
  pcall(function() g_pGuiMan:HideTooltip() end)
  pcall(function() g_pGuiMan:HideTooltipText() end)
end

local SLOT_SCALE = 1.35
-- Map markers are small icons on a busy bitmap, so they need more than a slot does to read.
local MARKER_SCALE = 1.6
local function slot_focus(list)
  for i = 1, table.getn(list) do
    local e = list[i]
    local c = e.c
    -- Reset on every rebuild: a panel closed while a slot was focused would otherwise keep it
    -- enlarged for the rest of the session.
    pcall(function() c:SetScale(1.0) end)
    e.hi = function(on)
      pcall(function() c:SetScale(on and SLOT_SCALE or 1.0) end)
      pcall(function() if on then c:OnMouseEnter() else c:OnMouseLeave() end end)
      if on then U.tip(c) end
    end
  end
end

local function build_inventory(inv)
  local eq = {}
  local ec = panel_controls(inv.lm_pEquipmentPanel)
  if ec then
    local order = {"BackSword", "BeltSword", "SilverSword", "SmallWeaponOne", "SmallWeaponTwo",
                   "Armour", "Amulet", "RingLeft", "RingRight", "Trophy",
                   "Elixir1", "Elixir2", "Elixir3"}
    for i = 1, table.getn(order) do add(eq, ec[order[i]]) end
  end
  slot_focus(eq)
  seg("equipment", eq)

  local rep = inv.lm_pRepositoryPanel
  local rc  = panel_controls(rep)
  if rep and rc then
    -- Bag: only slots that actually hold something, otherwise the ring is 84 empty cells.
    local bag = {}
    if type(rep.lm_tRepository) == "table" then
      for x, col in pairs(rep.lm_tRepository) do
        if type(col) == "table" then
          for y, e in pairs(col) do
            if type(e) == "table" and e.Item and e.Control then add(bag, e.Control) end
          end
        end
      end
    end
    slot_focus(bag)
    seg("bag", bag)

    local quest = {}
    local nq = rep.lm_nQuestControls or 0
    for i = 1, nq do
      local c = rc["QuestSlot" .. i]
      if c and c.m_Status == SLOT_OCCUPIED then add(quest, c) end
    end
    slot_focus(quest)
    seg("quest", quest)

    if rep.lm_bFiltersVisible then
      local f = {}
      add(f, rc.FilterAll)
      for i = 0, 6 do add(f, rc["Filter" .. i]) end
      add(f, rc.AutoSortSmallBag)
      add(f, rc.AutoSortAlchemyBag)
      seg("filters", f)
    end
  end

  local gc = nil
  if inv.lm_pGroundPanel and inv.lm_pGroundPanel.lm_bActive then
    gc = panel_controls(inv.lm_pGroundPanel)
  end
  if gc then
    local g = {}
    for k, c in pairs(gc) do
      if type(c) == "table" and c.m_Status == SLOT_OCCUPIED then add(g, c) end
    end
    slot_focus(g)
    seg("ground", g)
  end

  local tc = nil
  if inv.lm_pTransferPanel and inv.lm_pTransferPanel.lm_bActive then
    tc = panel_controls(inv.lm_pTransferPanel)
  end
  if tc then
    local t = {}
    for k, c in pairs(tc) do
      if type(c) == "table" and c.m_Status == SLOT_OCCUPIED then add(t, c) end
    end
    add(t, tc.TransferAllButton)
    slot_focus(t)
    seg("container", t)
  end
end

-- Live controls of one panel object: buttons that are not disabled, item slots that hold
-- something, and anything else that carries a click handler of its own.
-- A CListControl owns its rows; they live in a scrolled content panel, so their coordinates
-- are meaningless for spatial navigation. Give every list a section of its own, ordered by
-- row index, and step through it linearly.
local function collect_list(c, label)
  local items = {}
  local n = 0
  for i, v in pairs(c.lm_tListItems) do
    if type(v) == "table" and v.Button and v.Enabled ~= false then
      n = n + 1
      table.insert(items, {c = v.Button, x = 0, y = -i, idx = i})
    end
  end
  if n == 0 then return end
  table.sort(items, function(a, b) return a.idx < b.idx end)
  seg(label, items, c)
end

local function collect_from(obj, out, label)
  local cs = panel_controls(obj)
  if cs == nil then return end
  local names = {}
  for k, v in pairs(cs) do table.insert(names, k) end
  table.sort(names)
  for i = 1, table.getn(names) do
    local c = cs[names[i]]
    if type(c) == "table" and not SKIP[c] then
      local st = c.m_Status
      if type(c.lm_tListItems) == "table" and c.lm_pScrollView then
        collect_list(c, label .. ":" .. tostring(c.m_Name))
      elseif c.m_ButtonType ~= nil then
        if st ~= BTN_DISABLED then add(out, c) end
      elseif st == SLOT_OCCUPIED then
        add(out, c)
      elseif c.OnClick or c.OnDoubleClick then
        add(out, c)
      end
    end
  end
end

-- Most in-game screens are a shell panel plus a few sub-panels held in lm_p* fields (the
-- character screen keeps its stats and its talent tree that way). Each sub-panel becomes its
-- own section, so the shoulder buttons walk between the parts of a screen.
local function sub_panels(obj)
  local out, names = {}, {}
  -- Controls also carry an lm_pPanel back-pointer, so require a *different* panel and the
  -- absence of m_Name, which only controls have.
  for k, v in pairs(obj) do
    -- rawequal, not ~=: tolua's __eq rejects mismatched operand types outright.
    if type(v) == "table" and k ~= "lm_pPanel" and v.m_Name == nil
       and v.lm_pPanel and type(v.lm_pPanel) == "userdata"
       and not rawequal(v.lm_pPanel, obj.lm_pPanel) then
      table.insert(names, k)
    end
  end
  table.sort(names)
  for i = 1, table.getn(names) do
    table.insert(out, {key = names[i], obj = obj[names[i]]})
  end
  return out
end

-- The options screen builds its rows at runtime onto a per-tab panel held in lm_SettingSets.
-- A checkbox is toggled by clicking it; a slider is a CGuiSlider whose position the panel
-- reads back in OnLMouseUp, so left/right moves the thumb and then replays that handler.
-- The options screen's five category buttons are ordinary buttons, but to the player they are
-- the screen's sections -- so give them the same "<panel>.tabs" section a real tab strip gets
-- and the shoulder buttons walk them. Declared in screen order, not sorted.
local SETTINGS_TABS = {"GameplayButton", "GraphicsButton", "SoundButton",
                       "ControlsButton", "AdvancedButton"}
-- The options screen and the key-binding screen carry the same five buttons under their own
-- prefixes; "Управление" swaps one screen for the other, so both need them walkable.
local SETTINGS_PREFIX = {"Settings", "Controls"}

-- Which prefix this screen uses, or nil if it is not one of the two.
local function settings_prefix(sp)
  local cs = panel_controls(sp)
  if cs == nil then return nil end
  for i = 1, table.getn(SETTINGS_PREFIX) do
    local p = SETTINGS_PREFIX[i]
    if type(cs[p .. SETTINGS_TABS[1]]) == "table" then return p, cs end
  end
  return nil
end

local function mark_settings_tabs(sp)
  local p, cs = settings_prefix(sp)
  if p == nil then return end
  for i = 1, table.getn(SETTINGS_TABS) do
    local c = cs[p .. SETTINGS_TABS[i]]
    if type(c) == "table" then SKIP[c] = true end
  end
end

local function build_settings_tabs(sp, label)
  local p, cs = settings_prefix(sp)
  if p == nil then return end
  local list = {}
  for i = 1, table.getn(SETTINGS_TABS) do
    local name = p .. SETTINGS_TABS[i]
    local c = cs[name]
    if type(c) == "table" and on_panel(c) then
      local x, y = pos_of(c)
      if x then
        local key = SETTINGS_TABS[i]
        table.insert(list, {c = c, x = x, y = y, tabname = name, tabkey = key,
                            sel = function()
                              local cur = sp.lm_pCurrentButton
                              if cur ~= nil then return rawequal(c, cur) end
                              -- The key-binding screen keeps no current button of its own: it
                              -- *is* the Controls category, and that is what is selected.
                              return key == "ControlsButton"
                            end})
      end
    end
  end
  seg(label .. ".tabs", list)
end

local function build_settings(sp, label)
  local set = sp.lm_SettingSets and sp.lm_sType and sp.lm_SettingSets[sp.lm_sType]
  local pnl = set and set.Panel
  if pnl == nil or type(pnl.m_Controls) ~= "table" then return end
  local list, names = {}, {}
  for k, v in pairs(pnl.m_Controls) do table.insert(names, k) end
  table.sort(names)
  for i = 1, table.getn(names) do
    local c = pnl.m_Controls[names[i]]
    -- Sliders (continuous and discrete settings) are CGuiSlider userdata, not Lua tables;
    -- filtering on "table" here silently dropped resolution, gamma and every volume row.
    local kind = type(c)
    if (kind == "table" or kind == "userdata") and c.lm_sType == "setting" then
      -- Rows are all attached to the same content panel, so read the model position for every
      -- kind: a checkbox also carries an lm_Definition, and mixing the two spaces put it in the
      -- wrong place in the top-to-bottom order.
      local x, y
      local okm, m = pcall(function() return c.m_pModel:GetPosition() end)
      if okm and m and (m.x ~= 0 or m.y ~= 0) then x, y = m.x, m.y else x, y = pos_of(c) end
      -- AddSetting numbers the rows as it lays them out top to bottom, and the number is in the
      -- control's name. That ordering is always available; the coordinates are not -- a slider
      -- reports (0,0) until the engine has attached it, which has not happened yet on the tab
      -- that was just opened.
      local _, _, ord = string.find(names[i], "Setting(%d+)")
      ord = tonumber(ord)
      if x then
        local ctl = c
        local e = {c = ctl, x = x, y = y}
        if ctl.lm_Value ~= nil then
          -- checkbox
          e.act = function() ctl:OnLMouseDown() ctl:OnLMouseUp() end
          e.adj = e.act
        else
          e.adj = function(delta)
            local range = ctl:GetScrollRange()
            local pos = ctl:GetScrollPos() + delta
            if pos < 0 then pos = 0 end
            if pos > range - 1 then pos = range - 1 end
            ctl:SetScrollPos(pos)
            sp:OnLMouseUp(ctl)
          end
        end
        -- The rows give no visual feedback of their own on mouse-over, so tint the row's own
        -- labels (every row kind keeps them in lm_TextControls). Gold reads as "here" against
        -- the white of an enabled row and the grey of a disabled one -- the engine's own
        -- palette is greyscale, so brightening alone would be invisible.
        local labels = ctl.lm_TextControls
        if type(labels) == "table" and table.getn(labels) > 0 then
          e.hi = function(on)
            local enabled = true
            local oke, r = pcall(function() return ctl.lm_Setting:IsEnabled() end)
            if oke and r == false then enabled = false end
            for k = 1, table.getn(labels) do
              local t = labels[k]
              pcall(function()
                if on then t:ChangeColor(1, 0.8, 0.3)
                elseif enabled then t:ChangeColor(1, 1, 1)
                else t:ChangeColor(0.5, 0.5, 0.5) end
              end)
            end
            pcall(function() if on then ctl:OnMouseEnter() else ctl:OnMouseLeave() end end)
            if on then U.tip(ctl) end
          end
        end
        e.ord = ord
        table.insert(list, e)
      end
    end
  end
  -- Top to bottom. Array order is what the scroll helper turns into a scrollbar position and
  -- what up/down steps through, so it has to match what the player sees.
  table.sort(list, function(a, b)
    if a.ord and b.ord and a.ord ~= b.ord then return a.ord < b.ord end
    return a.y > b.y
  end)
  build_settings_tabs(sp, label)
  seg(label .. ".rows", list, nil, sp.lm_pScrollView)
  -- The rows live on the scroll view's content panel, so their coordinates are in a space of
  -- their own and cannot be compared with the screen's buttons. Step them by index like a list
  -- and let the scroll view stand in for the whole block when leaving it.
  local sec = U.sections[table.getn(U.sections)]
  if sec and sec.name == label .. ".rows" then
    sec.rows = true
    local ax, ay = pos_of(sp.lm_pScrollView)
    if ax then sec.ax, sec.ay = ax, ay end
  end
end

-- The key-binding screen builds its rows at runtime onto a scroll view's content panel rather
-- than onto the screen, and keeps them in lm_pItems in layout order -- two cells per action, the
-- main binding and the alternate. The generic collector walks a panel's own m_Controls, so it
-- never saw a single one of them: the pad could reach the five category buttons at the top and
-- the three at the bottom, and nothing in between. That is what "не даёт крестиком менять" was.
local function build_bindings(cp, label)
  local items = cp.lm_pItems
  if type(items) ~= "table" then return end
  local list, row, lasty = {}, 0, nil
  for i = 1, table.getn(items) do
    local it = items[i]
    local ctl = it.Control
    local x, y
    if ctl ~= nil then
      local okm, m = pcall(function() return ctl.m_pModel:GetPosition() end)
      if okm and m and (m.x ~= 0 or m.y ~= 0) then x, y = m.x, m.y else x, y = pos_of(ctl) end
    end
    if x then
      -- PostInitialize lays the rows out top to bottom, so a change in y is a new line. The
      -- line number is what the scroll bar is driven by; the two cells on it share it.
      if lasty == nil or math.abs(y - lasty) > 0.01 then row = row + 1 lasty = y end
      local e = {c = ctl, x = x, y = y, row = row}

      -- Waiting for a key, as opposed to waiting for the confirmation dialog that clearing a
      -- binding raises: lm_bKeyCaught is how the panel itself tells those apart, and stepping
      -- on the second one would cancel the very thing the player is about to confirm.
      local function armed()
        return cp.lm_pActiveItem ~= nil and rawequal(cp.lm_pActiveItem, it)
               and cp.lm_bKeyCaught == false
      end
      local function disarm()
        if not armed() then return false end
        pcall(function() cp:CancelBinding() end)
        pcall(function() g_pGuiMan:SetDoKeyBindCapture(false) end)
        return true
      end

      -- Selecting a cell arms the engine's own key capture, exactly as a mouse click does, so
      -- the key still has to come from the keyboard: a pad has no letters to offer, and this
      -- screen binds engine key ids, not pad buttons. Reading the list and clearing a binding
      -- are the parts that are actually pad work, and those now are.
      e.act = function() cp:OnButtonClick(it.Name) end
      -- Input id 10 is what the capture treats as "delete this binding". Going through it
      -- rather than calling RemoveBinding directly means the player gets the same confirmation
      -- the mouse would raise -- and that popup is one the focus layer already answers.
      e.alt = function()
        cp:OnButtonClick(it.Name)
        cp:BindControl(10)
      end
      e.esc = disarm
      e.hi = function(on)
        -- Stepping off a cell that is still waiting would leave the engine listening on behalf
        -- of a row the player has already left.
        if not on then disarm() end
        pcall(function() if on then ctl:OnMouseEnter() else ctl:OnMouseLeave() end end)
      end
      table.insert(list, e)
    end
  end
  seg(label .. ".bindings", list, nil, cp.lm_pScrollView)
  local sec = U.sections[table.getn(U.sections)]
  if sec and sec.name == label .. ".bindings" then
    sec.nrows = row
    -- Two columns, so left/right has to mean "the other binding for this action" -- which is
    -- coordinate stepping, not index stepping. But the coordinates are the content panel's, so
    -- the section is a band to everything outside it and is entered through this anchor.
    sec.band = true
    local ax, ay = pos_of(cp.lm_pScrollView)
    if ax then sec.ax, sec.ay = ax, ay end
  end
end

-- The character screen's left column is a set of plain models, not buttons: the game wires
-- them up through g_GuiLayoutManager button actions, and picking one means calling
-- SetTraitActive on the hero panel.
local TRAITS = {"Strength", "Dexterity", "Endurance", "Intelligence",
                "Aard", "Axi", "Igni", "Yrden", "Quen",
                "SteelStrong", "SteelFast", "SteelGroup",
                "SilverStrong", "SilverFast", "SilverGroup"}

local function build_hero_traits(hero)
  local tp = hero.lm_pTraitsPanel
  local cs = panel_controls(tp)
  if cs == nil then return end
  local list = {}
  for i = 1, table.getn(TRAITS) do
    local name = TRAITS[i]
    local c = cs["Label" .. name]
    if c then
      local x, y = pos_of(c)
      if x then
        local trait = name
        table.insert(list, {
          c = c, x = x, y = y,
          hi = function(on)
            if on then tp:SetTraitSelected(trait) else tp:DeselectTrait(trait) end
          end,
          act = function() hero:SetTraitActive(trait) end
        })
      end
    end
  end
  seg("traits", list)
end

-- The diary stacks one filter strip per tab in the same spot plus a set of quest-only
-- controls, and detaches whatever does not belong to the open tab. Our wrapper only learns
-- about detaches that happen after it is installed, so seed the flags from the panel's own
-- bookkeeping and the first look at the screen is right too.
local DIARY_TABS = {"quests", "characters", "places", "monsters",
                    "alchemy", "ingredients", "glossary", "tutorials"}

local function seed_diary(d)
  local cs = panel_controls(d)
  if cs == nil then return end
  local tab = DIARY_TABS[d.lm_nLastTabClicked or 0]
  local set = tab and d.lm_tFilters and d.lm_tFilters[tab]
  for i = 1, 9 do
    local c = cs["Filter" .. i]
    if type(c) == "table" then
      local f = set and set[i]
      if f and f.Visible == true then c.wxp_offpanel = nil else c.wxp_offpanel = true end
    end
  end
  -- The act filters belong to the quest tab alone.
  if type(d.lm_tQuestFilters) == "table" then
    local on = (tab == "quests")
    for k, c in pairs(d.lm_tQuestFilters) do
      if type(c) == "table" then
        if on then c.wxp_offpanel = nil else c.wxp_offpanel = true end
      end
    end
  end
  -- Track/untrack only exists once a quest is being read.
  local track = {d.lm_pTrackButton, d.lm_pTrackButtonLabel, d.lm_pTrackButtonLabelBack}
  for i = 1, table.getn(track) do
    local c = track[i]
    if type(c) == "table" then
      if d.lm_bQuestMode == true then c.wxp_offpanel = nil else c.wxp_offpanel = true end
    end
  end
end

-- A panel object reports lm_bActive == false while one of its content panels owns the screen:
-- CGuiNewSystemPanel:SwitchContentPanel toggles its own panel off before showing Options, Load
-- or Controls. Its buttons are then behind that screen, and collecting them put Resume/Save/
-- Load/Options/Exit one press of "down" away from the settings rows -- which is how a stray
-- press could reach Exit and quit the game.
local function shown(obj)
  return obj ~= nil and obj.lm_bActive ~= false
end

local function build_generic(obj, label)
  local own = {}
  if shown(obj) then
    collect_from(obj, own, label)
  end
  seg(label, own)
  local subs = sub_panels(obj)
  for i = 1, table.getn(subs) do
    local nice = string.gsub(subs[i].key, "^lm_p", "")
    local sub = subs[i].obj
    -- A screen keeps all of its content panels alive and swaps which one is shown; collecting
    -- the hidden ones would put unreachable controls in the focus ring.
    local live = true
    if sub.lm_bActive == false then live = false end
    if live and sub.IsActive then
      local okA, rA = pcall(function() return sub:IsActive() end)
      if okA and rA == false then live = false end
    end
    if live then
    local list = {}
    mark_settings_tabs(sub)
    collect_from(sub, list, label .. "." .. nice)
    seg(label .. "." .. nice, list)
    if sub.lm_SettingSets then build_settings(sub, label .. "." .. nice)
    else
      build_settings_tabs(sub, label .. "." .. nice)
      if type(sub.lm_pItems) == "table" then build_bindings(sub, label .. "." .. nice) end
    end
    -- one more level: sub-panels of sub-panels (lists inside a tab, for instance)
    local deep = sub_panels(sub)
    for j = 1, table.getn(deep) do
      local n2 = label .. "." .. nice .. "." .. string.gsub(deep[j].key, "^lm_p", "")
      local l2 = {}
      collect_from(deep[j].obj, l2, n2)
      seg(n2, l2)
    end
    end
  end
end

-- New Game is a small wizard the main menu keeps beside itself: lm_tPanels is the list of steps
-- (content, difficulty, control mode) and lm_nActivePanel says which one is on screen, 0 meaning
-- the menu itself. Those steps are engine panels -- userdata named GamePanel / DifficultyPanel /
-- ControlsPanel -- and not the Lua panel wrappers the rest of the UI is built from: no
-- lm_pPanel, so sub_panels never found one of them. The ring therefore kept the main menu's own
-- buttons, which the wizard is drawn on top of, and up and down paged a menu nobody could see.
local function wizard_step(mm)
  local n, t = mm.lm_nActivePanel, mm.lm_tPanels
  if type(t) ~= "table" or n == nil or n == 0 then return nil end
  local e = t[n]
  return e and e.Panel
end

local function build_wizard(pnl, label)
  local cs
  if not pcall(function() cs = pnl.m_Controls end) then return false end
  if type(cs) ~= "table" then return false end
  local names = {}
  for k, v in pairs(cs) do table.insert(names, k) end
  table.sort(names)

  -- Every choice on these screens is two buttons: the illustrated card (Easy, Witcher, Mouse)
  -- and the caption under it (EaseLabel, WitcherLabel, MouseLabel) which is where the OnClick
  -- that actually picks the option lives. Both light up, so collecting both gives two stops per
  -- choice and lights a different thing on every other press. Keep the cards -- the card's own
  -- OnHilight lights the caption too, which is exactly what the mouse does -- and let the
  -- card's OnLMouseDown delegate the click to the caption, which it already does.
  local function is_caption(n)
    if string.sub(n, -5) ~= "Label" then return false end
    -- Named by hand in the shipped scripts, and not consistently: the card for EaseLabel is
    -- "Easy", not "Ease". So do not try to pair them -- the suffix alone says which is which.
    return true
  end

  local list, dropped = {}, 0
  for i = 1, table.getn(names) do
    local n = names[i]
    local c = cs[n]
    if type(c) == "table" and c.m_ButtonType ~= nil then
      if is_caption(n) then dropped = dropped + 1
      else
        local x, y = pos_of(c)
        if x == nil then
          local okm, m = pcall(function() return c.m_pModel:GetPosition() end)
          if okm and m then x, y = m.x, m.y end
        end
        if x then
          local ctl = c
          local e = {c = ctl, x = x, y = y}
          e.hi = function(on)
            pcall(function()
              if on then ctl:OnMouseEnter() else ctl:OnMouseLeave() end
            end)
            -- The game hangs its own hover behaviour on these hooks, which is what carries the
            -- highlight across to the caption. Calling them keeps card and caption in step.
            pcall(function()
              if on then if ctl.OnHilight then ctl.OnHilight() end
              elseif ctl.OnUnhilight then ctl.OnUnhilight() end
            end)
          end
          -- Back one step. The wizard's Exit is wired to SwitchToPrevPanel, and without this
          -- the cancel button would be dead on every screen of it: the main menu has no
          -- "close" of its own for U.close to find.
          e.esc = function()
            local ex = cs.Exit
            if ex == nil then return false end
            pcall(function() ex:OnLMouseDown() ex:OnLMouseUp() end)
            return true
          end
          table.insert(list, e)
        end
      end
    end
  end
  if table.getn(list) == 0 then return false end
  -- Reading order, not alphabetical: the cards sit in a row with Back below them, and sorting by
  -- name would open every step of the wizard with the focus on "Назад".
  table.sort(list, function(a, b)
    if math.abs(a.y - b.y) > 0.2 then return a.y > b.y end
    return a.x < b.x
  end)
  seg(label, list)
  return true
end

-- Conversations are not "panels" as far as the engine is concerned, but they are the screen
-- the player spends the most time on, so they get a section of their own: the reply lines are
-- controls Reply1..ReplyN and a click on one is what picks that line.
--
-- A conversation also offers things that are not lines at all -- sleep, a gift, trade -- and the
-- engine draws those as a row of bare icons under the replies (AddReplyText splits on
-- nReplyAction and builds Icon<N> instead of Reply<N>). They pick a reply exactly like a line
-- does, so leaving them out of the ring meant the pad simply could not book a room.
local function build_dialog(dp)
  local list = {}
  local mc = dp.lm_pPanel.m_Controls
  local n = dp.lm_nNumNormalReplies or dp.lm_nNumReplies or 0
  for i = 1, n do
    local c = mc["Reply" .. i]
    if c then table.insert(list, {c = c, x = 0, y = -i, idx = i}) end
  end

  -- Icons sit in one horizontal row, laid out right to left by index (X = -375 - (i-1)*75), so
  -- order them by where they actually are rather than by name.
  local icons = {}
  for i = 1, (dp.lm_nNumGPActions or 0) do
    local c = mc["Icon" .. i]
    -- Status 0 is Disabled: the action exists but the game will not let it happen, and a focus
    -- stop that does nothing is the thing that made these screens feel broken in the first place.
    if c and c.m_Status ~= 0 and not c.wxp_offpanel then
      local x = pos_of(c)
      table.insert(icons, {c = c, x = x or 0})
    end
  end
  table.sort(icons, function(a, b) return a.x < b.x end)
  for i = 1, table.getn(icons) do
    local c = icons[i].c
    table.insert(list, {
      c = c, x = 0, y = -(n + i), idx = n + i,
      -- Bare icon, no text: the tooltip is the only thing that says what it does.
      hi = function(on)
        pcall(function() if on then c:OnMouseEnter() else c:OnMouseLeave() end end)
        if on then U.tip(c) end
      end,
      act = function()
        -- The mouse path, so the engine raises OnClick itself; the closure AddReplyText put
        -- there is what knows which reply id this icon stands for.
        local ok = pcall(function() c:OnLMouseDown() c:OnLMouseUp() end)
        if not ok and type(c.OnClick) == "function" then pcall(function() c.OnClick() end) end
      end,
    })
  end
  seg("replies", list)
end

-- The map is not a grid of controls. Its eighteen controls are the fog layer, the map bitmap
-- and eleven marker TEMPLATES the engine clones -- none of them respond to anything, and
-- l_tGuiMapInfo gives handlers to exactly two, both empty. What is actually on the map is
-- lm_tMarkers, attached to lm_pMarkersPanel at real positions.
--
-- So the markers are the ring. For a player who cannot point at the map, "step to the next
-- thing on it and be told what it is" is the whole of what a map does, and the engine already
-- hands us the tooltip it would have shown the mouse.
local function build_map(mp)
  local list = {}
  for k, v in pairs(mp.lm_tMarkers or {}) do
    local c = v.Control
    if c then
      local x, y = pos_of(c)
      local e = {c = c, x = x or 0, y = y or 0, tpl = tostring(v.Template)}
      e.hi = function(on)
        pcall(function() c:SetScale(on and MARKER_SCALE or 1.0) end)
        pcall(function() if on then c:OnMouseEnter() else c:OnMouseLeave() end end)
        if on then U.tip(c) end
      end
      table.insert(list, e)
    end
  end
  if table.getn(list) == 0 then return false end
  -- Reading order, so stepping down the map goes down the map. Markers share coordinates with
  -- each other (one panel, one attachment point), so this is a plain sort, not the two-space
  -- problem the settings rows had.
  table.sort(list, function(a, b)
    if math.abs(a.y - b.y) > 0.2 then return a.y > b.y end
    return a.x < b.x
  end)
  seg("markers", list)
  return true
end

-- The Enhanced Edition registers exactly one minigame: InitializeMinigames builds
-- l_tGames = { ["Poker"] = MGPoker:new() } and loads only mg_poker_main, so the four thousand
-- lines of mg_dices_main and minigame_dices_ex are a prototype that never runs. Poker hides the
-- whole in-game GUI (PrepareGui calls g_GuiInGame:Hide) and puts up its own CLuaPanels, one per
-- phase, which is why nothing else in here recognised the screen.
--
-- NOT VERIFIED IN A REAL GAME -- there is no dice opponent in the prologue. The button half goes
-- through the same collector every other screen uses, so it is as sound as those are; the dice
-- half is new ground and is the part to watch.
local POKER_GUIS = { {"lm_pGuiSetup", "setup"}, {"lm_pGuiBid", "bid"},
                     {"lm_pGuiResult", "result"}, {"lm_pGuiStatus", "status"} }
-- A die is a model in the scene, not a control, so the focus cue has to be geometry.
local DIE_SCALE = 1.25

local function build_poker(pk)
  for i = 1, table.getn(POKER_GUIS) do
    local g = pk[POKER_GUIS[i][1]]
    -- Every phase panel exists for the whole game and is toggled off when it is not the one on
    -- screen, exactly like the system screen's content panels -- collecting the hidden ones
    -- would fill the ring with buttons the player cannot see.
    if type(g) == "table" and shown(g) then
      local live = true
      if g.lm_pPanel then
        local ok, r = pcall(function() return g.lm_pPanel:IsActive() end)
        if ok and r == false then live = false end
      end
      if live then build_generic(g, "Poker." .. POKER_GUIS[i][2]) end
    end
  end

  -- Choosing which dice to re-throw is a click on the die in the 3D scene, so there is no
  -- control for the collector to find. OnLMouseDown matches the clicked object against each
  -- die's own model, which means it can be handed that model directly and the engine does the
  -- rest: selection effect, sound, and the toggle in both directions.
  -- It refuses outright unless the table camera is up (lm_nCamera == 4), and that is exactly
  -- when picking dice means anything, so the section comes and goes on its own.
  if pk.lm_nCamera == 4 and type(pk.tMiniGamesObject) == "table" then
    local base = NWCANIMBASE_BASE or 255
    local list = {}
    for i = 0, 4 do
      local obj = pk.tMiniGamesObject[i]
      local model = nil
      if obj then pcall(function() model = obj:GetModel(base) end) end
      if model then
        table.insert(list, {
          c = model, x = i, y = 0, idx = i + 1,
          hi  = function(on) pcall(function() model:SetScale(on and DIE_SCALE or 1.0) end) end,
          act = function() pcall(function() pk:OnLMouseDown(model) end) end,
        })
      end
    end
    if table.getn(list) > 0 then seg("dice", list) end
  end
end

-- Panels that can own the screen, most specific first.
local function open_panel()
  local gi = g_GuiInGame
  local function act(o)
    if o == nil then return false end
    if o.lm_bActive then return true end
    local ok, r = pcall(function() return o:IsActive() end)
    return ok and r == true
  end
  -- A yes/no confirmation is modal: nothing behind it can be reached, so it always wins,
  -- in the main menu just as much as in game.
  if g_pOKCancelPanel and g_pOKCancelPanel.lm_bActive then
    return "Confirm", g_pOKCancelPanel
  end
  -- Before a game is loaded there is no in-game GUI at all; the screen belongs to the main menu
  -- and to the system panel it opens for Load and Options.
  if gi == nil then
    if g_pGuiMan and act(g_pGuiMan.lm_pInGameNewSystemPanel) then
      return "System", g_pGuiMan.lm_pInGameNewSystemPanel
    end
    if wxp_mainmenu then return "MainMenu", wxp_mainmenu end
    return nil, nil
  end
  -- Popups that pause the game and sit on top of whatever is behind them. The prologue throws
  -- tutorial cards at the player constantly and until now the pad could not answer one at all --
  -- the only way out was the mouse. They win over everything below, dialog included, because
  -- that is exactly the case the engine itself handles by toggling the dialog off (ShowTutorialDialog).
  -- A minigame takes the screen away from the in-game GUI entirely, so it outranks the panels
  -- below -- none of which are even visible while it runs.
  if g_MiniGames and g_MiniGames.lm_sGameRunning == "Poker" and g_Poker then
    return "Poker", g_Poker
  end
  local tut = gi.lm_pInGameNewTutorialPanel
  if tut then
    local okS, shownT = pcall(function() return tut:IsShown() end)
    if okS and shownT and tut.lm_bActive then return "Tutorial", tut end
  end
  if act(gi.lm_pInGameNewSexCardPanel) then return "Card", gi.lm_pInGameNewSexCardPanel end
  if act(gi.lm_pInGameNewRestPanel)    then return "Rest", gi.lm_pInGameNewRestPanel end
  if gi.lm_pDialogPanel and gi.lm_pDialogPanel.lm_bLowerActive then
    return "Dialog", gi.lm_pDialogPanel
  end
  if g_pStackPanel and g_pStackPanel.lm_bActive then return "Stack", g_pStackPanel end
  if g_pBribePanel and g_pBribePanel.lm_bActive then return "Bribe", g_pBribePanel end
  if act(gi.lm_pNewInventoryPanel)      then return "Inventory", gi.lm_pNewInventoryPanel end
  if act(gi.lm_pInGameNewAlchemyPanel)  then return "Alchemy",   gi.lm_pInGameNewAlchemyPanel end
  if act(gi.lm_pInGameNewDiaryPanel)    then return "Diary",     gi.lm_pInGameNewDiaryPanel end
  if act(gi.lm_pInGameSummaryPanel)     then return "Hero",      gi.lm_pInGameSummaryPanel end
  if act(gi.lm_pInGameMapPanel)         then return "Map",       gi.lm_pInGameMapPanel end
  if g_pGuiMan and act(g_pGuiMan.lm_pInGameNewSystemPanel) then
    return "System", g_pGuiMan.lm_pInGameNewSystemPanel
  end
  return nil, nil
end

-- ---------------------------------------------------------------- focus

-- CDragSlot:OnMouseEnter only lights up a slot that holds an item, so drive HilightSlot
-- directly as well: focus has to be visible on empty slots too. Entries built by a
-- hand-written builder may override this with their own `hi` callback.
local function highlight(e, on)
  if e == nil then return end
  local c = e.c
  pcall(function()
    if e.hi then e.hi(on) return end
    if c == nil then return end
    if on then
      if c.HilightSlot then c:HilightSlot(true) end
      c:OnMouseEnter()
      if c.OnTooltip then U.tip(c) end
    else
      if c.UnhilightSlot then c:UnhilightSlot(true) end
      c:OnMouseLeave()
    end
  end)
end

-- Keep the focused row inside the scrolled viewport.
local function scroll_to(sec, pos)
  if sec == nil then return end
  local sv = sec.scroll or (sec.list and sec.list.lm_pScrollView)
  if sv == nil then return end
  pcall(function()
    local sb = sv.lm_pScrollBar
    local n = table.getn(sec.items)
    local idx = pos
    -- A section laid out in columns scrolls by line: the key-binding screen puts two cells on
    -- every row, so stepping the bar per entry would move it twice as far as the focus went
    -- and run out of travel halfway down the list.
    local e = sec.items[pos]
    if sec.nrows and e and e.row then n, idx = sec.nrows, e.row end
    local range = sb:GetScrollRange()
    local frac = 0
    if n > 1 then frac = (idx - 1) / (n - 1) end
    sb:SetScrollPos(range * frac)
    sv:OnLMouseUp()
  end)
end


U.focus_entry = nil

function U.set_focus(e)
  -- Callers historically passed a bare control; accept both.
  if e ~= nil and e.c == nil then e = {c = e} end
  local c = e and e.c
  -- rawequal, not ==: a slider row is userdata and tolua's __eq throws on mixed operands.
  if rawequal(c, U.focus) then return end
  highlight(U.focus_entry, false)
  U.focus, U.focus_entry = c, e
  highlight(e, true)
end

function U.refresh()
  local name, obj = open_panel()
  local prev_names = {}
  for i = 1, table.getn(U.sections) do prev_names[U.sections[i].name] = true end
  U.sections = {}
  U.panel = name or "-"
  if obj == nil then
    highlight(U.focus_entry, false)
    U.focus, U.focus_entry, U.si = nil, nil, 0
    return false
  end
  if name == "Diary" then pcall(function() seed_diary(obj) end) end
  SKIP = {}
  if obj.lm_bActive ~= false then pcall(function() mark_tab_buttons(obj) end) end
  if name == "Dialog" then build_dialog(obj)
  elseif name == "Tutorial" then
    build_generic(obj, name)
    -- The card is one button and a wall of text, so up/down have to mean "read on".
    for si = 1, table.getn(U.sections) do
      if U.sections[si].name == "Tutorial" then U.sections[si].textscroll = obj.lm_pScroll end
    end
  elseif name == "Rest" then
    build_generic(obj, name)
    -- The hour dial is a bare CGuiSlider the panel keeps in a field of its own, not a control.
    for si = 1, table.getn(U.sections) do
      if U.sections[si].name == "Rest" and obj.lm_pSlider then
        table.insert(U.sections[si].items, {
          c = obj.lm_pSlider, x = 0, y = -1,
          adj = function(d)
            local sl = obj.lm_pSlider
            sl:SetScrollPos(sl:GetScrollPos() + d)
            obj:OnLMouseUp(sl)
          end
        })
      end
    end
    -- Meditation is drawn ON TOP of the character screen and does not cover it: the dial is in
    -- one corner and the talent tree fills the rest. A player who opens it to sleep off a night
    -- is just as likely to be there to spend talent points, so both belong in the ring and the
    -- shoulders step between them. Closing meditation to reach the tree behind it works, but
    -- only because the pad had no other way of getting there.
    local hero = g_GuiInGame and g_GuiInGame.lm_pInGameSummaryPanel
    if hero then
      local okH, live = pcall(function()
        if hero.lm_bActive then return true end
        return hero:IsActive() == true
      end)
      if okH and live then
        build_hero_traits(hero)
        build_generic(hero, "Hero")
      end
    end
  elseif name == "MainMenu" then
    -- While a wizard step is up the menu behind it is not on screen, so its buttons must not be
    -- in the ring at all -- that is the whole complaint.
    local step = wizard_step(obj)
    local built = false
    if step ~= nil then
      local okW, r = pcall(function() return build_wizard(step, "NewGame") end)
      built = okW and r
    end
    if not built then build_generic(obj, name) end
  elseif name == "Poker" then build_poker(obj)
  elseif name == "Map" then
    -- Markers first; the tab strip is added below like every other screen's. If the map has
    -- nothing on it yet -- a fresh area, fog everywhere -- fall back so the ring is not empty.
    if not build_map(obj) then build_generic(obj, name) end
  elseif name == "Hero" then build_hero_traits(obj) build_generic(obj, name)
  elseif name == "Inventory" then build_inventory(obj)
  elseif name == "Alchemy" and obj.lm_pRepositoryPanel then build_inventory(obj)
  else build_generic(obj, name) end
  -- The screen's own tab strip, if it has one. The map has nothing else at all, so without
  -- this it offers no focus ring whatsoever.
  if name ~= "Dialog" and obj.lm_bActive ~= false then
    pcall(function() build_tabs(obj, name) end)
  end
  if table.getn(U.sections) == 0 then
    U.focus, U.focus_entry, U.si = nil, nil, 0
    return false
  end
  -- Keep the current focus if it survived the rebuild.
  if U.focus then
    for si = 1, table.getn(U.sections) do
      local it = U.sections[si].items
      for i = 1, table.getn(it) do
        if rawequal(it[i].c, U.focus) then U.si, U.focus_entry = si, it[i] return true end
      end
    end
  end
  -- Opening something adds sections; landing on one of those is what the player expects (pick
  -- Load from the menu and the focus belongs in the save list, not back on the buttons). A list
  -- wins over a button strip: a screen that just produced one is a screen built around it.
  local pick, firstNew = nil, nil
  for si = 1, table.getn(U.sections) do
    if prev_names[U.sections[si].name] == nil then
      if firstNew == nil then firstNew = si end
      if pick == nil and U.sections[si].list then pick = si end
    end
  end
  if pick == nil then pick = firstNew end
  if pick == nil then pick = 1 end
  U.si = pick
  U.set_focus(U.sections[pick].items[1])
  scroll_to(U.sections[pick], 1)
  return true
end

local function current_items()
  local s = U.sections[U.si]
  if s == nil then return nil end
  return s.items
end

local function entry_of(c)
  local it = current_items()
  if it == nil then return nil end
  for i = 1, table.getn(it) do
    if rawequal(it[i].c, c) then return it[i] end
  end
  return nil
end

-- Where a section sits on screen. List rows are ordered by index and carry no real
-- coordinates, so the list widget itself stands in for them; everything else averages its
-- items, which is close enough to decide "is that block above me or to my left".
local function section_anchor(sec)
  if sec.ax then return sec.ax, sec.ay end
  if sec.list then
    local x, y = pos_of(sec.list)
    if x then return x, y end
  end
  local n, sx, sy = 0, 0, 0
  for i = 1, table.getn(sec.items) do
    local e = sec.items[i]
    if e.x and not (e.x == 0 and e.y <= 0) then sx = sx + e.x sy = sy + e.y n = n + 1 end
  end
  if n == 0 then return nil, nil end
  return sx / n, sy / n
end

local function positional(sec)
  return not (sec.list or sec.rows or sec.name == "replies")
end

-- Positional means "step inside it by coordinates". A band is positional inside but keeps its
-- own coordinate space -- the key-binding cells sit on a scroll view's content panel, whose
-- origin has nothing to do with the screen's -- so crossing into or out of one has to go
-- through the section's anchor, the same way a list does.
local function crossable(sec)
  return positional(sec) and not sec.band
end

-- Leaving the current section in the direction the player pushed. Without this the ring is a
-- set of islands and half the screen is only reachable through the shoulder buttons, which is
-- exactly the thing that reads as broken -- the stick should get everywhere.
local function move_across(dx, dy)
  local sec = U.sections[U.si]
  if sec == nil then return nil end
  local ox, oy
  if crossable(sec) and U.focus_entry and U.focus_entry.x then
    ox, oy = U.focus_entry.x, U.focus_entry.y
  else
    ox, oy = section_anchor(sec)
  end
  if ox == nil then return nil end
  local bestSi, bestEnt, bestScore
  local function consider(si, e, x, y)
    local ax, ay = x - ox, y - oy
    local along = ax * dx + ay * dy
    local perp  = math.abs(ax * dy - ay * dx)
    if along <= 0.02 then return end
    -- Crossing blocks is judged mostly by distance along the push: a settings row is anchored
    -- at its label on the far left, so scoring sideways offset as harshly as inside a grid
    -- would skip the rows entirely and land on the buttons at the bottom of the screen.
    if perp > along * 3 + 3 then return end
    local sc = along + perp * 0.5
    if bestScore == nil or sc < bestScore then bestSi, bestEnt, bestScore = si, e, sc end
  end
  for si = 1, table.getn(U.sections) do
    if si ~= U.si then
      local o = U.sections[si]
      if table.getn(o.items) > 0 then
        if crossable(o) then
          for i = 1, table.getn(o.items) do
            local e = o.items[i]
            if e.x then consider(si, e, e.x, e.y) end
          end
        else
          -- A list or a block of settings rows is one destination, entered at its first row --
          -- and it spans the screen, so treat it as a band: a push into it only has to line up
          -- on the axis it is being crossed on. Judging it as a point put the settings rows out
          -- of reach from the category buttons at the left edge of the screen.
          local x, y = section_anchor(o)
          if x then
            if dy ~= 0 then x = ox end
            if dx ~= 0 then y = oy end
            consider(si, o.items[1], x, y)
          end
        end
      end
    end
  end
  if bestEnt == nil then return nil end
  U.si = bestSi
  U.set_focus(bestEnt)
  local ns = U.sections[bestSi]
  for i = 1, table.getn(ns.items) do
    if ns.items[i] == bestEnt then scroll_to(ns, i) end
  end
  return U.describe()
end

-- dx/dy are screen-sense: (0,1) is up. Aurora y already grows upwards.
function U.move(dx, dy)
  if U.focus == nil or entry_of(U.focus) == nil then U.refresh() end
  local sec = U.sections[U.si]
  -- A row that carries a value takes left/right for itself -- that is how a checkbox flips and
  -- a slider moves.
  local fe = U.focus_entry
  if fe and fe.adj and dx ~= 0 then
    local okA, errA = pcall(function() fe.adj(dx) end)
    if not okA then return "adjust failed: " .. tostring(errA) end
    -- the panel repaints its labels after every change, which wipes the focus tint
    highlight(fe, true)
    return U.describe()
  end
  -- A screen that is mostly text scrolls instead of moving a focus: there is nothing else on it
  -- to step to, and a card long enough to need this is one the player has to be able to read.
  if sec and sec.textscroll and dy ~= 0 then
    local okT = pcall(function()
      local sv = sec.textscroll
      local sb = sv.lm_pScrollBar
      local range = sb:GetScrollRange()
      local pos = sb:GetScrollPos() - dy * (range / 6)
      if pos < 0 then pos = 0 end
      if pos > range then pos = range end
      sb:SetScrollPos(pos)
      sv:OnLMouseUp()
    end)
    if okT then return U.describe() end
  end
  if sec and (sec.list or sec.rows or sec.name == "replies") then
    local it = sec.items
    local n = table.getn(it)
    if n == 0 then return "empty list" end
    -- A one-row list has nowhere to step, so the push has to mean "leave this list".
    if n <= 1 then return move_across(dx, dy) or U.describe() end
    local cur = 1
    for i = 1, n do if rawequal(it[i].c, U.focus) then cur = i end end
    local step = 0
    if dy > 0 then step = -1 elseif dy < 0 then step = 1 end
    -- Sideways out of a list: the buttons that act on the selected row usually sit next to it.
    if step == 0 then return move_across(dx, dy) or "edge" end
    local nx = cur - 1 + step
    -- The rows have blocks above and below them on screen, so running off the end should mean
    -- "go there", not "jump to the other end of the list".
    if sec.rows and (nx < 0 or nx >= n) then return move_across(dx, dy) or "edge" end
    nx = math.mod(nx + n, n) + 1
    U.set_focus(it[nx])
    scroll_to(sec, nx)
    return U.describe()
  end
  local it = current_items()
  if it == nil then return "no section" end
  local cur = entry_of(U.focus)
  if cur == nil then
    U.set_focus(it[1])
    return "focus reset"
  end
  local best, bestScore, wrap, wrapScore = nil, nil, nil, nil
  for i = 1, table.getn(it) do
    local e = it[i]
    if not rawequal(e.c, U.focus) then
      local ax, ay = e.x - cur.x, e.y - cur.y
      local along = ax * dx + ay * dy
      local perp  = math.abs(ax * dy - ay * dx)
      if along > 0.005 and perp < along * 2.5 + 0.35 then
        local sc = along + perp * 2.5
        if bestScore == nil or sc < bestScore then best, bestScore = e, sc end
      elseif along < -0.005 then
        -- candidate for wrapping to the far end of the row/column
        local sc = -along - perp * 2.5
        if perp < 0.35 and (wrapScore == nil or sc > wrapScore) then wrap, wrapScore = e, sc end
      end
    end
  end
  -- Inside the section first, then the rest of the screen, and only then wrap around: a jump
  -- back to the far end of the same row should never beat a neighbour that is really there.
  local pick = best
  if pick == nil then
    local across = move_across(dx, dy)
    if across then return across end
    pick = wrap
  end
  if pick == nil then return "edge" end
  U.set_focus(pick)
  local secN = U.sections[U.si]
  if secN and secN.scroll then
    for i = 1, table.getn(secN.items) do
      if secN.items[i] == pick then scroll_to(secN, i) end
    end
  end
  return U.describe()
end

-- The shoulder buttons walk whatever this screen calls a section. Any builder can declare one
-- by naming a section "<panel>.tabs": a real CTextTabControl strip (diary, map) or a set of
-- buttons that acts like one (the options screen's categories). Stepping presses the entry,
-- because that is what picking a tab means.
local function tabs_section()
  for i = 1, table.getn(U.sections) do
    if string.find(U.sections[i].name, "%.tabs$") then return i end
  end
  return nil
end

local function tab_step(delta)
  if table.getn(U.sections) == 0 then U.refresh() end
  local si = tabs_section()
  if si == nil then return nil end
  local sec = U.sections[si]
  local n = table.getn(sec.items)
  if n == 0 then return nil end
  -- Step from where the focus already is, else from the tab that is currently open.
  local cur = nil
  for i = 1, n do if rawequal(sec.items[i].c, U.focus) then cur = i end end
  if cur == nil then
    for i = 1, n do
      local e = sec.items[i]
      if e.sel then
        local oks, r = pcall(e.sel)
        if oks and r then cur = i end
      end
    end
  end
  local nx
  if cur == nil then
    if delta >= 0 then nx = 1 else nx = n end
  else
    nx = math.mod(cur - 1 + delta + n, n) + 1
  end
  local e = sec.items[nx]
  U.si = si
  U.set_focus(e)
  local ok, err = pcall(function()
    if e.act then e.act() else e.c:OnLMouseDown() e.c:OnLMouseUp() end
  end)
  if not ok then return "tab failed: " .. tostring(err) end
  -- Stay on the tab that was just picked: the player is walking the strip, and the content
  -- below is one push of the stick away. Follow it by key, not by identity -- picking
  -- "Управление" replaces the whole screen, and with it every one of its buttons; losing the
  -- focus there sent the next press back to the first tab, so "Дополнительно" was unreachable.
  local keep, key = e.c, e.tabkey
  U.focus, U.focus_entry = nil, nil
  U.refresh()
  for i = 1, table.getn(U.sections) do
    local it = U.sections[i].items
    for j = 1, table.getn(it) do
      if rawequal(it[j].c, keep) or (key and it[j].tabkey == key) then
        U.si = i U.set_focus(it[j]) return U.describe()
      end
    end
  end
  return U.describe()
end

-- Sibling panels sharing one screen slot (Hero/Stats/Skills and friends) have no strip of
-- their own; the panel manager swaps them.
local function mgr_tab(delta)
  local gi = g_GuiInGame
  local mgr = gi and gi.lm_pPanelManager
  if mgr == nil or type(mgr.lm_tTabsPanels) ~= "table" then return nil end
  for pos, tp in pairs(mgr.lm_tTabsPanels) do
    if type(tp) == "table" and tp.lm_nTabsNum and tp.lm_nTabsNum > 0 then
      local cur = mgr.lm_sPanels[pos]
      local n = tp.lm_nTabsNum
      local names, idx = {}, nil
      for i = 0, n - 1 do
        names[i] = tp.lm_tPanelsNames[i]
        if names[i] == cur then idx = i end
      end
      -- The open panel is normally not one of its own tabs; step from the first entry then.
      local nx
      if idx == nil then
        if delta >= 0 then nx = 0 else nx = n - 1 end
      else
        nx = math.mod(idx + delta + n, n)
      end
      local target = names[nx]
      if target and target ~= cur then
        local ok, err = pcall(function() return mgr:SwitchPanel(pos, target) end)
        if not ok then return "tab failed: " .. tostring(err) end
        U.focus, U.focus_entry = nil, nil
        U.refresh()
        return U.describe()
      end
    end
  end
  return nil
end

function U.section(delta)
  local n = table.getn(U.sections)
  if n == 0 then U.refresh() n = table.getn(U.sections) end
  -- A screen with a single block of controls has no sections to walk; the thing the player
  -- means by "next section" there is the tab strip.
  if n <= 1 then
    local r = tab_step(delta) or mgr_tab(delta)
    if r then return r end
  end
  if n == 0 then return "no sections" end
  U.si = math.mod(U.si - 1 + delta + n, n) + 1
  local sec = U.sections[U.si]
  U.set_focus(sec.items[1])
  scroll_to(sec, 1)
  return U.describe()
end

function U.activate()
  local c = U.focus
  if c == nil then return "no focus" end
  local sec = U.sections[U.si]
  local e = U.focus_entry
  local ok, err = pcall(function()
    if e and e.act then e.act()
    elseif sec and sec.name == "replies" then
      c:OnLMouseDown()
    elseif sec and sec.list then
      CListControl:OnItemClicked(sec.list, c)
    elseif c.m_Status == SLOT_OCCUPIED and c.OnDoubleClick then
      c:OnDoubleClick()
    else
      c:OnLMouseDown()
      c:OnLMouseUp()
    end
  end)
  if not ok then return "activate failed: " .. tostring(err) end
  U.refresh()
  return "activated " .. tostring(c.m_Name)
end

function U.alt()
  local c = U.focus
  if c == nil then return "no focus" end
  local e = U.focus_entry
  if e and e.alt then
    local okA, errA = pcall(e.alt)
    if not okA then return "alt failed: " .. tostring(errA) end
    U.refresh()
    return "alt " .. tostring(c.m_Name)
  end
  pcall(function() c:OnRMouseDown() c:OnRMouseUp() end)
  U.refresh()
  return "alt " .. tostring(c.m_Name)
end

function U.describe()
  local s = U.sections[U.si]
  local sn = "-"
  if s then sn = s.name .. "[" .. table.getn(s.items) .. "]" end
  local fn = "-"
  if U.focus then
    local okn, n = pcall(function() return U.focus.m_Name end)
    if okn and n then fn = tostring(n)
    elseif s then
      -- A slider row is userdata with no name to read; say where it is instead.
      for i = 1, table.getn(s.items) do
        if rawequal(s.items[i].c, U.focus) then fn = "row " .. i end
      end
    end
  end
  return U.panel .. " / " .. sn .. " / " .. fn
end

function U.status()
  local out = {}
  for i = 1, table.getn(U.sections) do
    table.insert(out, U.sections[i].name .. "=" .. table.getn(U.sections[i].items))
  end
  log(U.describe() .. "  sections: " .. table.concat(out, " "))
  return U.describe()
end

-- ---------------------------------------------------------------- panels

-- name -> (open, close) pair, mirroring what l_tGuiOptionsInfo in gui_new_optionspanel does
-- when the player clicks the HUD buttons.
local function panel_ops(key)
  local gi = g_GuiInGame
  -- The system panel is the one screen that also exists before a game is loaded, so it must not
  -- depend on g_GuiInGame the way the in-game panels do.
  if key == "system" then
    if g_pGuiMan == nil or g_pGuiMan.lm_pInGameNewSystemPanel == nil then return nil end
    return function() g_pGuiMan.lm_pInGameNewSystemPanel:TogglePanel() end,
           function() g_pGuiMan.lm_pInGameNewSystemPanel:ToggleOff() end
  end
  if gi == nil then return nil end
  -- Popups have no "open" of their own -- the game raises them. What matters is that cancel
  -- can put them away, which is the whole reason the pad was stuck on them.
  if key == "tutorial" then
    return function() end, function() gi:CloseTutorialDialog() end
  elseif key == "card" then
    return function() end, function() gi.lm_pInGameNewSexCardPanel:ToggleOff() end
  elseif key == "rest" then
    return function() end, function() gi.lm_pInGameNewRestPanel:ToggleOff() end
  elseif key == "poker" then
    -- The minigame is not something the pad opens; the game starts it from a conversation.
    -- Backing out is the engine's own escape path, which asks for confirmation where it should.
    return function() end, function() g_Poker:OnKeyboardEsc() end
  end
  if key == "inventory" then
    return function() gi.lm_pNewInventoryPanel:ShowIndependent() end,
           function() gi.lm_pNewInventoryPanel:Hide() end
  elseif key == "alchemy" then
    return function() gi.lm_pInGameNewAlchemyPanel:UnToggleOff() end,
           function() gi.lm_pInGameNewAlchemyPanel:ToggleOff() end
  elseif key == "diary" then
    return function() gi:ToggleDiary() end, function() gi:ToggleDiary() end
  elseif key == "hero" then
    return function() gi.lm_pInGameSummaryPanel:ShowIndependent() end,
           function() gi.lm_pInGameSummaryPanel:Hide() end
  elseif key == "map" then
    return function() gi.lm_pInGameMapPanel:TogglePanel() end,
           function() gi.lm_pInGameMapPanel:TogglePanel() end
  end
  return nil
end

local PANEL_KEY = {
  Inventory = "inventory", Alchemy = "alchemy", Diary = "diary",
  Hero = "hero", Map = "map", System = "system",
  Tutorial = "tutorial", Card = "card", Rest = "rest", Poker = "poker"
}

function U.open(key)
  local o, c = panel_ops(key)
  if o == nil then return "unknown panel " .. tostring(key) end
  -- Most of these are toggles; opening what is already open would close it.
  U.refresh()
  if PANEL_KEY[U.panel] == key then return U.describe() end
  local ok, err = pcall(o)
  if not ok then return "open failed: " .. tostring(err) end
  U.focus, U.focus_entry = nil, nil
  U.refresh()
  return U.describe()
end

function U.close()
  -- A cell that is waiting for a key takes the back button for itself: leaving the screen with
  -- the engine still capturing would swallow the next keypress somewhere else entirely.
  local fe = U.focus_entry
  if fe and fe.esc then
    local okE, handled = pcall(fe.esc)
    -- Refresh before describing: the step it just backed out of is gone, and reporting the
    -- section we were in a moment ago is only confusing in a log.
    if okE and handled then U.refresh() return U.describe() end
  end
  U.refresh()
  if U.panel == "Dialog" then return "in dialog" end
  local name = U.panel
  local key = PANEL_KEY[name]
  if key == nil then return "nothing open" end
  local o, c = panel_ops(key)
  local closed = false
  if c then closed = pcall(c) end
  if not closed then
    -- No known close for this screen: press its own back/close control instead.
    local want = {"Close", "CloseButton", "Back", "BackButton", "Exit", "SettingsBackButton"}
    for w = 1, table.getn(want) do
      for si = 1, table.getn(U.sections) do
        local it = U.sections[si].items
        for i = 1, table.getn(it) do
          if it[i].c and it[i].c.m_Name == want[w] then
            pcall(function() it[i].c:OnLMouseDown() it[i].c:OnLMouseUp() end)
            closed = true
            break
          end
        end
        if closed then break end
      end
      if closed then break end
    end
  end
  U.focus, U.focus_entry = nil, nil
  U.refresh()
  return U.describe()
end

-- The shoulder buttons mean "next part of this screen". Whichever way a screen expresses
-- that -- its own tab strip, the panel manager, or the sections we built -- one of these
-- answers, so the button is never dead.
function U.tab(delta)
  local r = tab_step(delta)
  if r then return r end
  r = mgr_tab(delta)
  if r then return r end
  return U.section(delta)
end

function U.focus_by_name(name)
  for si = 1, table.getn(U.sections) do
    local it = U.sections[si].items
    for i = 1, table.getn(it) do
      if it[i].c and it[i].c.m_Name == name then
        U.si = si
        U.set_focus(it[i])
        return U.describe()
      end
    end
  end
  return "not found: " .. tostring(name)
end

-- ---------------------------------------------------------------- intents
-- One verb per gamepad event. The bridge writes these into System/wxp_nav.txt.

function wxp_intent(intent)
  if intent == nil then return "nil intent" end
  local sub = nil
  local colon = string.find(intent, ":")
  if colon then
    sub = string.sub(intent, colon + 1)
    intent = string.sub(intent, 1, colon - 1)
  end
  if     intent == "up"       then return U.move(0, 1)
  elseif intent == "down"     then return U.move(0, -1)
  elseif intent == "left"     then return U.move(-1, 0)
  elseif intent == "right"    then return U.move(1, 0)
  elseif intent == "activate" then return U.activate()
  elseif intent == "alt"      then return U.alt()
  elseif intent == "sect+"    then return U.section(1)
  elseif intent == "sect-"    then return U.section(-1)
  elseif intent == "tab+"     then return U.tab(1)
  elseif intent == "tab-"     then return U.tab(-1)
  elseif intent == "cancel"   then return U.close()
  elseif intent == "close"    then return U.close()
  elseif intent == "open"     then return U.open(sub)
  elseif intent == "signmenu" then
    if wxp_wheel == nil and wxp_load_wheel then wxp_load_wheel() end
    if wxp_wheel then return wxp_wheel.show(sub == "on") end
    return "no wheel"
  elseif intent == "target" then
    if wxp_combat == nil and wxp_load_combat then wxp_load_combat() end
    if wxp_combat == nil then return "no combat layer" end
    local r
    if sub == "next" then r = wxp_combat.cycle(1)
    elseif sub == "prev" then r = wxp_combat.cycle(-1)
    elseif sub == "off" then wxp_combat.clear() return "target cleared"
    else r = wxp_combat.acquire() end
    if r == nil then return "no target" end
    return "target " .. wxp_combat.status()
  elseif intent == "run" then
    -- Two speeds off the left stick. The game has no walk key at all -- actions.2da has only
    -- Forward/Backward/Strafe -- and startup.lua turns always-run on, so Geralt has been
    -- sprinting everywhere. Measured on the live player: always-run gives 7.5-9.4 units per
    -- second and walking 2.1-2.5, so this really is the walk/run split and not a nuance.
    -- Both the engine call and the settings flag are set: the flag is what startup.lua uses,
    -- and leaving the two disagreeing is how a setting comes back on its own later.
    local want = (sub ~= "0")
    g_cAuroraSettings.m_bAlwaysRun = want
    pcall(function() g_pClientExoApp:SetAlwaysRun(want) end)
    return want and "run" or "walk"
  elseif intent == "sign" then
    local n = tonumber(sub) or 0
    if wxp_wheel then
      wxp_wheel.highlight(n)
      wxp_wheel.select(n)
      return "sign " .. tostring(n)
    end
    return "no wheel"
  end
  return "unknown intent " .. tostring(intent)
end

-- Short names for the bridge's command channel.

function wxp_nav(dir)
  if     dir == "up"    then return U.move(0, 1)
  elseif dir == "down"  then return U.move(0, -1)
  elseif dir == "left"  then return U.move(-1, 0)
  elseif dir == "right" then return U.move(1, 0)
  end
  return "bad dir"
end
function wxp_act()          return U.activate() end
function wxp_alt()          return U.alt() end
function wxp_tab(d)         return U.section(d or 1) end
function wxp_ui_refresh()   U.refresh() return U.describe() end

log("navigation layer loaded")
