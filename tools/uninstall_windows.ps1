# WitcherPadBridge -- remove the mod from the Windows build. Double-click uninstall_windows.bat.
param([string]$Game = "")

$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $Here
$Name = "The Witcher Enhanced Edition"
. (Join-Path $Here "_log.ps1")

function Test-Game([string]$p) {
    if (-not $p) { return $false }
    return (Test-Path (Join-Path $p "System\witcher.ini"))
}

function Find-Game {
    $candidates = New-Object System.Collections.Generic.List[string]
    # Steam's own library list is the only source that is right by construction.
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

if ($Game) {
    if (-not (Test-Game $Game)) { throw "В `"$Game`" не видно System\witcher.ini - это не папка игры." }
} else {
    $Game = Find-Game
}
if (-not $Game) { throw "Не нашёл $Name. Укажите папку игры: -Game `"D:\путь\к\$Name`"" }
Open-WxpLog $Game "uninstall_windows.ps1"
Say "== игра: $Game =="

$Sys     = Join-Path $Game "System"
$Scripts = Join-Path $Sys  "Scripts"
$Backup  = Join-Path $Game "WitcherPadBridge\backup"

Say "== мост =="
Remove-Item (Join-Path $Sys "lightfx\wxp\LightFX.dll") -Force -ErrorAction SilentlyContinue
foreach ($d in @("lightfx\wxp", "lightfx")) {
    $p = Join-Path $Sys $d
    if ((Test-Path $p) -and -not (Get-ChildItem $p -Force)) { Remove-Item $p -Force }
}

Say "== Lua-слой =="
Get-ChildItem (Join-Path $Scripts "wxp_*.luc") -ErrorAction SilentlyContinue | Remove-Item -Force
$saved = Join-Path $Backup "debug.luc"
if (Test-Path $saved) {
    Copy-Item $saved (Join-Path $Scripts "debug.luc") -Force
    Say "   debug.luc восстановлен из бэкапа"
} else {
    Say "   бэкапа debug.luc нет - восстановите его проверкой целостности файлов в Steam"
}

Note "done."
Write-Host ""
Write-Host "Удалено. gamepad.ini оставлен на месте - сотрите вручную, если он больше не нужен."
