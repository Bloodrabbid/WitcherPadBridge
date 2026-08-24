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
if (-not $Game) {
    throw "Не нашёл $Name. Укажите папку игры явно: -Game `"D:\путь\к\$Name`""
}
Open-WxpLog $Game "install_windows.ps1"
Say "== игра: $Game =="

$Sys     = Join-Path $Game "System"
$Scripts = Join-Path $Sys  "Scripts"
$Backup  = Join-Path $Game "WitcherPadBridge\backup"
$Dll     = Join-Path $Root "bridge\windows\LightFX.dll"

if (-not (Test-Path $Dll))     { Fail "нет $Dll - соберите мост (bridge/windows/build.sh)" }
if (-not (Test-Path $Scripts)) { Fail "нет папки скриптов: $Scripts" }

New-Item -ItemType Directory -Force -Path $Backup | Out-Null
# debug.luc is the game's own script with one line added: the only script the engine loads
# unconditionally, hence the entry point. Keep the stock copy before replacing it.
$stock = Join-Path $Scripts "debug.luc"
$saved = Join-Path $Backup  "debug.luc"
if ((Test-Path $stock) -and -not (Test-Path $saved)) {
    Say "== бэкап штатного debug.luc =="
    Copy-Item $stock $saved
}

Say "== мост =="
$lfx = Join-Path $Sys "lightfx\wxp"
New-Item -ItemType Directory -Force -Path $lfx | Out-Null
Copy-Item $Dll (Join-Path $lfx "LightFX.dll") -Force

Say "== таблица скорости шага =="
# Немодифицированная игра до этой строки таблицы не доходит: клавиши «идти» нет, а startup.lua
# включает вечный бег. Она нужна только когда шаг просит пад.
$Data2da = Join-Path $Game "Data\2DA"
New-Item -ItemType Directory -Force -Path $Data2da | Out-Null
$SpeedSrc = Join-Path $Root "mod\data\2DA\CreatureSpeed.2da"
if (Test-Path $SpeedSrc) { Copy-Item $SpeedSrc $Data2da -Force }
else { Say "   (CreatureSpeed.2da нет в пакете - шаг останется штатным)" }

Say "== Lua-слой =="
$luc = @(Get-ChildItem (Join-Path $Root "mod\scripts\*.luc") -ErrorAction SilentlyContinue)
if ($luc.Count -eq 0) { Fail "в mod\scripts нет .luc - соберите пакет через tools/package.sh" }
foreach ($f in $luc) { Copy-Item $f.FullName $Scripts -Force; Say "   $($f.Name)" }

$ini = Join-Path $Game "gamepad.ini"
if (-not (Test-Path $ini)) {
    Say "== gamepad.ini по умолчанию =="
    Copy-Item (Join-Path $Root "mod\gamepad.ini") $ini
}

Write-WxpFiles @(
    (Join-Path $lfx "LightFX.dll")
    (Join-Path $Scripts "debug.luc")
    (Join-Path $Scripts "wxp_gamepad.luc")
    (Join-Path $Scripts "wxp_ui.luc")
    (Join-Path $Scripts "wxp_combat.luc")
    (Join-Path $Scripts "wxp_settings.luc")
    (Join-Path $Scripts "wxp_signwheel.luc")
    (Join-Path $Scripts "wxp_rumble.luc")
    $ini
)
Note "done."

Write-Host ""
Write-Host "Готово. Запускайте игру обычным способом."
Write-Host "  Настройки: $ini  (перечитывается на лету)"
Write-Host "  Лог моста: $Sys\wxp_bridge.log"
Write-Host "  Лог Lua:   $Sys\wxp_gamepad.log"
Write-Host "  Отчёт установки: $Game\WitcherPadBridge\install.log"
Write-Host "  Собрать всё для отчёта об ошибке: tools\diagnose.ps1"
Write-Host ""
Say "ВАЖНО: в Steam выключите Steam Input для этой игры" "Yellow"
Write-Host "  (Свойства -> Контроллер -> «Отключить Steam Input») или переведите в passthrough."
Write-Host "  Мод читает пад напрямую через XInput."
Write-Host ""
Write-Host "Проверка целостности файлов в Steam откатывает debug.luc - после неё"
Write-Host "запустите установщик ещё раз. Удаление: tools\uninstall_windows.ps1"
