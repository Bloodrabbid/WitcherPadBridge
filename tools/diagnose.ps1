# WitcherPadBridge -- collect everything needed to diagnose "не работает" into one folder.
#
#     powershell -ExecutionPolicy Bypass -File tools\diagnose.ps1 [-Game "D:\...\The Witcher Enhanced Edition"]
#     (or double-click tools\diagnose.bat)
#
# On macOS, Steam Deck, Bazzite or any Proton setup use tools/diagnose.sh instead.
# Nothing is uploaded anywhere: this writes a folder and a .zip next to itself and prints the
# path. Look inside before sending it on -- the paths contain your user name. Save games and
# anything else personal are deliberately left out.
param([string]$Game = "")

$ErrorActionPreference = "Continue"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $Here
$Name = "The Witcher Enhanced Edition"

function Test-Game([string]$p) {
    if (-not $p) { return $false }
    return (Test-Path (Join-Path $p "System\witcher.ini"))
}

function Find-Game {
    $candidates = New-Object System.Collections.Generic.List[string]
    $steam = $null
    foreach ($k in @("HKCU:\Software\Valve\Steam", "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam")) {
        try { $steam = (Get-ItemProperty $k -ErrorAction Stop).InstallPath } catch { }
        if ($steam) { break }
    }
    if ($steam) {
        $candidates.Add((Join-Path $steam "steamapps\common\$Name"))
        $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $lib = $m.Groups[1].Value -replace '\\\\', '\'
                $candidates.Add((Join-Path $lib "steamapps\common\$Name"))
            }
        }
    }
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $d.IsReady) { continue }
        $candidates.Add((Join-Path $d.RootDirectory "Program Files (x86)\Steam\steamapps\common\$Name"))
        $candidates.Add((Join-Path $d.RootDirectory "GOG Games\The Witcher Enhanced Edition"))
        $candidates.Add((Join-Path $d.RootDirectory "SteamLibrary\steamapps\common\$Name"))
    }
    foreach ($c in $candidates) { if (Test-Game $c) { return $c } }
    return $null
}

if (-not $Game) { $Game = Find-Game }

$Stamp  = Get-Date -Format "yyyyMMdd-HHmmss"
$Out    = Join-Path $Root "wxp-diag-$Stamp"
New-Item -ItemType Directory -Force -Path (Join-Path $Out "logs")   | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Out "config") | Out-Null
$Report = Join-Path $Out "report.txt"

function H([string]$t)    { Add-Content $Report @("", "=== $t ===") -Encoding UTF8 }
function W([string]$t)    { Add-Content $Report $t -Encoding UTF8 }
function Size([string]$p) { if (Test-Path $p) { return (Get-Item $p).Length } return $null }

# An absent log is itself a finding, so say either way. gamepad.ini can exist in two places at
# once and which one the bridge read is half the question, so neither may overwrite the other.
function Grab([string]$Sub, [string[]]$Paths) {
    foreach ($p in $Paths) {
        if (Test-Path $p) {
            $base = Split-Path -Leaf $p
            $dest = Join-Path (Join-Path $Out $Sub) $base
            $n = 2
            while (Test-Path $dest) {
                $stem = [System.IO.Path]::GetFileNameWithoutExtension($base)
                $ext  = [System.IO.Path]::GetExtension($base)
                $dest = Join-Path (Join-Path $Out $Sub) "$stem-$n$ext"
                $n++
            }
            Copy-Item $p $dest -Force
            W ("  collected  {0}  ({1} bytes) -> {2}" -f $p, (Get-Item $p).Length, (Split-Path -Leaf $dest))
        } else {
            W ("  absent     {0}" -f $p)
        }
    }
}

Set-Content $Report @(
    "WitcherPadBridge diagnostics"
    "generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
) -Encoding UTF8

H "package"
W "package folder: $Root"
$verFile = Join-Path $Root "VERSION"
W ("version: " + $(if (Test-Path $verFile) { (Get-Content $verFile -Raw).Trim() } else { "unknown (source tree?)" }))
$dll = Join-Path $Root "bridge\windows\LightFX.dll"
if (Test-Path $dll) { W ("  {0} bytes  {1}" -f (Get-Item $dll).Length, $dll) }

H "host"
try { W ("os: " + (Get-CimInstance Win32_OperatingSystem).Caption) } catch { W ("os: " + [System.Environment]::OSVersion.VersionString) }
W ("build: " + [System.Environment]::OSVersion.VersionString)
W ("PowerShell: " + $PSVersionTable.PSVersion)
W ("64-bit OS: " + [System.Environment]::Is64BitOperatingSystem)

H "game"
if (-not $Game) {
    W "NOT FOUND. Rerun as: diagnose.ps1 -Game `"D:\путь\к\$Name`""
} else {
    W "folder: $Game"
    $Sys     = Join-Path $Game "System"
    $Scripts = Join-Path $Sys  "Scripts"
    W "system:  $Sys"
    # Writable or not decides whether the pad can talk to the script layer at all.
    $probe = Join-Path $Sys "wxp_diag_probe.tmp"
    try {
        Set-Content $probe "x" -ErrorAction Stop; Remove-Item $probe -Force
        W "System writable: yes"
    } catch {
        W "System writable: NO  <-- the channels live there; nothing will work"
    }

    H "installed files"
    W " -- the bridge --"
    $lfx = Join-Path $Sys "lightfx\wxp\LightFX.dll"
    if (Test-Path $lfx) { W ("  {0} bytes  {1}" -f (Get-Item $lfx).Length, $lfx) }
    else { W "  MISSING  $lfx   <-- the game loads the bridge from here; rerun the installer" }
    W " -- the script layer --"
    foreach ($n in @("debug", "wxp_gamepad", "wxp_ui", "wxp_combat", "wxp_settings", "wxp_signwheel")) {
        $f = Join-Path $Scripts "$n.luc"
        if (Test-Path $f) { W ("  {0} bytes  {1}" -f (Get-Item $f).Length, $f) }
        else { W "  MISSING  $f" }
    }
    # debug.luc is the entry point: without our line in it nothing Lua-side ever runs. Steam's
    # file verification restores the stock copy, which is the usual way this breaks.
    $dbg = Join-Path $Scripts "debug.luc"
    if (Test-Path $dbg) {
        $bytes = [System.IO.File]::ReadAllBytes($dbg)
        $text  = [System.Text.Encoding]::ASCII.GetString($bytes)
        if ($text -match "wxp_gamepad") { W "  debug.luc calls wxp_gamepad: yes" }
        else { W "  debug.luc calls wxp_gamepad: NO  <-- Steam verify probably restored it; rerun the installer" }
    }

    H "logs"
    Grab "logs" @(
        (Join-Path $Sys "wxp_bridge.log")
        (Join-Path $Sys "wxp_bridge.log.1")
        (Join-Path $Sys "wxp_gamepad.log")
        (Join-Path $Sys "wxp_gamepad.log.1")
        (Join-Path $Game "WitcherPadBridge\install.log")
    )

    H "config and channels"
    Grab "config" @(
        (Join-Path $Game "gamepad.ini")
        (Join-Path $Sys  "wxp_config.ini")
        (Join-Path $Sys  "wxp_state.ini")
        (Join-Path $Sys  "wxp_nav.txt")
        (Join-Path $Sys  "wxp_aim.txt")
    )
}

H "controllers"
# Steam Input hides the pad from XInput, which is the single most common Windows-side failure.
try {
    Get-PnpDevice -PresentOnly -ErrorAction Stop |
        Where-Object { $_.FriendlyName -match "Controller|Gamepad|XBOX|DualS|Wireless" } |
        ForEach-Object { W ("  {0}  [{1}]" -f $_.FriendlyName, $_.Status) }
} catch { W "  (Get-PnpDevice unavailable on this host)" }

H "steam input"
$steamProc = Get-Process -Name steam -ErrorAction SilentlyContinue
W ("steam running: " + $(if ($steamProc) { "yes" } else { "no" }))
W "If the pad is listed above but the game ignores it, turn Steam Input OFF for this game"
W "(Properties -> Controller -> Disable Steam Input). The bridge reads XInput directly."

H "running processes"
$p = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match "^witcher" }
if ($p) { $p | ForEach-Object { W ("  {0}  pid {1}" -f $_.ProcessName, $_.Id) } }
else    { W "  (the game is not running)" }

try {
    Compress-Archive -Path $Out -DestinationPath (Join-Path $Root "wxp-diag-$Stamp.zip") -Force
} catch { }

Write-Host ""
Write-Host "Собрано: $Out"
Write-Host "Архив:   $(Join-Path $Root "wxp-diag-$Stamp.zip")"
Write-Host ""
Write-Host "Загляните в report.txt перед отправкой - там пути с вашим именем пользователя."
