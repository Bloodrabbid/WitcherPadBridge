local function listnewglobal(t, i, v)
  local sInvSyntax = ""
  
  local bInvSyntax = false
  if type(v) == "function" then
    if string.sub(i, 1, 1) ~= string.lower(string.sub(i, 1, 1)) then
      bInvSyntax = true
    end
  else
    local bConstant = false
    local bGlobal = false
    if string.sub(i, 1, 2) == "g_" or string.sub(i, 1, 3) == "lg_" then
      bGlobal = true
    end
    if string.upper(i) == i then
      bConstant = true
    end
    if not bConstant and not bGlobal then
      bInvSyntax = true
    end
  end
  if bInvSyntax then
    sInvSyntax = " -- INVALID NAME !!!!!!!!!!!!!!!!!"
    AurPrintf("Variable " .. i .. " has invalid name")
  end
  g_DumpGlobals:write(type(v) .. "\t" .. i .. "\t" .. sInvSyntax .. "\n")
  g_DumpGlobals:flush()
  rawset(t, i, v)
end

if DEBUG_LIST_GLOBALS then
  g_DumpGlobals = io.open("dump_luaglobals.txt", "w")
  local T = getmetatable(getfenv())
  T.__newindex = listnewglobal
  setmetatable(getfenv(), T)
end

function dbgAttack()
  g_cAuroraSettings.m_bAurPrintfEnable = true
  g_cAuroraSettings.m_bDumpPlayerAttackData = true
  g_cAuroraSettings.m_bDumpPlayerAnimations = true
  g_cAuroraSettings.m_bDumpPlayerCombatRounds = true
  g_cAuroraSettings.m_bDumpPlayerAnimationsOnServer = true
end

function restarmodule()
  console("runscript restartmodule")
end

-- WitcherPadBridge entry point
pcall(function()
  g_Lua:PlayFile("wxp_gamepad")
end)
