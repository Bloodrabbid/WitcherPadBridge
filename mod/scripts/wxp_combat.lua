-- WitcherPadBridge :: combat targeting.
--
-- Aurora fights with the mouse: an attack starts on the creature under the cursor, and the
-- engine then keeps an "attack lock" on it. A pad has no cursor to put on anyone, so the lock
-- has to be set from here -- g_Module:SetLockedAttackTarget is the engine's own entry point for
-- exactly that.
--
-- Finding who to lock onto needs a list of enemies, and the engine already keeps one: it fires
-- enemy.add / enemy.update / enemy.remove GUI events as creatures enter and leave the fight.
-- The Enhanced Edition's handlers for those are empty stubs (they belonged to the old HUD), so
-- nothing in the game reads them -- but the engine still sends them. Listening in costs nothing
-- and gives exactly the set the game itself considers hostile.
--
-- Do NOT try to enumerate creatures by walking object ids through GetGameObject: an id that is
-- not a live object takes the game down with it. Verified the hard way.

wxp_combat = {}
local C = wxp_combat

C.enemies = {}        -- creature -> os.clock() when the engine last mentioned it
C.target  = nil
C.hooked  = false
C.enabled = true
C.range   = 25        -- world units; a fight in this engine happens well inside that
C.trace    = true     -- log every enemy event while working out what the engine sends
C.watching = true     -- log combat mode / enemy count / lock whenever they change

local function log(s) if wxp_log then wxp_log("cbt: " .. tostring(s)) end end

-- ---------------------------------------------------------------- enemy feed

function C.on_event(name, a1)
  if name == nil or string.sub(name, 1, 6) ~= "enemy." then return end
  if C.trace then log("event " .. name .. " " .. tostring(a1)) end
  if name == "enemy.remove.all" then
    C.enemies = {}
    C.target = nil
  elseif name == "enemy.remove" then
    if a1 ~= nil then
      C.enemies[a1] = nil
      if rawequal(a1, C.target) then C.target = nil end
    end
  elseif a1 ~= nil then
    -- add / update / hilite / add_and_hilite all mean "this one is in the fight"
    C.enemies[a1] = os.clock()
  end
end

-- CGuiInGame:OnGuiEvent has a fixed arity, so pass every argument through by name rather than
-- through arg/unpack: this sits in front of every GUI event the engine sends.
function C.hook()
  if C.hooked then return true end
  if CGuiInGame == nil then return false end
  local orig = CGuiInGame.OnGuiEvent
  if type(orig) ~= "function" then return false end
  C.hooked = true
  function CGuiInGame:OnGuiEvent(s, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15)
    pcall(function() C.on_event(s, a1) end)
    return orig(self, s, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15)
  end
  log("gui event hook installed")
  return true
end

-- ---------------------------------------------------------------- geometry

local function pos_of(o)
  local v = Vector:new_local(0, 0, 0)
  o:GetPosition(v)
  return v
end

local function alive(c)
  local ok, r = pcall(function()
    local p = c:GetCreatureProxy()
    if p == nil then return false end
    if p.IsDead and p:IsDead() then return false end
    return p:GetCurrentVitalityPoints() > 0
  end)
  return ok and r == true
end

-- Everything the engine has told us about, minus the dead and the departed. Creatures that were
-- removed from the world stop answering GetPosition, so a failure here is also a removal.
function C.candidates()
  local out = {}
  if g_Player == nil then return out end
  local okp, p = pcall(function() return pos_of(g_Player) end)
  if not okp then return out end
  local face = nil
  pcall(function()
    local v = Vector:new_local(0, 0, 0)
    g_Player:GetOrientation(v)
    face = v
  end)
  for c, _ in pairs(C.enemies) do
    local ok, e = pcall(function()
      if rawequal(c, g_Player) then return nil end
      if not alive(c) then return nil end
      local w = pos_of(c)
      local dx, dy = w.x - p.x, w.y - p.y
      local d = math.sqrt(dx * dx + dy * dy)
      if d > C.range then return nil end
      -- Ahead of Geralt beats behind him, but distance still decides between two in front.
      local score = d
      if face and d > 0.01 then
        local fl = math.sqrt(face.x * face.x + face.y * face.y)
        if fl > 0.01 then
          local cosa = (dx * face.x + dy * face.y) / (d * fl)
          score = d * (1.6 - 0.6 * cosa)
        end
      end
      return {c = c, d = d, score = score}
    end)
    if ok and e then table.insert(out, e) end
    if not ok then C.enemies[c] = nil end
  end
  table.sort(out, function(a, b) return a.score < b.score end)
  return out
end

-- ---------------------------------------------------------------- targeting

-- SetLockedAttackTarget takes an object id, not the creature; GetLockedAttackTarget hands back
-- the creature. Id 0 clears the lock -- 0xFFFFFFFF does not, it resolves to the player.
local NO_OBJECT = 0

function C.set(c)
  C.target = c
  local id = NO_OBJECT
  if c ~= nil then
    local oki, r = pcall(function() return c:GetId() end)
    if not oki or type(r) ~= "number" then log("no id for target") return false end
    id = r
  end
  local ok, err = pcall(function() g_Module:SetLockedAttackTarget(id) end)
  if not ok then log("SetLockedAttackTarget failed: " .. tostring(err)) return false end
  return true
end

function C.acquire()
  local list = C.candidates()
  if table.getn(list) == 0 then return nil end
  C.set(list[1].c)
  return list[1]
end

-- Step through the enemies in the order acquire() would rank them.
function C.cycle(delta)
  local list = C.candidates()
  local n = table.getn(list)
  if n == 0 then C.target = nil return nil end
  local cur = 0
  for i = 1, n do if rawequal(list[i].c, C.target) then cur = i end end
  local nx = math.mod(cur - 1 + delta + n, n) + 1
  C.set(list[nx].c)
  return list[nx]
end

function C.clear()
  C.set(nil)
  C.target = nil
end

-- Called every frame from the runtime tick. Keeps the lock pinned to a live target and picks a
-- new one the moment the current one drops, which is what makes a fight playable without a mouse.
-- One line per change, never per frame: this is what a single real fight has to tell us.
local last = {}
local function watch()
  local mode = 0
  pcall(function() mode = getPlayerCombatMode() end)
  local n = 0
  for _, _ in pairs(C.enemies) do n = n + 1 end
  local tag = "-"
  if C.target then pcall(function() tag = C.target:GetObjectTag() end) end
  local held = "-"
  pcall(function()
    local h = g_Module:GetLockedAttackTarget()
    if h then held = h:GetObjectTag() end
  end)
  if mode ~= last.mode or n ~= last.n or tag ~= last.tag or held ~= last.held then
    last.mode, last.n, last.tag, last.held = mode, n, tag, held
    log(string.format("mode=%s enemies=%d target=%s lock=%s", tostring(mode), n, tag, held))
  end
end

function C.tick()
  if C.watching then pcall(watch) end
  if not C.enabled or g_Player == nil or g_Module == nil then return end
  local held = nil
  pcall(function() held = g_Module:GetLockedAttackTarget() end)
  if C.target ~= nil then
    if not alive(C.target) then C.target = nil
    elseif held == nil then C.set(C.target) end
  end
  if C.target == nil then
    local ok, mode = pcall(function() return getPlayerCombatMode() end)
    if ok and mode and mode ~= 0 then C.acquire() end
  end
end

function C.status()
  local list = C.candidates()
  local s = "enemies=" .. table.getn(list) .. " target="
  if C.target then
    local ok, t = pcall(function() return C.target:GetObjectTag() end)
    s = s .. (ok and tostring(t) or "?")
  else
    s = s .. "-"
  end
  local ok2, held = pcall(function() return g_Module:GetLockedAttackTarget() end)
  s = s .. " lock=" .. tostring(ok2 and held)
  for i = 1, math.min(table.getn(list), 6) do
    local tag = "?"
    pcall(function() tag = list[i].c:GetObjectTag() end)
    s = s .. string.format(" | %s d=%.1f", tostring(tag), list[i].d)
  end
  return s
end

C.hook()
log("combat targeting loaded")
