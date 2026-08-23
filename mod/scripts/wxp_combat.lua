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
--
-- What the lock does NOT do is make a blow land. Verified in a live fight: with the lock held
-- on a bandit an arm's length away and the reticle on empty ground, OnAttackBegin never fires,
-- with or without m_nAttackLockingMode. The engine's own GetPlayerAttackLock stays
-- OBJECT_INVALID throughout; SetLockedAttackTarget only feeds the selection ring that
-- CNWCModule:OnHeartbeat draws. An attack goes to whoever is under the reticle -- the game says
-- so on its own tutorial card: click only when the cursor turns into a burning sword.
--
-- So aiming is turning the camera, and that is what the assist below does. The one thing that
-- makes it tractable is CNWCModule:OnHiliteMouseover, which hands Lua the creature under the
-- reticle every frame: there is no world-to-screen projection in Lua, but this is the answer
-- projection would have been for. Geometry gets the camera close, the mouseover feed closes it.
--
-- The same rule applies to creatures we are already holding. A creature that the engine has
-- deleted leaves a dangling userdata behind, and calling anything on it is a bus error, not a
-- Lua error -- pcall does not save us. lg_tCreatureList is the engine's own register of live
-- creatures (CNWCCreature:OnCreate adds, OnDelete removes), so a plain table lookup answers
-- "is this still a real object" without touching the object at all. Every path in here goes
-- through registered() before it dereferences anything.

wxp_combat = {}
local C = wxp_combat

C.enemies = {}        -- creature -> os.clock() when the engine last mentioned it
C.target  = nil
C.hooked  = false
C.enabled = true
C.range   = 25        -- world units; a fight in this engine happens well inside that
C.trace    = false    -- log every enemy event; only useful while reverse-engineering the feed
C.watching = true     -- log combat mode / enemy count / lock whenever they change

-- Aim assist. Measured on the live camera: 200 px of mouse turn the view by 1.0123 rad, three
-- steps in a row agreeing to four decimals, so the mapping is flat and one constant covers it.
C.aim_enabled = true
C.aim_px_rad  = 197.6
-- The camera does not look at Geralt, it looks past his shoulder, so pointing the
-- camera-to-player axis at a target still leaves the reticle beside it -- about 70 px worth at
-- melee range when measured by hand. It is a property of the rig, not of the target, and it
-- flips when the player switches shoulder, so it is seeded and then learned: every frame the
-- reticle is confirmed on the target, the geometric residual at that moment IS the offset.
C.aim_offset  = -72
C.aim_seq     = 0
C.aim_hunt    = nil   -- when the geometry says "aimed" but the reticle disagrees
C.aim_hunt_i  = 0
C.aim_hunt_net = 0    -- how far the search has pushed the view, so it can put it back
C.aim_hunt_for = nil  -- the target the current search belongs to
-- Close enough. The reticle is about 85 px of mouse wide, so a residual smaller than this is
-- already on the target and spending it only produces a permanent micro-jitter that reads as
-- the camera never settling.
C.aim_dead    = 30
-- How long a chosen target is kept before the creature under the reticle may take its place.
-- Without this the assist and the retarget rule feed each other: turning toward A sweeps B
-- under the reticle, retargeting to B turns the view back across A, and the camera swings left
-- and right for as long as the fight lasts.
C.retarget_hold = 0.8
C.target_since  = 0
-- Pitch is deliberately not solved. g_CameraGob is not the eye: as the view swings from sky to
-- ground its angle above Geralt stays at 45 degrees and only its distance changes, so the
-- elevation of the look axis simply is not in anything Lua can read. An unlearned guess at it
-- pins the camera against its pitch limit and holds it there -- watched it happen. So height is
-- left to the sweep below, which is bounded and self-correcting, and costs a fraction of a
-- second only when yaw alone has failed to find the target.

local function log(s) if wxp_log then wxp_log("cbt: " .. tostring(s)) end end

-- A pointer lookup, nothing more: safe to call on a creature that may already be gone.
local function registered(c)
  if c == nil then return false end
  if lg_tCreatureList == nil then return true end
  return lg_tCreatureList[c] ~= nil
end

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
  elseif a1 ~= nil and registered(a1) then
    -- add / update / hilite / add_and_hilite all mean "this one is in the fight"
    C.enemies[a1] = os.clock()
  end
end

-- CGuiInGame:OnGuiEvent has a fixed arity, so pass every argument through by name rather than
-- through arg/unpack: this sits in front of every GUI event the engine sends.
function C.hook()
  if C.hooked then return true end
  if CGuiInGame == nil then return false end
  -- Reloading this file makes a new C, so a naive wrap would stack a fresh hook on top of the
  -- previous one and every event would be delivered twice, once into a table nobody reads.
  -- Keep the engine's own method aside the first time and always wrap that.
  if wxp_gui_event_orig == nil then
    local o = CGuiInGame.OnGuiEvent
    if type(o) ~= "function" then return false end
    wxp_gui_event_orig = o
  end
  local orig = wxp_gui_event_orig
  C.hooked = true
  function CGuiInGame:OnGuiEvent(s, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15)
    pcall(function() C.on_event(s, a1) end)
    -- One wrapper, two readers: vibration wants a different set of these events, and wrapping
    -- OnGuiEvent a second time would deliver everything twice.
    pcall(function() if wxp_rumble then wxp_rumble.on_event(s, a1, a2) end end)
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
  if not registered(c) then return false end
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
    if not registered(c) then C.enemies[c] = nil end
    local ok, e = pcall(function()
      if not registered(c) then return nil end
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
  if c ~= nil and not registered(c) then return false end
  -- Only when it is a different creature: tick() re-pins the same target every frame to keep
  -- the engine's selection ring on it, and stamping that would make the hold below expire never.
  if not rawequal(c, C.target) then C.target_since = os.clock() end
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

-- ---------------------------------------------------------------- aim assist

local AIM_FILE = "wxp_aim.txt"      -- cwd is the game's System/ dir

local function bearing(dx, dy)
  if math.atan2 then return math.atan2(dy, dx) end
  if dx == 0 then if dy >= 0 then return 1.5707963 else return -1.5707963 end end
  local a = math.atan(dy / dx)
  if dx < 0 then a = a + 3.14159265 end
  return a
end

-- Sums to zero, so a search that runs to the end leaves the camera as the player left it. A
-- search that is cut short does not, which is what aim_hunt_reset is for: without it the leftover
-- nudges pile up and half a minute of fighting has the view pointing at the sky. Watched that
-- happen, and every attack after it swung at a wall.
local HUNT_Y = {40, -80, 80, -40}

-- Undo whatever the search has pushed the view by, in one nudge.
local function aim_hunt_reset()
  local n = C.aim_hunt_net or 0
  C.aim_hunt, C.aim_hunt_i, C.aim_hunt_net = nil, 0, 0
  return -n
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function wrap_pi(a)
  while a >  3.14159265 do a = a - 6.2831853 end
  while a < -3.14159265 do a = a + 6.2831853 end
  return a
end

function C.under_reticle()
  if g_Module == nil then return nil end
  local c = g_Module.lm_pMouseOverCreature
  if not registered(c) then return nil end
  return c
end

-- How far the camera still has to turn, in the pixels the bridge already speaks, plus whether
-- the reticle is on the target right now. Positive turns the view one way, negative the other;
-- the sign convention is the bridge's, measured, not guessed.
function C.aim_solve()
  local t = C.target
  if not registered(t) or g_Player == nil or g_CameraGob == nil then return nil end
  -- Any enemy under the reticle will do: the blow lands on whoever is there, and the point of
  -- the assist is a blow that lands, not a particular corpse.
  local mo = C.under_reticle()
  local ready = mo ~= nil and (rawequal(mo, t) or C.enemies[mo] ~= nil)
  local ok, gx, far = pcall(function()
    local c = Vector:new_local(0, 0, 0) g_CameraGob:GetPosition(c)
    local p = Vector:new_local(0, 0, 0) g_Player:GetPosition(p)
    local e = Vector:new_local(0, 0, 0) t:GetPosition(e)
    -- Where the rig is pointing. This one rotates one-for-one with mouse dx, which is the whole
    -- reason the mapping above is a single constant.
    local view = bearing(p.x - c.x, p.y - c.y)
    -- Where the target is, measured from Geralt rather than from the camera. The camera sits
    -- barely a pace from him, so a bearing taken from it swings through tens of degrees for a
    -- target at sword's length -- and it is exactly at sword's length that this runs most.
    -- From Geralt the same angle is steady, and at any range worth turning for the two agree.
    local want = bearing(e.x - p.x, e.y - p.y)
    local d = math.sqrt((e.x - p.x) * (e.x - p.x) + (e.y - p.y) * (e.y - p.y))
    -- +dx lowers the camera yaw, hence the sign
    return -wrap_pi(want - view) * C.aim_px_rad, d
  end)
  if not ok or gx == nil then return nil end
  if ready then
    -- Found it: the view is where it should be, so nothing to give back.
    C.aim_hunt, C.aim_hunt_i, C.aim_hunt_net, C.aim_hunt_for = nil, 0, 0, nil
    -- The camera is where it should be, so whatever geometry says right now is the rig's own
    -- offset. Learn it slowly: a target strafing through the reticle would otherwise drag it.
    -- Not from a target in Geralt's face, though: there the parallax between his position and
    -- the camera's is the same size as the distance being measured, and a value learned from
    -- one of those poisons the aim for everything further away. Watched it happen: an offset
    -- learned at a pace and a half left a bandit twenty paces off unreachable.
    if far and far > 3 then
      C.aim_offset = clamp(C.aim_offset * 0.9 + (-gx) * 0.1, -260, 260)
    end
    return 0, 0, true
  end
  local tx, ty = clamp(gx + C.aim_offset, -600, 600), 0
  -- Inside the reticle already: stop asking the bridge to turn. A target in melee never stands
  -- still, so without this the residual flickers around zero and the camera hunts forever.
  if math.abs(tx) < C.aim_dead then tx = 0 end
  -- Yaw says we are on it and the engine says we are not, so what is left is height: the target
  -- is up a stair, or taller or shorter than the guess baked into the learned offset. Nudge the
  -- view up and down over the target, then come back to where it started -- four steps, bounded,
  -- and it stops the moment the reticle answers.
  if math.abs(tx) < C.aim_dead and rawequal(C.aim_hunt_for, t) then
    if C.aim_hunt == nil then C.aim_hunt = os.clock() C.aim_hunt_i = 0 C.aim_hunt_net = 0 end
    -- Wait longer before starting: the vertical sweep is the part that actually makes people
    -- queasy, and most of the time yaw alone gets there a fraction of a second later anyway.
    local n = math.floor((os.clock() - C.aim_hunt - 0.6) / 0.16)
    if n >= C.aim_hunt_i and C.aim_hunt_i < 4 then
      C.aim_hunt_i = C.aim_hunt_i + 1
      ty = HUNT_Y[C.aim_hunt_i]
      C.aim_hunt_net = C.aim_hunt_net + ty
    end
  else
    -- The target moved out from under the search, or it belongs to somebody else now: give the
    -- view back before starting over.
    ty = aim_hunt_reset()
    C.aim_hunt_for = t
  end
  return tx, ty, false
end

-- One line, replaced in place: <seq> <dx> <dy> <ready>.
-- dx is an absolute residual: it is recomputed every frame from a camera that has already
-- moved, so the bridge replaces rather than accumulates, and the pair is a closed loop instead
-- of a dead-reckoned shove. dy has no such feedback -- the engine gives Lua no way to see the
-- camera's pitch -- so it is an increment the bridge adds on, and it is only ever emitted as
-- the bounded search above.
local aim_t
function C.aim_publish()
  if not C.aim_enabled then return end
  local now = os.clock()
  if aim_t and now - aim_t < 0.03 and now >= aim_t then return end
  local tx, ty, ready = C.aim_solve()
  if tx == nil then return end
  aim_t = now
  C.aim_seq = C.aim_seq + 1
  local f = io.open(AIM_FILE, "w")
  if f == nil then return end
  f:write(string.format("%d %d %d %d\n", C.aim_seq, tx, ty, ready and 1 or 0))
  f:close()
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
  if registered(C.target) then pcall(function() tag = C.target:GetObjectTag() end) end
  local held = "-"
  pcall(function()
    local h = g_Module:GetLockedAttackTarget()
    if registered(h) then held = h:GetObjectTag() end
  end)
  if mode ~= last.mode or n ~= last.n or tag ~= last.tag or held ~= last.held then
    last.mode, last.n, last.tag, last.held = mode, n, tag, held
    log(string.format("mode=%s enemies=%d target=%s lock=%s", tostring(mode), n, tag, held))
  end
end

function C.tick()
  if C.watching then pcall(watch) end
  if not C.enabled or g_Player == nil or g_Module == nil then return end
  -- A tutorial card pauses the world, and the prologue throws one at the player the moment they
  -- land their first blow. Nothing moves while it is up, so aiming at anything is meaningless --
  -- and every reading taken then is a reading of a frozen frame, which is how two earlier rounds
  -- of "the assist stopped working" turned out to be nothing of the sort.
  local okd, wd = pcall(getWorldTimeDelta)
  if okd and wd == 0 then return end
  if C.target ~= nil and not registered(C.target) then C.target = nil end
  local held = nil
  pcall(function() held = g_Module:GetLockedAttackTarget() end)
  if held ~= nil and not registered(held) then held = nil end
  if C.target ~= nil then
    if not alive(C.target) then C.target = nil
    elseif held == nil then C.set(C.target) end
  end
  local ok, mode = pcall(function() return getPlayerCombatMode() end)
  local fighting = ok and mode and mode ~= 0
  -- What the player is already looking at wins over what scores best: the assist should help
  -- with the enemy they picked, not drag the camera off it onto a closer one.
  if fighting then
    local mo = C.under_reticle()
    if mo ~= nil and C.enemies[mo] ~= nil and not rawequal(mo, C.target) and alive(mo) then
      -- but not the instant it appears: while the assist is turning, whoever the view sweeps
      -- past crosses the reticle too, and taking that as the player's choice is what makes the
      -- camera swing back and forth between two bandits.
      if C.target == nil or (os.clock() - (C.target_since or 0)) > C.retarget_hold then
        C.set(mo)
      end
    end
  end
  if C.target == nil and fighting then C.acquire() end
  if fighting and C.target ~= nil then pcall(C.aim_publish) end
end

function C.status()
  local tx, ty, ready = C.aim_solve()
  local list = C.candidates()
  local s = "enemies=" .. table.getn(list) .. " target="
  if registered(C.target) then
    local ok, t = pcall(function() return C.target:GetObjectTag() end)
    s = s .. (ok and tostring(t) or "?")
  else
    s = s .. "-"
  end
  local ok2, held = pcall(function() return g_Module:GetLockedAttackTarget() end)
  s = s .. " lock=" .. tostring(ok2 and held)
  s = s .. string.format(" reticle=%s aim=%s,%s ready=%s off=%.0f",
        tostring(C.under_reticle() ~= nil), tostring(tx), tostring(ty), tostring(ready),
        C.aim_offset)
  for i = 1, math.min(table.getn(list), 6) do
    local tag = "?"
    pcall(function() tag = list[i].c:GetObjectTag() end)
    s = s .. string.format(" | %s d=%.1f", tostring(tag), list[i].d)
  end
  return s
end

C.hook()
log("combat targeting loaded")
