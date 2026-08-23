-- WitcherPadBridge :: vibration.
--
-- The game has no rumble of its own: Witcher 1 is a 2007 PC title, there is not a single
-- vibration call in it, and the engine exports nothing of the sort to Lua (the full export list
-- pulled out of witcher.vpfs has exactly one shake-shaped name, ShakeCamera, and that moves the
-- camera). The eON wrapper, on the other hand, links Core Haptics and DirectInput force
-- feedback -- so the hardware road exists, it was just never driven. The bridge drives it, and
-- this file decides when.
--
-- The trigger that matters most is CNWCModule:OnCameraShake(vOffset): the engine calls it every
-- time something is supposed to shake the view, and hands over the offset, so the magnitude is
-- a ready-made intensity. Everything else here is a second opinion on top of that.
--
-- Channel: <game>/System/wxp_rumble.txt, one line "<seq> <low> <high> <ms>". low and high are
-- the two motors at 0..1000 -- the wire format follows XInput, the more constrained of the two
-- platform APIs, and macOS derives Core Haptics parameters from it.

wxp_rumble = {}
local R = wxp_rumble

local FILE = "wxp_rumble.txt"      -- cwd is the game's System/ dir

R.enabled = true
R.seq     = 0
R.last    = 0        -- os.clock of the last pulse
R.min_gap = 0.05     -- a melee exchange must not turn the pad into a doorbell
R.due     = nil      -- a pulse scheduled for later (the attack-chain tick)
R.due_lo  = 0
R.due_hi  = 0
R.due_ms  = 0
R.hp      = nil      -- last seen vitality, for spotting damage taken
R.trace   = false    -- log every pulse; useful while tuning, noisy otherwise

local function log(s) if wxp_log then wxp_log("rum: " .. tostring(s)) end end

-- ------------------------------------------------------------------ channel

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- low/high are 0..1 here; the file carries them as 0..1000 so the line stays integers and the
-- bridge never has to care what decimal separator this machine writes.
function R.send(low, high, ms)
  if not R.enabled then return end
  local now = os.clock()
  if now - R.last < R.min_gap then return end
  R.last = now
  R.seq = R.seq + 1
  local f = io.open(FILE, "w")
  if f == nil then return end
  f:write(string.format("%d %d %d %d\n", R.seq,
                        clamp(math.floor(low * 1000), 0, 1000),
                        clamp(math.floor(high * 1000), 0, 1000),
                        clamp(math.floor(ms), 10, 2000)))
  f:close()
  if R.trace then log(string.format("%.2f/%.2f %dms", low, high, ms)) end
end

-- A pulse that is supposed to land later. Only one is ever pending: these are cues, and a cue
-- that has been overtaken by the next one is not worth playing.
function R.schedule(delay, low, high, ms)
  R.due    = os.clock() + delay
  R.due_lo = low
  R.due_hi = high
  R.due_ms = ms
end

-- --------------------------------------------------------------- the feelings

-- Named so the table below reads as a list of things that happen in the game rather than as a
-- list of numbers: {heavy motor, light motor, milliseconds}.
R.feel = {
  shake_min   = {0.25, 0.05,  90},   -- the floor for a camera shake, scaled up by its size
  shake_max   = {1.00, 0.35, 220},
  hit_dealt   = {0.45, 0.30,  70},   -- our blow landed
  hit_taken   = {0.85, 0.25, 180},   -- Geralt lost vitality
  kill        = {0.70, 0.45, 200},
  chain       = {0.00, 0.55,  45},   -- the attack chain is ready for the next click
  sign        = {0.35, 0.55, 120},
  medallion   = {0.00, 0.35, 130},   -- the wolf medallion trembles near magic
  levelup     = {0.30, 0.60, 320},
  poisoned    = {0.55, 0.15, 260},
}

local function feel(name, scale)
  local f = R.feel[name]
  if f == nil then return end
  scale = scale or 1
  R.send(f[1] * scale, f[2] * scale, f[3])
end

R.feel_by_name = feel

-- ------------------------------------------------------------------ triggers

-- CNWCModule:OnCameraShake is the engine's own "something just shook the world" and it carries
-- how hard. Wrapped on the class, and kept aside the first time so reloading this file cannot
-- stack a second wrapper on top of the first.
function R.hook()
  if R.hooked then return true end
  if CNWCModule == nil or CNWCCreature == nil then return false end

  if wxp_shake_orig == nil then
    local o = CNWCModule.OnCameraShake
    if type(o) ~= "function" then return false end
    wxp_shake_orig = o
  end
  local shake = wxp_shake_orig
  function CNWCModule:OnCameraShake(vOffset)
    pcall(function()
      -- The offset is in world units and small; anything past a quarter unit already reads as
      -- a hard knock, so that is where the scale tops out.
      local m = 0
      if vOffset then
        local x, y, z = vOffset.x or 0, vOffset.y or 0, vOffset.z or 0
        m = math.sqrt(x * x + y * y + z * z)
      end
      local t = clamp(m / 0.25, 0, 1)
      local a, b = R.feel.shake_min, R.feel.shake_max
      R.send(a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t)
    end)
    return shake(self, vOffset)
  end

  -- OnHit fires on the attacker, so this is our blow connecting. It is the one cue the player
  -- cannot get from the screen alone in a crowd.
  if wxp_hit_orig == nil then
    local o = CNWCCreature.OnHit
    if type(o) == "function" then wxp_hit_orig = o end
  end
  if wxp_hit_orig then
    local hit = wxp_hit_orig
    function CNWCCreature:OnHit(pTarget)
      pcall(function()
        if g_Player and rawequal(self, g_Player) then feel("hit_dealt") end
      end)
      return hit(self, pTarget)
    end
  end

  R.hooked = true
  log("hooks installed (camera shake, hit)")
  return true
end

-- GUI events arrive through the single wrapper wxp_combat already owns; it forwards here rather
-- than us wrapping OnGuiEvent a second time and delivering everything twice.
function R.on_event(s, a1, a2)
  if not R.enabled then return end
  if s == "combatsequence.next" then
    -- The engine hands over the hit time of the next blow in the chain. That is exactly the
    -- moment the game wants the player to click -- its own tutorial card says an early click
    -- breaks the sequence -- so the tick is scheduled rather than played now.
    local t = tonumber(a2)
    if t and t > 0.05 and t < 3 then
      local c = R.feel.chain
      R.schedule(t, c[1], c[2], c[3])
    else
      feel("chain")
    end
  elseif s == "medallion.modechange" then
    feel("medallion")
  elseif s == "statspanel.levelup" then
    feel("levelup")
  elseif s == "playerhealth.poisoned" then
    feel("poisoned")
  elseif s == "spells.update" then
    feel("sign")
  end
end

-- --------------------------------------------------------------------- tick

-- Damage taken has no event of its own, so it is read off the player's vitality. Cheap: one
-- getter per heartbeat, and it is the same proxy wxp_combat already uses.
local function vitality()
  local v
  local ok = pcall(function()
    v = g_Player:GetCreatureProxy():GetCurrentVitalityPoints()
  end)
  if ok then return v end
  return nil
end

function R.tick()
  if not R.enabled then return end
  if R.due and os.clock() >= R.due then
    local lo, hi, ms = R.due_lo, R.due_hi, R.due_ms
    R.due = nil
    R.send(lo, hi, ms)
  end

  local hp = vitality()
  if hp ~= nil then
    if R.hp ~= nil and hp < R.hp then
      -- Scale with the size of the wound, but never below the floor: a scratch should still be
      -- felt, or the pad goes quiet exactly when the player is losing.
      local lost = R.hp - hp
      feel("hit_taken", clamp(0.5 + lost / 60, 0.5, 1))
    end
    R.hp = hp
  end
end

-- A short double tap, so "is vibration on at all" has an answer that does not require a fight.
function R.test()
  R.last = 0
  R.send(0.8, 0.2, 200)
end

log("vibration layer loaded")
