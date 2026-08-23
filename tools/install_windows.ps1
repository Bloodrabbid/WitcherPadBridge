# WitcherPadBridge -- installer for Windows. Double-click install_windows.bat, or run:
#     powershell -ExecutionPolicy Bypass -File tools\install_windows.ps1 [-Game "D:\...\The Witcher Enhanced Edition"]
#
# On Steam Deck / Bazzite / any Proton setup use tools/install_win.sh instead -- same steps, bash.
#
# No injector and no patched executable: the game tries to load System\lightfx\wxp\LightFX.dll on
# every start by itself and carries on when it is missing. That is the entry point.
param([string]$Game = "")

$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $Here
$Name = "The Witcher Enhanced Edition"

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
if (-not $Game) {
    throw "Не нашёл $Name. Укажите папку игры явно: -Game `"D:\путь\к\$Name`""
}
Write-Host "== игра: $Game =="

$Sys     = Join-Path $Game "System"
$Scripts = Join-Path $Sys  "Scripts"
$Backup  = Join-Path $Game "WitcherPadBridge\backup"
$Dll     = Join-Path $Root "bridge\windows\LightFX.dll"

if (-not (Test-Path $Dll))     { throw "нет $Dll - соберите мост (bridge/windows/build.sh)" }
if (-not (Test-Path $Scripts)) { throw "нет папки скриптов: $Scripts" }

New-Item -ItemType Directory -Force -Path $Backup | Out-Null
# debug.luc is the game's own script with one line added: the only script the engine loads
# unconditionally, hence the entry point. Keep the stock copy before replacing it.
$stock = Join-Path $Scripts "debug.luc"
$saved = Join-Path $Backup  "debug.luc"
if ((Test-Path $stock) -and -not (Test-Path $saved)) {
    Write-Host "== бэкап штатного debug.luc =="
    Copy-Item $stock $saved
}

Write-Host "== мост =="
$lfx = Join-Path $Sys "lightfx\wxp"
New-Item -ItemType Directory -Force -Path $lfx | Out-Null
Copy-Item $Dll (Join-Path $lfx "LightFX.dll") -Force

Write-Host "== Lua-слой =="
$luc = @(Get-ChildItem (Join-Path $Root "mod\scripts\*.luc") -ErrorAction SilentlyContinue)
if ($luc.Count -eq 0) { throw "в mod\scripts нет .luc - соберите пакет через tools/package.sh" }
foreach ($f in $luc) { Copy-Item $f.FullName $Scripts -Force; Write-Host "   $($f.Name)" }

$ini = Join-Path $Game "gamepad.ini"
if (-not (Test-Path $ini)) {
    Write-Host "== gamepad.ini по умолчанию =="
    Copy-Item (Join-Path $Root "mod\gamepad.ini") $ini
}

Write-Host ""
Write-Host "Готово. Запускайте игру обычным способом."
Write-Host "  Настройки: $ini  (перечитывается на лету)"
Write-Host "  Лог моста: $Sys\wxp_bridge.log"
Write-Host ""
Write-Host "ВАЖНО: в Steam выключите Steam Input для этой игры" -ForegroundColor Yellow
Write-Host "  (Свойства -> Контроллер -> «Отключить Steam Input») или переведите в passthrough."
Write-Host "  Мод читает пад напрямую через XInput."
Write-Host ""
Write-Host "Проверка целостности файлов в Steam откатывает debug.luc - после неё"
Write-Host "запустите установщик ещё раз. Удаление: tools\uninstall_windows.ps1"
