# WitcherPadBridge — полноценная поддержка геймпада для The Witcher: Enhanced Edition

## Context

Цель — сделать так, чтобы в The Witcher EE можно было «запустить и играть» с геймпада, как в новых
частях: аналоговое движение и камера, бой с мягким автонаведением, знаки/зелья, полная навигация по
меню/инвентарю/диалогам/карте, плюс **вкладка настроек геймпада внутри игры**. Внешние мапперы
(Steam Input, антимикро и т.п.) не нужны — ощущение нативное; под капотом допустим синтез ввода
внутри процесса. Результат — устанавливаемый мод.

Два уровня тестирования: (1) эта Mac-машина, нативный eON-порт, DualSense; (2) ROG Xbox Ally X с
Bazzite — Windows-версия под Proton, Xbox-раскладка. Поэтому **ядро мода кросс-платформенное**
(живёт в данных игры + один общий Win32-DLL), а не в macOS-обёртке.

Почему это вообще возможно (разведка, всё подтверждено чтением файлов и дизасмом):
- eON-обёртка на каждом запуске пытается загрузить `System\lightfx\wxp\LightFX.dll` (AlienFX LightFX)
  и умеет JIT-транслировать произвольные PE. Тот же путь работает под Wine/Proton → **один 32-битный
  DLL исполняется на обеих платформах** без патча самой игры.
- Весь UI игры — 161 файл Lua 5.0.2 (байткод с debug-инфо) прямо в `System/Scripts/`, легко
  декомпилируется/редактируется. Движок экспортирует в Lua ~1281 метод (камера, игрок, бой, ввод,
  настройки), есть пофреймовый апдейт (`RegisterUpdate`/`SetUpdateHandler`) и полный набор stdlib (io/os).
- Меню опций описано в Lua → вкладку «Gamepad» можно добавить малыми правками.
- Нативный джойстик-путь движка есть, но убог (2 кнопки + 2 оси + hat) → как основа не годится,
  только как диагностика.

## КЛЮЧЕВАЯ ПОПРАВКА (найдена при проектировании, дизасм eON)

`keybd_event` в обёртке — **пустышка (no-op)**; `SendInput` для клавиатуры лишь постит WM-сообщения,
а мышь — только двигает курсор. **Aurora читает ввод через DirectInput, не через WM.** Значит синтез
через keybd_event/SendInput игра НЕ увидит. Основной механизм синтеза →
**хук COM-vtable у `IDirectInputDevice8`: `GetDeviceState` (индекс 9) и `GetDeviceData` (индекс 10)**
на клавиатурном и мышином устройствах игры (общая vtable — берём указатель, создав своё
SysKeyboard/SysMouse-устройство; `VirtualProtect` + подмена слотов). Идентично на eON и Wine/Proton.

## Архитектура

**A. WitcherPadBridge — Win32 x86 DLL** → `System/lightfx/wxp/LightFX.dll` (MinGW i686, один бинарь
   Mac+Proton). Экспортирует LightFX API (`LFX_Initialize/Light/Release/Update/...`) заглушками, чтобы
   игра сама его подхватила. Модули:
   - `pad_reader` — свой DirectInput8, `EnumDevices(DI8DEVCLASS_GAMECTRL)`, `c_dfDIJoystick2`, поллинг,
     переакквайр на hot-plug;
   - `synthesizer` — vtable-хук DI-клавиатуры/мыши: подмешивает наши скан-коды в 256-байтный state и/или
     буферные `DIDEVICEOBJECTDATA`; правый стик → mouse-дельты lX/lY; кнопки → игровые действия/LMB/RMB;
   - `mapper` — состояние пада + режим → набор виртуальных действий (по конфигу: раскладка, deadzone,
     сенса, кривые, инверсия);
   - `config_watcher` — читает `gamepad.ini` (пишет Lua-меню), следит за mtime; читает канал режима из Lua;
   - `logger` → `wxp/bridge.log` в write-dir.
**B. Lua-мод** (`System/Scripts`): вкладка «Gamepad» в настройках + пофреймовая логика (режимы,
   радиальное меню знаков/зелий, мягкий автотаргет в бою, навигация диалогов/списков).
   - Lua→DLL: `gamepad.ini` + `gamepad_state.ini` (режим/такт, только на переходах);
   - DLL→Lua: инъекция скан-кодов игровых действий; для наблюдения из Lua — выделенный «виртуальный
     клавиш» через `isKeyDown` и/или значение в state-файле.
   - **Приоритет — минимум правок shipped-файлов**: по возможности регистрировать вкладку и логику из
     ДОБАВЛЕННЫХ модулей (`wxp_gamepad_*.lua`) через `RegisterLuaSetting` в рантайме (переживает Steam-verify).
**C. `SDLGamepad.config`** → `~/Library/Application Support/com.cdprojektred.TheWitcher/` (Mac):
   современные маппинги (DualSense/Xbox Series — встроенная база eON ~2015 их не знает).
**D. Дистрибуция**: инсталлятор Mac + инструкция Windows/Proton (Bazzite), README RU/EN, бэкап/аптускейл.

## План работ

### Фаза 0 — тулчейн и пробы, снимающие риски (по ценности информации)
Итерация: правка → запуск → чтение логов (`eon.txt`, `lightfx.txt`, свой `bridge.log`). Для скорости —
перевести игру в оконный режим 1280×720 через игровое меню (пишет в реестр `Settings`: FullScreen=0,
VideoModeWidth/Height); сейчас 800×600 fullscreen.

0.1 **PE грузится? (гейт всего)**: `brew install mingw-w64` → `i686-w64-mingw32-gcc`; собрать минимальный
    `LightFX.dll` (DllMain пишет `wxp_probe.txt`, экспорты через `.def`, `-Wl,--kill-at`), положить в
    `System/lightfx/wxp/`. Успех: `lightfx.txt` без ошибки 0x2 / появился probe-файл / в `eon.txt` есть
    загрузка+JIT. Провал → Mac: dylib через `DYLD_INSERT_LIBRARIES` (бинарь не стрипнут), Proton: остаётся DLL.
0.2 **Проверить синтез**: в probe-DLL (а) keybd_event/SendInput жмут W — ожидаемо НЕ работает; (б)
    vtable-хук `GetDeviceState` DI-клавиатуры выставляет DIK_W → Геральт идёт. Заодно понять
    immediate (state) vs buffered (`GetDeviceData`) — определяет способ инъекции.
0.3 **Камера мышью**: хук `GetDeviceState`/`GetDeviceData` DI-мыши, прибавлять lX → камера крутится;
    проверить LMB-инъекцию (клик в меню/HUD). Fallback: `MouseDeltas_RegisterForMouseDelta`(Mac)/Lua
    `SetMousePosition`+`EnableManualCamera`.
0.4 **Lua round-trip**: unluac (поддержка 5.0, под установленным openjdk) декомпилит `cprogressbar.luc`;
    luac 5.0.3 с патчем `ldump.c` (size_t/длины — 4 байта) даёт header
    `1b4c756150010404040608090908`; сверка `luac -l` + `cmp`, загрузка в игре без Lua-ошибки.
0.5 **Грузится ли голый .lua при отсутствии .luc?**: добавить `wxp_probe_mod.lua`, `dofile` из хука.
    Да → шипаем исходники для новых файлов (без luac), правим `.luc` только если иначе никак.
0.6 **Диагностика нативного пути (10 мин, для полноты)**: Steam LaunchOptions `--eon_log_gamepads`;
    реестровая проба Joystick Button — подтвердить тупик и что eON видит DualSense (VID 045E/PID 0202).
0.7 **Видимость DualSense**: USB и Bluetooth, приложение frontmost; проверить, что Steam Input (если
    включён) не перехватывает пад мимо GameController. Рекомендация: Steam Input off / passthrough.

### Фаза 1 — играбельное ядро (DLL)
Модули A целиком. Дефолтные раскладки Xbox/PS для ~44 действий Witcher 1: левый стик — движение
(WASD/drive-mode), правый — камера, A/Cross — атака (LMB), стили Z/X/C, знаки 1–5, зелья 6–8, панели,
quicksave/load, медитация, вытаскивание меча, зум/лок камеры. Deadzone + кривая + сенса по осям + инверсия.
**Переключение режимов** (геймплей/меню/диалог/радиалка/миниигра/медитация): DLL сам режим не знает —
**Lua сигналит режим в `gamepad_state.ini` на переходах**, DLL поллит каждый тик.

### Фаза 2 — Lua-слой
Файлы: `hwdepsettings.luc`(лучше добавить `wxp_gamepad_settings.lua` с `RegisterLuaSetting`),
`gui_new_system_settingspanel.luc`(+"Gamepad" в список вкладок), `gui_defs_sys_v2.luc`(кнопка вкладки),
опц. `gui_new_system_controlspanel.luc`; новый `wxp_gamepad_runtime.lua` (поллер+режимы+радиалка+таргет).
Настройки — типы ST_CHECKBOX/ST_CONTINOUS/..., персист `Write/ReadSettingIniEntry`→`gamepad.ini`, БЕЗ
NeedsRestart. Лейблы literal String (TLK не трогаем). Радиалка: сперва пробуем спящие движковые экшены
`ActivateOwnRadial`/`RadialN..NW` (оверрайд `Data/2DA/keymap.2da`); если мертвы — своя Lua-панель
(`PerformCastSpell`/`PerformUseItem`). Бой: автотаргет через `SetLockedAttackTarget` или снап курсора
`MapToScreen`+`SetMousePosition`. Диалоги/списки: `ListBoxUp/Down/Left/Right`. Определение
«активен геймпад» — heartbeat через `isKeyDown`/state-файл.

### Фаза 3 — полировка
Кривые/ускорение камеры, раздельная сенса H/V; (опц.) глифы кнопок в подсказках (Xbox/PS по
`productCategory`); (опц.) вибрация принудительным `CreateEffect` (DIDEVCAPS FF не заявляет → пробуем и
тихо отключаемся); edge-cases: alt-tab (сброс зажатых клавиш), hot-plug, миниигры (кости/покер/кулачные),
медитация.

### Фаза 4 — дистрибуция и уровень 2 (Ally/Bazzite/Proton)
Манифест: добавляемые — `LightFX.dll`, `wxp_gamepad_*.lua`, `Data/2DA/keymap.2da`, `SDLGamepad.config`,
`gamepad.ini`, README, инсталлятор; изменяемые shipped (минимум) — 2–3 `.luc` (или ноль, если рантайм-
регистрация в 0.5 сработала). Mac-инсталлятор копирует файлы + `SDLGamepad.config` в write-dir + бэкап +
аптускейл после Steam-verify. Bazzite: тот же DLL (Wine грузит PE нативно) + Scripts + 2DA; Steam Input
off/passthrough (DLL читает DirectInput). Предупреждение: Steam-verify восстанавливает изменённые `.luc`
(добавленные файлы обычно остаются) → отсюда упор на рантайм-регистрацию и шаг «переприменить».

## Verification
- Фаза 0 DoD: PE грузится; синтез доказан (Геральт идёт от vtable-хука); Lua round-trip чист; известно,
  грузится ли `.lua`.
- Фаза 1 DoD: только с DLL — аналоговое движение + камера правым стиком + базовые кнопки в игре;
  deadzone/сенса из ini; alt-tab/hot-plug не залипают.
- Фаза 2 DoD: вкладка Gamepad в опциях и персистит; меню/инвентарь/диалог/карта/журнал — с пада;
  радиалка знаков/зелий; бой играбелен только падом.
- Фаза 4 DoD: чистая установка/удаление на Mac и на Ally под Proton; обе платформы проходят
  «запустил и играешь».
- **«Запустил и играешь»**: с холодного старта только геймпадом — пройти главное меню, загрузить сейв,
  ходить левым стиком, крутить камеру правым, драться (атака + знак + зелье) с автотаргетом, открыть и
  использовать инвентарь/журнал/карту, вести диалог, поменять настройку геймпада — без клавы/мыши и без
  внешних запусков.

## Risk register (риск → фолбэк)
1. eON не грузит наш PE → полный набор LFX-экспортов; иначе Mac=dylib(DYLD_INSERT), Proton=DLL.
2. keybd_event/SendInput не питают DI (ожидаемо) → **vtable-хук GetDeviceState/GetDeviceData** (основной);
   если vtable недоступна → IAT-патч `DirectInput8Create`/нативные символы eON на Mac.
3. Игра читает буферно (`GetDeviceData`) → инъекция и state, и `DIDEVICEOBJECTDATA` (проба 0.2/0.3 решит).
4. unluac ломается на больших файлах → рантайм-`RegisterLuaSetting` из добавленных `.lua`; иначе
   байткод-патч или шип `.lua` (если 0.5 позволит).
5. Движковая радиалка мертва → своя Lua-панель по значению октанта от DLL.
6. Камера мышь-дельтой не идёт → `MouseDeltas_*`(Mac)/Lua `SetMousePosition`+manual-camera API.
7. Steam Input прячет пад → документируем off/passthrough (Mac и Ally).
8. Steam-verify восстанавливает `.luc` → минимум правок + рантайм-регистрация + шаг переприменения.

## Критические файлы
- `.../System/Scripts/hwdepsettings.luc`, `gui_new_system_settingspanel.luc`, `gui_defs_sys_v2.luc`,
  `gui_new_system_controlspanel.luc`, `gui.luc`
- `.../Data/2da00.bif` (keymap.2da/actions.2da/actiontypes.2da) → оверрайд `.../Data/2DA/`
- `.../System/witcher.ini`, `.../System/restype.ini`
- `.../The Witcher.app/Contents/MacOS/The Witcher` (референс DI-vtable/GetDeviceState/GetDeviceData)
- `~/Library/Preferences/com.vpltd.EonRegistry.plist` (реестр/биндинги)
- `~/Library/Application Support/com.cdprojektred.TheWitcher/` (eon.txt, DataChanges/, GameDocuments/, SDLGamepad.config)

---
## ЖУРНАЛ ИСПОЛНЕНИЯ

### Фаза 0 — прогресс
- Тулчейн: mingw-w64 (i686-w64-mingw32-gcc 16.2.0) установлен; openjdk есть; lua/luac НЕТ (нужно для 0.4).
- Собрана probe-DLL `WitcherPadBridge/probe/LightFX.dll` (i686 PE): 19 LFX-экспортов (undecorated,
  --kill-at), самопиннинг модуля, воркер-поток (лог своего пути, DI enum, vtable-хук kbd/mouse
  GetDeviceState/GetDeviceData, поллинг пада, контрольный keybd_event/SendInput), стабы LFX.
- Харнесс: `WitcherPadBridge/tools/launch.sh` (чистит логи+open), `collect.sh` (сводит все логи).

### НАХОДКА (прогон через `open`, до запрета запусков)
- Игровые DLL (binkw32/mss32/d3dx9_42/commonlibs) упакованы ВНУТРИ witcher.vpfs (на диске в System их нет).
  161 `.luc` — реально на диске (Lua-мод жизнеспособен).
- `eON_LoadLibraryEx()` порядок поиска (из строк бинаря): (as given, от CWD) → (eON dll directory) →
  (main executable path) → (user directory N). Детальные строки в лог не пишутся (уровень логирования).
- Наш DLL из `System/lightfx/wxp/` и корня НЕ загрузился (0x2). Вероятная причина: `open` не выставляет
  рабочую директорию (CWD), а Steam — выставляет (запускает из папки игры). Либо база «main exe path» =
  каталог нативного бинаря в .app, а не System.
- RE точного построения пути дорогой (адреса строк формируются adrp+add).

### ТЕКУЩИЙ ШАГ (ждёт запуска пользователем)
- DLL разложена в 18 мест (basename / lightfx/wxp/ / литеральные `lightfx\wxp\`) по 6 безопасным базам:
  game root, game/System, write-dir, DataChanges/System, GameDocuments, AppDataLocal.
  Внутрь подписанного `.app` НЕ клали (сломает подпись).
- DLL логирует свой полный путь (GetModuleFileNameA) → первый же успешный запуск покажет каноническую базу.
- НАДО: пользователь запускает игру (лучше через Steam — выставит CWD), с подключённым DualSense,
  доходит до меню (~20с), выходит. Затем читаем `collect.sh`. Ожидаем: путь загрузки, список DI-устройств
  (виден ли DualSense!), срабатывание хуков, значения осей пада.
- TODO после: убрать лишние копии, оставить канонический путь; поставить lua/luac 5.0 для 0.4.

### Фаза 0.4 — Lua-тулчейн: ГОТОВО и ПРОВЕРЕНО (без запуска игры)
- unluac.jar декомпилирует Lua 5.0 идеально (имена методов/локальных сохранены). 158/161 скриптов
  декомпилированы (3 пустышки: djinni_startup_local, mg_*_trash — неважны). Все в `tools/decompiled/`.
- Собран `tools/luac` (Lua 5.0.3, arm64) с патчами под целевой формат: Instruction→unsigned int (4б),
  DumpSize→4б, header size_t→4, LoadSize→4б, TESTSIZE size_t=4. (`tools/lua` — интерпретатор.)
- **Round-trip подтверждён**: заголовок нашего luac БАЙТ-В-БАЙТ = целевой `1b4c7561 5001 0404 0406 0809 0908`;
  наш luac ЗАГРУЖАЕТ оригинальные `.luc` игры; decompile→recompile cprogressbar даёт ИДЕНТИЧНУЮ
  последовательность опкодов (35/35). → можно свободно править любой из 161 UI-скриптов.
  (Осталось подтвердить, что игра исполняет наш recompiled .luc — нужен запуск.)

### Разбор UI (по декомпилированным исходникам) — план Фазы 2 уточнён
- **Бутстрап**: `startup.lua` в конце зовёт `g_Lua:PlayFile("debug")` и `startup_local` (при Debug Mode=1).
  Точка входа мода — 1 добавленная строка `g_Lua:PlayFile("wxp_gamepad")` в startup (единственная
  обязательная правка shipped-файла для загрузки логики).
- **Настройки**: `hwdepsettings.lua` (2645 строк). Паттерн: базы `CCheckBoxSetting`(ST_CHECKBOX),
  `CDiscreetSetting`(ST_DISCREET), `CContinousSetting`(ST_CONTINOUS, слайдер). Конкретная настройка =
  `makeClass(база)` + `GetClassName()`(ключ ini) + `GetCategory()` + `GetRange()/GetValueName()/ApplyChanges()`
  + `RegisterLuaSetting(C:new())`. Метка через `GetSettingName()`=`g_TalkTable:GetSimpleString(g_tOptionDescriptions[ClassName])`
  → для наших настроек ПЕРЕОПРЕДЕЛИТЬ `GetSettingName()` на литерал (TLK не трогаем). Персист:
  Write→`WriteSettingIniEntry(ClassName,val)` + дополнительно писать свой `gamepad.ini` через Lua io.
- **Вкладки**: `gui_new_system_settingspanel.lua` — жёстко `tSetNames={Gameplay,Graphics,Sound,Advanced}` +
  `l_tGuiButtonInfo` (кнопки, `SetType(категория)`); фильтр по `GetCategory()`. Вкладка «Gamepad» = добавить
  "Gamepad" в tSetNames + кнопку в l_tGuiButtonInfo + визуал в `gui_defs_sys_v2.lua`.
  **MVP-упрощение**: сначала `GetCategory()="Gameplay"` → настройки видны в существующей вкладке, НОЛЬ правок
  панели; отдельная вкладка — полировка.
- **Пофреймовый рантайм**: модель = `makeClass(CLuaPanel)` → `_MakePanel(layout,false,{...,"OnUpdate"},"modal")`
  → `self.lm_pPanel:RegisterUpdate()` → `OnUpdate(deltaT)` вызывается КАЖДЫЙ КАДР с дельтой (пример: gui_settings).
  Для always-on во время геймплея нужен постоянный скрытый апдейтер (проверить, тикает ли вне меню) —
  это для Фазы 2/3. `isKeyDown(id)` доступен (инвентарь использует для модификатора split-stack).

### АРХИТЕКТУРНЫЙ ВЫВОД (снижает риск)
- **Phase 1 = только DLL**: движение/камера/кнопки→существующие keybind'ы. Lua НЕ нужен для базового
  «ходить и драться». → как только DLL грузится и хук работает, есть играбельный core.
- **Phase 2 = Lua**: вкладка настроек (активна в меню — always-on не нужен), радиалка, автотаргет,
  навигация меню. Канал DLL→Lua: файл состояния пада (io) и/или инъекция виртуальных клавиш (isKeyDown).

### СЛЕДУЮЩИЙ ЗАПУСК (делает пользователь) — что нужно
- Запуск через **Steam** (важно: Steam ставит рабочую папку = корень игры → «as given»-резолв
  `lightfx\wxp\LightFX.dll` попадёт в уже разложенную `<game root>/lightfx/wxp/LightFX.dll`).
  Мой прошлый запуск был через `open` (CWD=/), поэтому не нашёл.
- DualSense подключён (USB предпочтительно), дойти до меню (~20с), выйти. Затем `tools/collect.sh`.
- Ждём в логах: OUR MODULE PATH (какая копия сработала → канонизируем путь, лишнее удалим),
  список DI-устройств (виден ли DualSense), срабатывание vtable-хуков kbd/mouse, значения осей пада,
  и «Parsed N mappings» если положим SDLGamepad.config.

### Прогон #2 (пользователь) — РЕЗУЛЬТАТ + КОРНЕВАЯ ПРИЧИНА
- ✅ eON ВИДИТ DUALSENSE: `Gamepads: setting up device: name: DualSense Wireless Controller`
  (Device GUID 4475616c...=ASCII "DualSense Wirele"). SDLGamepad.config найден (write-dir путь верный).
- ❌ DLL всё ещё не грузился (0x2). Дизасм eON_LoadLibraryExA: 4 попытки (as given→VPFS CWD via
  eON_GetFullPathNameA; main-exe-path; eON dll dir; user dir), спец-имена nvapi/atiadl отбрасываются.
- **КОРНЕВАЯ ПРИЧИНА НАЙДЕНА (статически)**: наш DLL импортировал `api-ms-win-crt-*.dll` (UCRT,
  Homebrew-mingw по умолчанию). eON эмулирует СТАРЫЙ msvcrt.dll и UCRT-apiset'ы разрешить не может →
  байндинг PE падает → LoadLibrary=NULL. Дело было НЕ в пути.
- **ФИКС**: переписал probe в freestanding (`probe/dllmin.c`): без CRT (свой memset/memcpy/форматтер,
  лог через kernel32 CreateFile/WriteFile), импорт ТОЛЬКО KERNEL32.dll; dinput8 — динамически
  (LoadLibrary/GetProcAddress). Собрано `-nostdlib -nodefaultlibs -ffreestanding -fno-builtin`,
  entry=_DllMainCRTStartup@12. Проверено: import table = только KERNEL32.dll.
- Разложено 18 копий (все — новый билд, md5 d44b1e9e...). Ждём прогон #3.
- ВАЖНО для реального моста: собирать ВСЁ freestanding (никакого UCRT). Это же ограничение для Фазы 1.

### Прогон #3 — freestanding тоже 0x2 → блокер ТОЧНО путь, не импорты
- Оба билда (CRT и freestanding) дают 0x2 (FILE_NOT_FOUND) → файл не находится ни в одной из 4 баз eON.
  (CRT-фикс всё равно нужен — без UCRT — но это не текущий блокер.)
- DYLD_INSERT на Mac НЕ вариант: .app подписан Developer ID, hardened runtime (flags 0x10000),
  entitlements только allow-jit (нет allow-dyld-environment-variables/disable-library-validation) →
  DYLD_INSERT игнорируется без переподписи бандла.
- VPFS_CWD (для «as given») в __bss, ставится в рантайме — статически не прочесть. Ресурсы игры
  (`.\Scripts`) находятся, но это другой резолвер (CExoResMan), не eON_LoadLibraryEx VPFS_CWD.
- РЕШЕНИЕ: `tools/trace_lightfx.sh` — `sudo fs_usage` покажет ТОЧНЫЕ пути, которые eON пробует для
  LightFX.dll. Даёт однозначный ответ за 1 запуск. После — кладём DLL ровно туда, чистим остальное.
- Freestanding LightFX.dll — валидный PE32 i386 (entry 0x704c1af0, IMAGE_FILE_DLL) → загрузится, как найдётся.

## 🔴 КОРНЕВАЯ ПРИЧИНА (окончательно, дизасм eON) — PE-DLL НА MAC НЕВОЗМОЖЕН

Цепочка: `eON_LoadLibraryExA` → `LoadWindowsPEFile` → **только `VPFS_Open`/`VPFS_Read`** (обычный
файловый API не используется). В `VPFS_Open` (0x10033e1ac) есть проверка расширения:
```
strcasecmp(end-4, ".exe") == 0  -> метка 0x10033e3a0
strcasecmp(end-4, ".dll") == 0  -> метка 0x10033e3a0
strcasecmp(end-3, ".ax")  == 0  -> метка 0x10033e3a0
иначе -> обычный путь (0x10033e230), где w25=1
0x10033e3a0:  w25 = 0
...
0x10033e760:  cbz w25, skip   ; при w25==0 ПРОПУСКАЕТСЯ eON_FileSystem::getInfo (stat реального диска)
```
→ **для `.dll` / `.exe` / `.ax` eON НЕ смотрит на реальный диск вообще — только внутрь witcher.vpfs.**
Это объясняет всё: 18 разложенных копий не сработали; игровые DLL грузятся из архива; `.luc` c диска
читаются нормально (не exec-расширение). Код ошибки 2 в lightfx.txt — ЗАХАРДКОЖЕН (`mov w0,2` перед
`eON_SetLastError`), поэтому вводил в заблуждение. Debug-логи попыток (уровень 5) включить нельзя:
порог в `eON_Logging::logMessageVA` жёстко ≥10.

Проверенные и отпавшие обходы:
- Репак witcher.vpfs: TOC в хвосте (offset 0x00f60610) — высокоэнтропийный/зашифрованный → дорого.
- Подмена нативным dylib вместо Windows-DLL: eON использует dlopen только для фиксированного набора
  встроенных модулей, generic-механизма нет.
- DYLD_INSERT_LIBRARIES: блокируется hardened runtime (flags 0x10000, entitlements только allow-jit)
  — но РАЗБЛОКИРУЕТСЯ ad-hoc переподписью .app (codesign -f -s - с нужными entitlements).

## Развилка (нужно решение пользователя)
1. **dylib + ad-hoc переподпись .app (рекомендую)**: нативный macOS-мост (arm64+x86_64), инъекция
   через DYLD_INSERT_LIBRARIES в Steam launch options. Хукаем НЕ-стрипнутые символы eON:
   DirectInputKeyboardDeviceImp::GetDeviceState/GetDeviceData, ...MouseDeviceImp..., пад берём из
   GameController/eON. Фиделити = как на Windows. Windows/Proton остаётся на PE-DLL (там всё работает).
   Цена: два тонких моста + шаг переподписи (обратимо, повторить после Steam-verify).
2. **Чистый Lua + helper-процесс**: без изменения бандла; хелпер читает пад и пишет состояние в файл,
   Lua читает пофреймово (io подтверждён в скриптах). Минусы: автозапуск хелпера на Mac под вопросом
   (os.execute идёт через эмулируемый CreateProcess), движение через WalkPlayerToPoint (click-to-move)
   — менее «нативное» ощущение.
3. **Windows-first**: делаем полный мод для Windows-версии (там PE-DLL + Lua работают уже сейчас),
   тестируем на Ally/Bazzite; Mac — потом вариантом 1.

## ✅ РЕШЕНИЕ ДЛЯ macOS: dylib + ad-hoc переподпись (выбор пользователя) — ТОЧКИ ИНЪЕКЦИИ НАЙДЕНЫ

Бинарь НЕ стрипнут → символы резолвим в рантайме через LC_SYMTAB + ASLR slide (dlsym не годится,
символы локальные `t`/`b`).

**Устройство клавиатуры (дизасм `DirectInputKeyboardDeviceImp::GetDeviceState` @ 0x1002f1ce8):**
```
if (!this[0x1c0]) -> DIERR_NOTACQUIRED
mutex = this + 0x80          (pthread_mutex)
if (this[0x1c1]) memcpy(dst, this + 0xC0, min(cb,256))    <-- СЫРОЕ состояние 256 байт по DIK-кодам
else  ... кастомный data format: список пар (DIK, offset) по this[0x1e0], читает те же this[0xC0+DIK]
```
→ **достаточно писать байты в `device+0xC0`** (0x80 = нажато), под мьютексом `device+0x80`.

**Как добраться до объекта (без хуков!):**
- `__ZL17gRawInputKeyboard` @ 0x101bd8ae0 — глобальный УКАЗАТЕЛЬ на keyboard-receiver
  (используется в `_RawInput_ProcessKeyboard`: `adrp x23,0x101bd8000; ldr x8,[x23,0xae0]`).
- `__ZL14gRawInputMouse`  @ 0x101bd8ad8 — то же для мыши.
- В `KeyboardEventReceiver::ProcessKeyDown` (0x1002f2e3c): `ldr x8,[x0,0x10]` → **device = receiver+0x10**.

**Ещё чище — звать родные обработчики eON** (сохраняют и буферные события, не только immediate state):
- `__ZN21KeyboardEventReceiver14ProcessKeyDownEjt` (this, uint, uint16 macOS-keycode; keycode < 0x1ff,
  транслируется таблицей `KeycodeToDirectInput::diTable` @ 0x101ad8f0c)
- `__ZN21KeyboardEventReceiver12ProcessKeyUpEjt`
- `__ZN18MouseEventReceiver17ProcessMouseMovedEj`, `...22ProcessMouseButtonDownEjh`, `...20ProcessMouseButtonUpEjh`

→ **ZERO-HOOK дизайн**: ни инлайн-патчей, ни W^X-проблем, ни JIT-конфликтов. Только чтение символов +
вызов родных функций / запись в состояние. Идентично по фиделити Windows-мосту.

Переподпись: `codesign -f -s - --options runtime --entitlements` c исходным allow-jit ПЛЮС
`disable-library-validation` + `allow-dyld-environment-variables`. Инъекция: Steam launch options
`DYLD_INSERT_LIBRARIES=/path/wxp_bridge.dylib %command%`.

### Реализация macOS-моста — СДЕЛАНО (ждёт проверки запуском)
- `bridge/macos/wxp_probe.c` → `wxp_bridge.dylib` (universal arm64+x86_64):
  резолв LC_SYMTAB+slide → `gRawInputKeyboard`/`gRawInputMouse`/`ProcessKeyDown`/`ProcessKeyUp`;
  воркер-поток циклом 3с: [пауза] → [МЕТОД A: state[DIK_W]=0x80 по device+0xC0] → [пауза] →
  [МЕТОД B: родной ProcessKeyDown/Up(W)]. Лог `/tmp/wxp_bridge.log`.
- `tools/resign.sh` — ВЫПОЛНЕН: .app переподписан ad-hoc, flags 0x10002(adhoc,runtime),
  entitlements: allow-jit + allow-unsigned-executable-memory + disable-library-validation +
  allow-dyld-environment-variables. Откат: Steam → Проверить целостность файлов.
- `tools/launch_injected.sh` — прямой запуск с DYLD_INSERT_LIBRARIES.
- Мёртвые 18 копий LightFX.dll удалены из игры (вектор невозможен на macOS); исходник остался в
  `probe/` для будущей Windows-сборки.
- ЖДЁТ: один запуск пользователем → смотреть `/tmp/wxp_bridge.log` (резолв символов, указатели) и
  идёт ли Геральт сам ~3 секунды из каждых 12 (метод A) и ещё 3с (метод B).

## ✅ ФАЗА 0 ЗАКРЫТА: мост работает на macOS (подтверждено вживую)

### Как запускать (важно!)
Игра при старте прыгает через Steam (`steam://` в бинаре) и теряет DYLD-инъекцию.
**Решение**: выставить `SteamAppId=20900` + `SteamGameId=20900` → steam_api не перезапускает процесс.
`tools/launch_injected.sh` делает это. Требует запущенный Steam.
- ❌ Параметры запуска Steam на macOS НЕ поддерживают `VAR=val %command%` (это Linux-синтаксис) → OS Error 260.
- ❌ Скрипт-обёртка вместо бинаря в бандле — Steam отказывается запускать.
- ❌ `LSEnvironment` в Info.plist — не доходит до процесса, запущенного Steam.
- ✅ Прямой запуск бинаря с env (SteamAppId + DYLD_INSERT_LIBRARIES) — РАБОТАЕТ.

### Подтверждено вживую (лог моста)
- dylib грузится в процесс игры; резолв LC_SYMTAB+slide работает (74983 символа).
- `_gKeyboardEventReceiver` @ +slide → **recv=0x400001609738**, `_gMouseEventReceiver` найден.
- **device = *(recv+0x10) = 0x400001609700**, т.е. recv = device+0x38 (приёмник встроен в устройство,
  обратный указатель device+0x48 — совпало с дизасмом CreateDevice).
- **state = device+0xC0 = 0x4000016097c0**; флаги: `acquired[0x1c0]=1` (игра активно читает!),
  `rawfmt[0x1c1]=1` → путь простого memcpy → запись байтов состояния работает.
- Инъекция клавиши изменила экран (скриншот до/после отличается) — канал живой.
- ВАЖНО: указатель периодически становится 0x0 (устройство пересоздаётся при смене режимов) →
  мост обязан перечитывать глобал каждый тик (уже реализовано) и переустанавливать удержание.

### Инструменты отладки
- Канал команд: `echo "<DIK_hex> <ms>" > /tmp/wxp_cmd`, метод `A`(сырое состояние)/`B`(родной вызов)
  через `/tmp/wxp_method`. Лог: `/tmp/wxp_bridge.log`.
- Скриншоты через `screencapture -x` работают → визуальная верификация без участия пользователя.
- Игра сейчас в ОКОННОМ режиме — удобно для итераций.

### Состояние бандла
- `.app` переподписан ad-hoc + entitlements (allow-jit, unsigned-exec-mem, disable-library-validation,
  allow-dyld-environment-variables). Оригинальный бинарь на месте (обёртка откачена), подпись валидна.
- Откат: `tools/uninstall_mac.sh` + Steam → Проверить целостность.

---
# (устаревший RESUME перенесён в конец файла)

## ФАЗА 1 — мост собран и запущен (v0.1)
`bridge/macos/wxp_bridge.m` — ObjC dylib, universal (arm64/arm64e/x86_64):
- резолв символов eON (LC_SYMTAB), zero-hook инъекция;
- **смещения подтверждены дизасмом**: клавиатура state=`dev+0xC0`, mutex=`dev+0x80`;
  мышь dX=`dev+0x88`, dY=`dev+0x8C`, кнопки=`dev+0xA0+n`, mutex=`dev+0xA8`; device=`*(recv+0x10)`;
- чтение пада через GameController (in-process) — **`gamepad: DualSense Wireless Controller` подтверждено**;
- deadzone + кривая отклика + сенса по осям + инверсия Y; горячая перезагрузка `gamepad.ini`
  из write-dir (проверяется по mtime);
- аккуратный релиз: храним свой набор удержаний (`g_held`), чужие клавиши не трогаем;
- цикл ~250 Гц.

Дефолтная раскладка v0.1: ЛС→WASD, ПС→камера(мышь), A→ЛКМ(атака), X→ПКМ(знак), Y→инвентарь(I),
B→Alt(подсветка), LB/RB→пред/след знак(-/=), LT/RT→быстрый/силовой стиль(X/Z),
D-pad↑↓←→→сталь(Q)/серебро(E)/групповой(C)/карта(M), Menu→Esc, Options→журнал(J).

### ВАЖНО (v0.2): Aurora читает клавиатуру БУФЕРИЗОВАННО
Запись только в массив мгновенного состояния (`dev+0xC0`) игрой НЕ видится —
`CExoInputInternal::ReadInputBuffer` читает буфер событий. Правильный способ — звать РОДНЫЕ обработчики:
- `KeyboardEventReceiver::ProcessKeyDown/ProcessKeyUp(self, 0, macOS_keycode)` — обновляют И состояние,
  И очередь событий. Принимают **macOS kVK-коды** (не DIK!), транслируются таблицей diTable.
- `MouseEventReceiver::ProcessMouseButtonDown/Up(self, 0, buttonIndex)` — аналогично для кнопок мыши.
- Дельты мыши по-прежнему пишем в `dev+0x88/0x8c` (ProcessMouseMoved берёт их из MouseDeltas_*, что нам
  не подходит) — проверить, видит ли игра; иначе разбирать буферный путь мыши.
Мост шлёт события ТОЛЬКО на переходах (нажатие/отпускание), храня свой набор удержаний.

## ✅ ФАЗА 1 — ввод ПОДТВЕРЖДЁН ВЖИВУЮ (клавиатура), найдена таблица действий

### Что реально сломано было
1. **`dwSequence` = 0.** Второй аргумент `ProcessKeyDown/Up/ProcessMouseButton*/ProcessMouseMoved`
   движок кладёт прямо в `DIDEVICEOBJECTDATA.dwSequence` (дизасм `0x1002f2f34: stp w22,w21,[sp,8]` /
   `0x1002f2f38: str w20,[sp,0x14]`). Теперь мост шлёт сквозной атомарный счётчик.
2. **Мышь: писать в `dev+0x88/0x8C` бесполезно** — это только immediate-состояние.
   Правильный путь (дизасм `MouseEventReceiver::ProcessMouseMoved` @ 0x10043e790):
   функция сама берёт дельту через `MouseDeltas_GetLastMouseDelta`, потом кладёт её И в
   `dev+0x88/0x8C`, И в буферный `std::deque<DIDEVICEOBJECTDATA>`.
   → мост прибавляет дельту в глобальный аккумулятор и зовёт родную `ProcessMouseMoved`:
   ```
   base = sym("__ZL17sMouseDeltasMutex")            // 0x101bd8898
   base+0x00 : pthread_mutex   base+0x40 : 4 слота по 12 байт {inUse,accX,accY}
   base+0x70 : float gDeltaX   base+0x74 : float gDeltaY
   ```
   Кросс-проверка: `__ZZ35MouseDeltas_FeedMouseDeltaFromEventE10lastDeltaX` == base+0x78 (сошлось).

### Подтверждено вживую (скриншоты до/после, канал /tmp/wxp_cmd)
W — Геральт идёт · Esc — открывается игровое меню · Q — достаёт стальной меч ·
F — переворот камеры · **F5 — «Игра сохранена»** · J — открывается Дневник.
→ канал ввода полностью рабочий, включая буферные действия и панели.
Инвентарь (I) и Карта (M) не открылись — почти наверняка сюжетная блокировка пролога
Каэр Морхена, а не баг моста (Дневник в том же состоянии открывается). Перепроверить в обычной локации.

### 🔑 РАСШИФРОВАНА таблица клавиш игры (`actions.2da` + реестр `Bindings`)
`Data/2da00.bif` — формат **BIFF V1.1**: заголовок 20 байт, запись таблицы ресурсов **20 байт**
`{u32 id; u32 flags; u32 offset; u32 size; u32 type}` (type 2017 = 2DA). Скрипт-экстрактор → /tmp/bifx.
`actions.2da` = ресурс #91: колонки Name/ActionType/ActionID/DefKey/DefKey2/StrRef.
Реестр `HKCU\Software\CD Projekt Red\Witcher\Bindings` хранит ровно эти DefKey (юзер ничего не менял).

**Внутренняя нумерация клавиш движка (выведена и проверена вживую):**
```
12..23  = F1..F12      (F5=16 QuickSave ✓, F9=20 QuickLoad ✓, F1..F3 = камеры)
26      = SelectChar   30..39 = цифры 0..9  (1..5 знаки = 31..35, 6..8 эликсиры = 36..38)
40,41,42,43 = второй набор движения (стрелки)     44,45 = зум камеры
79..104 = A..Z         (A=79 → Q=95 ✓ проверено, W=101 ✓, S=97 ✓, D=82 ✓, J=88 ✓, F=84 ✓)
106,107 = NextSign/PrevSign (за пределами букв, физическая клавиша не расшифрована — не нужна)
```
Дефолты игры: Forward W, Backward S, StrafeLeft A, StrafeRight D, SteelSword Q, SilverSword E,
ExtraWeapon1/2/3 R/T/U, ChatMode(68), NextWeapon(71)/PrevWeapon(70), StrongStyle Z, FastStyle X,
GroupStyle C, знаки Aard/Quen/Yrden/Igni/Axii = 1/2/3/4/5, эликсиры 6/7/8,
Inventory I, Character H, Map M, Diary J, Alchemy L,
IsoCamera F1, HybridCamera F2, TPPCamera F3, FlipCamera F, SwitchSide G, зум(44/45),
SelectChar(26), QuickSave F5, QuickLoad F9.
Свободные буквы для новых биндов: B(80) K(89) N(92) O(93) P(94) V(100) Y(103).

### Тестовый стенд (полностью автономный, без пользователя)
- `/tmp/wxp_cmd`: `k <kVK> <ms>` · `m <dx> <dy> <n>` · `b <0|1> <ms>` (0=ЛКМ,1=ПКМ).
- Скриншот окна игры: `screencapture -x -t jpg -R 131,205,810,640 f.jpg` (окно 800x600 у левого края).
- **Есть квиксейв** → после перезапуска: подождать меню, F9 (kVK 101) = быстрая загрузка.
- Лог: `/tmp/wxp_bridge.log` (в т.ч. построчные `key DOWN/UP kVK=N`).

### 🔴 ГЛАВНОЕ ОТКРЫТИЕ ПО МЫШИ: игра НЕ читает оси DirectInput
Камера и UI берут **позицию курсора**, а не DI-оси. Доказано: свайп реального курсора ОС
(`CGWarpMouseCursorPosition`) поворачивает камеру; запись в DI-оси — нет; клик через
`MouseEventReceiver::ProcessMouseButtonDown` в меню не нажимает пункт.

**Механизм курсора в eON (дизасм `GetCurrentCursorPosition` @ 0x100161444,
`SCH_SetCursorPos_simcall` @ 0x1003190d0, `-[eON_CustomWindow getMousePosFromEvent:]` @ 0x1002f9bb4):**
```
__ZL17sCurrentCursorPos  @ 0x101bd82c0   int x, int y   (экранные коорд., origin сверху-слева)
__ZL15sDeltasToIgnore.0/.1 @ 0x101bd82c8/0x2cc          (компенсация программных варпов)
__ZL9sClipping          @ 0x101bd82d0   0=реальный курсор, 1=виртуальный, 2=инициализирован
позиция = (sClipping==1) ? sCurrentCursorPos : NSEvent.mouseLocation
```
→ **Решение для камеры**: выставить `sClipping=1` (посеяв позицию из реального курсора, чтобы
камера не прыгнула) и каждый тик прибавлять дельту стика к `sCurrentCursorPos`.
ПРОВЕРЕНО ВЖИВУЮ: камера поворачивается. Бонус: игра сама переустанавливает курсор каждый кадр
(mouse-look), поэтому упора в край экрана нет и реальный курсор не двигается.

**Решение для кликов/наведения**: игра реагирует на оконные события, поэтому мост синтезирует
НАСТОЯЩИЕ `NSEvent` (`mouseEventWithType:`) и постит их себе же через `[NSApp postEvent:atStart:]`.
`getMousePosFromEvent:` всё равно берёт координату из `sCurrentCursorPos`, так что позиция события
нужна лишь правдоподобная. Полезные символы, если понадобится нижний уровень:
`__ZN10eON_Window10MouseMovedE8tagPOINT` @ 0x100383f88, `__Z14GetFocusWindowv`, `_sMainGameWindow`,
`_eON_Internal_PostMessageToThread` (threadId, hwnd, msg, wParam, lParam).

### Клики: путь и найденные грабли
- Обработчики мыши eON живут на **вью `eON_CustomWindow`** (не на окне `eON_TopWindow`).
  `respondsToSelector:` для `mouseDown:` истинно у любого NSResponder → проверять бесполезно,
  надо искать вью по имени класса в иерархии `[[NSApp keyWindow] contentView]`.
- `-[eON_CustomWindow mouseDown:]` (0x1002f9e00): `[self getMousePosFromEvent:ev]` →
  `eON_Window::MouseMoved(pt)` → бит кнопки в глобале 0x101c76168 → PostMessage WM_*BUTTON*.
  Значит вызов метода вью напрямую с синтезированным NSEvent — законный путь.
- ГРАБЛИ: `mouse_apply` отсекал клик проверкой `*gMouseEventReceiver != NULL`
  (DI-устройство мыши может вообще не создаваться). Пути разведены.
- Диагностика координат: можно спросить сам движок —
  `objc_msgSend(view, @selector(getMousePosFromEvent:), ev)` возвращает упакованный POINT
  в игровых координатах. Это же снимает вопрос о масштабе Retina/draw-area.
- Запасной вариант, если прямой вызов не сработает: `CGEventPostToPid(getpid(), ev)`
  (в свой же процесс, без прав Accessibility) либо прямой
  `_eON_Internal_PostMessageToThread(threadId=*(u32*)(win+0x60), hwnd=*(void**)(win+0x28),
   msg=0x201/0x202/0x204/0x205, wParam=btnmask, lParam=(y<<16)|x)`.

### Дефолтная раскладка v0.3 (по расшифрованным биндам)
ЛС — WASD · ПС — камера · A — ЛКМ (атака/действие) · B — Esc (отмена) · X — ПКМ (знак) ·
Y — I (инвентарь) · LB — Q (стальной) · RB — E (серебряный) · LT — X (быстрый стиль) ·
RT — Z (силовой стиль) · L3 — C (групповой) · R3 — F (переворот камеры) ·
крестовина ↑J дневник ↓M карта ←H герой →L алхимия · Menu — Esc · Options — F5 (быстрое сохранение).

## ✅ МЫШЬ ЗАРАБОТАЛА ПОЛНОСТЬЮ (камера + наведение + клик) — подтверждено вживую
- **`*gMouseEventReceiver == NULL`**: игра НИКОГДА не создаёт DirectInput-устройство мыши.
  Поэтому весь DI-путь для мыши мёртв, а старый `mouse_apply` из-за проверки `if (!recv) return;`
  вообще не доходил до кнопок. Пути разведены: оконные события шлём всегда.
- Рабочая схема: `sClipping=1` + сдвиг `sCurrentCursorPos` (позиция) И вызов
  `[eON_CustomWindow mouseMoved:/mouseDown:/mouseUp:/rightMouseDown:/rightMouseUp:]`
  с синтезированным NSEvent (реакция). Вью ищем по имени класса в `[[NSApp keyWindow] contentView]`.
- **Координаты 1:1 в точках**: `engine_pt = (screenX - winX - 1, screenY - winY - 32)`
  (32 = заголовок окна). Проверено запросом `getMousePosFromEvent:` у самого движка.
- **E2E ДОКАЗАНО ТОЛЬКО ИНЪЕКЦИЕЙ**: из главного меню наведено на «Загрузить» → клик → диалог
  сохранений → клик по строке сейва (подсветилась) → клик «Загрузить» → игра загрузилась в мир.
- Скорость камеры теперь в **пикселях/сек** и интегрируется по реальному `dt` (не зависит от
  частоты цикла/кадров), дробный остаток переносится. Дефолт 1400/900 в `gamepad.ini`.
- Мост отдаёт курсор обратно, как только двигается настоящая мышь (`cam_release_if_real_mouse`).


---
# ▶️ RESUME HERE (актуально)

## Где мы
**Фаза 1 по вводу ЗАКРЫТА на macOS.** Работают и подтверждены скриншотами:
клавиатура (движение, действия, панели, F5/F9), камера правым стиком, наведение и клики мышью,
полная навигация по меню только инъекцией (главное меню → Загрузить → выбор сейва → загрузка).
Ключевые открытия и адреса — выше по файлу (разделы «ГЛАВНОЕ ОТКРЫТИЕ ПО МЫШИ»,
«РАСШИФРОВАНА таблица клавиш», «МЫШЬ ЗАРАБОТАЛА ПОЛНОСТЬЮ»).

## Рабочий цикл (без пользователя)
1. Сборка: `cd ~/Documents/WitcherXinput/WitcherPadBridge/bridge/macos && clang -dynamiclib
   -arch arm64 -arch arm64e -arch x86_64 -O2 -fobjc-arc -framework Foundation -framework GameController
   -framework CoreGraphics -framework AppKit -o wxp_bridge.dylib wxp_bridge.m && codesign -f -s - wxp_bridge.dylib`
2. Запуск: `pkill -f "MacOS/The Witcher"; tools/launch_injected.sh` (Steam может быть закрыт).
   Игра стартует ~2 мин (логотипы+интро), 4×Esc доводят до главного меню, сейв грузится ~1.5 мин.
3. Команды: `echo "k <kVK> <ms>" > /tmp/wxp_cmd` · `p <dx> <dy> <n>` камера/курсор ·
   `b <0|1> <ms>` кнопка мыши. Лог `/tmp/wxp_bridge.log`.
4. Скриншот окна: `screencapture -x -t jpg -R <x>,<y>,<w>,<h>` — окно 800x600 переезжает между
   запусками, координаты снимать с полного скриншота (экран 3456x2234 px = 1728x1117 pt).

## Ближайшие шаги
1. Живой тест геймпадом у пользователя: подобрать `SensitivityX/Y` в `gamepad.ini` (сейчас 1400/900 px/с).
2. Проверить инвентарь (I) и карту (M) в обычной локации — в прологе Каэр Морхена они, похоже, заблокированы сюжетом.
3. Режимы: в меню правый стик должен двигать курсор медленнее и без «mouse-look»-логики;
   нужен признак «сейчас открыта панель» (Фаза 2, Lua).
4. Фаза 2 (Lua): вкладка Gamepad в настройках, радиалка знаков (клавиши 1..5 уже известны),
   мягкий автотаргет, навигация списков. Тулчейн готов (`tools/luac`, `tools/unluac.jar`, `tools/decompiled/`).
5. Фаза 4: переписать `tools/install_mac.sh` под схему SteamAppId+DYLD_INSERT; сборка PE-DLL для Proton.

## Не забыть
- `*gMouseEventReceiver == NULL` — DI-мышь у игры не существует, только оконный путь.
- Второй аргумент всех `Process*` — это `dwSequence`, ноль слать нельзя.
- `.app` подписан ad-hoc с entitlements; Steam-verify это откатит.

## ✅ ФАЗА 2 — ГЕЙТ ПРОЙДЕН: наш Lua исполняется в игре
- **Точка входа**: `System/Scripts/debug.luc` (всего 48 строк, грузится безусловно из `startup`).
  В конец добавлено `pcall(function() g_Lua:PlayFile("wxp_gamepad") end)`.
  Round-trip нашего luac на этом файле проверен: 132 опкода совпали с оригиналом.
  Бэкап оригинала: `<game>/WitcherPadBridge/backup/debug.luc`, откат — `tools/uninstall_lua.sh`.
- **Подтверждено вживую** (`<game>/System/wxp_gamepad.log`): наш `.luc` исполняется,
  `io` работает, **рабочая директория Lua = `<game>/System/`**.
- Что доступно НА МОМЕНТ ЗАГРУЗКИ debug: `g_Lua`(userdata), `g_pGuiMan`(userdata),
  `g_cAuroraSettings`(userdata), `isKeyDown`, `getRules`, `AurPrintf`, `console`, `makeClass`.
  Что ещё НЕ существует: `g_GuiInGame`, `g_pClientExoApp`, `CGuiInGamePanelManager`,
  `CGuiNewPanelManager`, `CLuaPanel`, `defineGUIPanel`, `g_tGuiTabsCaptions`.
  → хук обязан быть ОТЛОЖЕННЫМ. Приём: метатаблица глобалов с `__newindex` (сама игра так делает
  в `debug.lua`/`listnewglobal`) — ждём появления нужного класса и в этот момент ставим хук.
- **`isKeyDown(id)` доступен глобально** → это готовый канал «мост → Lua»: мост жмёт незанятую
  клавишу, Lua её видит. Свободные буквы: B(80) K(89) N(92) O(93) P(94) V(100) Y(103).
- Пофреймовый тик: панели игры его НЕ регистрируют (единственный `RegisterUpdate` — в
  `gui_settings.lua`). Шаблон свой: `makeClass(CLuaPanel)` → `_MakePanel(model, false, {"OnUpdate"},
  "default")` (**"default" = НЕмодальная**, "modal" перехватит ввод) → `lm_pPanel:RegisterUpdate()`.
- Вкладки панелей: `CGuiInGamePanelManager:SwitchPanel(nPanelPosition, sNewPanelName)`,
  подписи в `g_tGuiTabsCaptions`, набор вкладок в `pPanel.lm_tsTabs`.
  Панели: InGameInventoryPanel, InGameMap, InGameSummaryPanel(Hero), InGameQuestPanel(Log),
  InGameStatsPanel, InGameSkillsPanel, InGameSequencePanel, InGameSigns/Steel/SilverSwordPanel.
- Контролы панели перечислимы из Lua: `panel.m_Controls[name]`; из геттеров есть
  `GetPosition`, `GetScreenVector`, `GetName`, `GetControl`.

### Автоопределение режима в мосте (без Lua, уже в коде)
В геймплее движок переустанавливает `sCurrentCursorPos` каждый кадр (mouse-look), в панели/меню — нет.
Мост сравнивает записанное значение с прочитанным на следующем тике: совпало → UI, разошлось →
геймплей (гистерезис 3 тика). В UI-режиме скорость курсора берётся из `MenuSensitivity` (700 px/с).
Ограничение: признак обновляется только пока стик реально движется — окончательное решение всё равно
за Lua (панель сообщит режим явно).

### Lua-хук: двухуровневая отложенность — РАБОТАЕТ
`makeClass` НЕ вешает метатаблицу на сам класс (только на инстансы через `create()`),
поэтому перехват безопасен. Но нужны ДВА уровня ожидания:
1. глобал класса появляется как ПУСТАЯ таблица (`makeClass` вернул `{}`) — ловим через
   `__newindex` на таблице глобалов;
2. методы присваиваются позже — ловим через `__newindex` уже на самом классе
   (срабатывает, т.к. ключа ещё нет).
Подтверждено в логе: `global appeared: CGuiInGamePanelManager` → `hook installed: TogglePanel`
→ `hook installed: SwitchPanel`.
Правильный класс подтверждён статически: `gui.lua:93` — `self.lm_pPanelManager = CGuiInGamePanelManager:new()`,
доступен как `g_GuiInGame.lm_pPanelManager`; панели открываются через `:TogglePanel(name)`
(пример вызова — `gui_ingame_textpanel.lua:87`).

### Мост: команда `g <gx> <gy>` — управление меню БЕЗ скриншотов
`cursor_goto_game()` берёт рамку окна у AppKit и сам считает экранные координаты:
`screenX = gameX + winLeft + 1`, `screenY = gameY + winTop + 32`
(winTop в системе с началом сверху). Логирует и позицию окна. Пример из живого запуска:
`goto: game(403,312) -> screen(868,471) window at 464,127 size 800x628`.
Игровые координаты пунктов (рендер 800x600), замерены через `getMousePosFromEvent:`:
главное меню — ЗАГРУЗИТЬ (403,312); диалог загрузки — первый сейв (425,89), кнопка «Загрузить» (298,461).

### Чего НЕ удалось проверить (упёрлось в спящий монитор)
Событий `TogglePanel` в логе нет, потому что игра не доехала до мира: слепые клики по меню и
F9 (QuickLoad из главного меню) не сработали. Проверка «мы в мире» без экрана — инжект F5 и
проверка появления нового файла в `GameDocuments/The Witcher/saves` (работает надёжно).
Нужен один заход с живым экраном: довести до мира, открыть панель, снять `System/wxp_gamepad.log`.

### Канал Lua → мост: ГОТОВ и проверен (наполовину, без экрана)
- Lua на каждом `TogglePanel` пишет `<game>/System/wxp_state.ini`: `UI = <кол-во открытых панелей>`,
  `Panel = <имя первой>`. Мост поллит по mtime раз в ~100 мс.
- **ВАЖНО**: рабочая директория процесса игры = `<game>/System`, а НЕ корень игры
  (хотя лаунчер делает `cd "$GAME"`). Относительный путь `System/wxp_state.ini` не находится.
  Мост теперь строит абсолютный путь от `_NSGetExecutablePath` (4 уровня вверх от бинаря в .app).
- Проверено вживую подсовыванием файла руками:
  `lua: 1 panel(s) open -> UI mode` / `lua: 0 panel(s) open -> gameplay`.
  Приоритет: отчёт Lua авторитетен, эвристика по перецентровке курсора — фолбэк.
- Осталось проверить (нужен живой экран): что Lua реально пишет файл при открытии панели.

### Что движок отдаёт в Lua как события (полный список handler-имён)
`OnLMouseDown/Up/Drag`, `OnRMouseDown`, `OnHilite`/`OnUnHilite` (наведение на контрол!),
`OnTooltip`, `OnClick`, `OnUpdate`, `OnHeartbeat`, `OnModalEscKey`, `OnActivate`/`OnDeactivate`,
`OnToggleOn`/`OnToggleOff`, `OnDelete`, `OnPostAttachmentInitialize`.
**Генерического обработчика клавиш НЕТ** → клавиши в Lua только через `isKeyDown()` внутри `OnUpdate`.
Курсор из Lua можно ЧИТАТЬ (`g_pGuiMan:GetMousePos`, `g_pClientExoApp:GetMousePosition`),
но НЕ двигать → курсор остаётся за мостом, Lua даёт структуру и цели.

---
## СЕССИЯ 2026-08-23 — UI-навигация: развилка решена, работа поделена

### Две сессии Claude на одном проекте
Параллельно работает вторая сессия (witcherxinput-0b). Разделение зафиксировано:
- **Lua-слой** (`mod/scripts/wxp_gamepad.lua`, `mod/scripts/wxp_ui.lua`, `tools/repl.sh`,
  `tools/install_lua.sh`, канал `System/wxp_cmd.txt`) — за ней.
- **Мост и всё macOS-обвязка** (`bridge/macos/wxp_bridge.m`, `/tmp/wxp_cmd`, `gamepad.ini`,
  `tools/launch_injected.sh`, resign/install) — за этой сессией.
Не перезапускать игру без предупреждения второй стороны.

### ❗ Реальный баг, который держал весь UI-режим мёртвым
Мост парсил из `wxp_state.ini` только `UI=<n>`, а Lua давно пишет `Mode=world|ui`.
→ `g_lua_ui` никогда не менялся, UI-режим не включался. Исправлено: парсятся `Mode=`, `Panel=`, `UI=`.

### Инъекция клавиш РАБОТАЕТ (снят прошлый ложный вывод)
Esc стабильно переключает `Mode` world↔ui. Прошлые «F5 не создаёт сейв» — игра ещё грузилась,
а не сломанный канал. Проверять «мы в мире» надо циклом F5-до-появления-нового-сейва.
`isKeyDown()` инжектированные клавиши по-прежнему НЕ видит — как канал мёртв.

### 🔑 GUI-координаты игры — выведены и подтверждены вживую
- GUI-пространство **1024x768**, начало координат **снизу-слева**, ось Y вверх.
- `g_pGuiMan:GetMousePos(v)` отдаёт координаты РОВНО в том же пространстве, что
  `control.m_pModel:GetPosition() * 100` (Aurora-единицы ×100). Проверено: курсор, поставленный
  в точку модели ResumeButton, дал `mouse=358,115` при `model=3.5749,1.1549`.
- Абсолютная позиция контрола = `m_pModel:GetPosition()` (уже мировая; `= lm_Definition + panelPos`).
- **Якорь контрола — это его УГОЛ, не центр**: в точке якоря `InvSteelSword` хит-тест отдаёт
  соседний `BackSword`, +11 px по Y — уже `InvSteelSword`.
- `c:IsMouseInside()` — рабочий хит-тест, отличная безголовая проверка попадания.
- `m_pModel:GetBoundingBox()` на GUI-моделях **бросает ошибку** — размеры оттуда не взять.
- Окно 800x628 pt, тайтлбар 28 pt. Точка окна → GUI: `gui_x = 1.2779*pt_x + 1`,
  `gui_y = 762 - 1.279*pt_y`. Обратно: `pt_x=(gui_x-1)/1.2779`, `pt_y=(762-gui_y)/1.279`.
- Константы Aurora: `AURORA_X=10.24 AURORA_Y=7.68 RESOLUTION=1600x1200` (`cdefineguipanel.lua`).

### РЕШЕНИЕ по навигации в панелях: интенты, а не курсор
Вторая сессия доказала вживую, что контролы активируются прямо из Lua
(`c:OnLMouseDown() c:OnLMouseUp()` закрывает панель, `inv:ShowIndependent()` открывает инвентарь),
и построила фокус-кольцо с секциями. Значит **в панелях мосту курсор не нужен вообще**.
Курсор остаётся для: игровой камеры и ГЛАВНОГО МЕНЮ (там нет heartbeat, Lua не тикает).

**Канал «мост → Lua»**: `<game>/System/wxp_nav.txt`, одна строка `<seq> <intent>\n`,
мост перезаписывает, Lua читает на heartbeat и сравнивает seq (seq сбрасывается на 1 при
перезапуске процесса — сравнивать `~=`, не `>`).
Интенты: `up down left right activate cancel alt sect+ sect- tab+ tab-`.
Семантика (сторона Lua): up/down/left/right — шаг фокуса внутри секции; sect± — смена секции
(снаряжение → сумка → квестовые → фильтры → контейнер); tab± — вкладки панели;
activate — `OnDoubleClick` для слота / `OnLMouseDown+Up` для кнопки; alt — `OnRMouseDown+Up`.

### Мост v0.4 — три режима вместо двух
`gameplay` / `ui` (владеет Lua, шлём интенты) / `menu` (Lua не тикает → курсор + настоящие клики).
Различение: `wxp_state.ini` свежее 3 с ⇒ Lua жив. **Ожидается от Lua строка `Tick=<n>` раз в
секунду с heartbeat** — без неё признака «Lua жив» нет.
Раскладка UI: D-pad/левый стик → шаги фокуса (первый сразу, автоповтор 110 мс после 420 мс);
A activate · B cancel · Y alt · LT/RT sect∓ · LB/RB tab∓ · правый стик — курсор (MenuSensitivity).

### Полезное про инвентарь (из живых пробников)
`g_GuiInGame.lm_pNewInventoryPanel` → `lm_pEquipmentPanel` / `lm_pRepositoryPanel` /
`lm_pGroundPanel` / `lm_pTransferPanel`. Репозиторий — сетка `lm_nMaxXItems=15`,
`lm_tRepository[x][y]`. Слоты снаряжения (GUI px, y вверх): `InvSteelSword@687,431`
`InvSilverSword@489,431` `Armour@562,455` `WitcherModel@421,128` и т.д.
Классы контролов: уровень 0 — `SelectButton/DeselectButton/DimmButton/EnableButton/OnMouseEnter/
OnLMouseDown/OnLMouseUp`, уровень 2 — `IsMouseInside/GetTextLabel/SetScale/EnableHitChecks`.

### Грабли окружения
Несколько «залипших» фоновых шеллов из прошлых сессий каждые пару минут делали
`pkill -f "MacOS/The Witcher"` и перезапускали игру — из-за этого измерения врали (процесс
всегда был «молодой»). Найдены и убиты. При странных результатах — сначала `ps` на такие шеллы.

### ✅ macOS: мост больше не требует лаунчера (Фаза 4, часть)
`tools/inject_loadcmd.py` — добавляет/убирает `LC_LOAD_DYLIB @executable_path/wxp_bridge.dylib`
во все слайсы Mach-O. Пишет в padding между концом load-команд и первой секцией `__TEXT`
(там ~3.3 МБ нулей в x86_64 и ~4.5 МБ в arm64), размер файла НЕ меняется, remove даёт
побайтно идентичный оригинал (проверено md5).
`tools/install_mac.sh` — бэкап бинаря → dylib в `Contents/MacOS/` → load-команда → ad-hoc
переподпись бандла с entitlements → дефолтный `gamepad.ini`. `tools/uninstall_mac.sh` — откат.
**Подтверждено вживую**: игра запущена БЕЗ `DYLD_INSERT_LIBRARIES`, мост загрузился сам
(`---- WitcherPadBridge loaded, pid 83057 ----`). Это закрывает «запустил и играешь» на macOS.
Защита от двойной загрузки: второй экземпляр видит `WXP_BRIDGE_ACTIVE` и не поднимает воркер;
`launch_injected.sh` сам определяет наличие load-команды и не добавляет DYLD_INSERT.

### ✅ Канал пад → Lua работает end-to-end (подтверждено вживую)
`echo "n <intent>" > /tmp/wxp_cmd` → мост пишет `<seq> <intent>` в `System/wxp_nav.txt` →
Lua-слой выполняет. Живой лог: `nav sect+ -> System / System[5] / ExitButton`,
`nav down -> ... ResumeButton`, `nav up -> ... OptionsButton`.
Обратный канал: `wxp_state.ini` пишется ~1 раз в секунду (`Mode/Panel/Section/Focus/Tick`),
мост читает и логирует `lua: mode=ui panel=Diary`. Признак «Lua жив» = mtime моложе 3 с.

### Windows/Proton — мост написан и собирается (Фаза 4)
`bridge/windows/wxp_bridge_win.c` + `build.sh` → `LightFX.dll` (PE32 i386, 19 undecorated
экспортов). Точка входа — та же попытка игры загрузить `System\lightfx\wxp\LightFX.dll`;
на Wine/Proton обычный PE-загрузчик, поэтому здесь она РАБОТАЕТ (в отличие от eON).
Синтез: клавиши — `SendInput` с `KEYEVENTF_SCANCODE` (DIK-коды это и есть скан-коды),
камера — `SetCursorPos` (движок читает позицию курсора, а не DI-оси), кнопки — `SendInput`.
Пад — XInput, грузится по имени (`xinput1_4/1_3/9_1_0/1_2`). Каналы и `gamepad.ini` — те же.
**Про UCRT**: сборка импортирует `api-ms-win-crt-*`. Раньше в журнале стояло требование
«всё freestanding, никакого UCRT» — оно было нужно ТОЛЬКО для eON, а PE под eON невозможен в
принципе. Wine/Proton апісеты UCRT предоставляют, так что требование снято осознанно.
**НЕ ПРОТЕСТИРОВАНО вживую** — нет доступа к Windows/Proton. Проверять на ROG Ally.

### README
`README.md` — RU + EN: раскладка, установка на обе платформы, gamepad.ini, диагностика,
предупреждение про Steam-verify и про необходимость выключить Steam Input на Windows.


---
# ✅ ФАЗА 2 — НАВИГАЦИЯ ПО UI С ГЕЙМПАДА РАБОТАЕТ (подтверждено вживую)

## Главный инструмент: Lua-REPL внутри игры
`System/Scripts/wxp_gamepad.luc` каждый 3-й heartbeat читает `<game>/System/wxp_cmd.txt`,
компилирует содержимое через `loadstring` и выполняет; результат и всё, что печатает `wxp_p()`,
уходит в `<game>/System/wxp_gamepad.log`. Обёртка: `tools/repl.sh` (файл или stdin, ждёт съедания
команды, печатает свежий кусок лога). Это заменило «слепые» пробники — весь объектный граф игры
теперь исследуется интерактивно, без перезапусков.
Горячая перезагрузка: `g_Lua:PlayFile("wxp_gamepad")` / `wxp_load_ui()`. Хуки ставятся один раз
(флаг `wxp_armed`), вся логика тика живёт в глобале `wxp_heartbeat`, поэтому перезагрузка файла
подменяет поведение без повторного оборачивания `OnHeartbeat`.

## 🔑 Ключевое открытие: UI игры полностью управляем ИЗ Lua, курсор не нужен
Движок водит свой UI мышью, но обработчики — обычные Lua-методы, и их можно звать напрямую:
- наведение: `c:OnMouseEnter()` / `c:OnMouseLeave()`, для слотов ещё `c:HilightSlot(true)` /
  `c:UnhilightSlot(true)` (OnMouseEnter подсвечивает ТОЛЬКО занятый слот — на пустых не видно);
- подсказка: `c:OnTooltip()`;
- нажатие: `c:OnLMouseDown()` + `c:OnLMouseUp()` (у кнопки это вызывает её `OnClick`);
- предмет в слоте: `c:OnDoubleClick()` (надеть/применить; ставится игрой в `AddItem`).
ДОКАЗАНО: клик по `Close` закрыл Дневник, `inv:ShowIndependent()` открыл инвентарь,
`hero:SetTraitActive("Igni")` переключил ветку талантов, чекбокс настроек перещёлкнулся 0→1.
Следствие: **для панелей мосту не нужны ни курсор, ни синтетические клики** — только интенты.
Курсор остаётся нужен ровно в главном меню (там нет heartbeat, Lua не тикает) и для камеры.

## Объектная модель (проверено в рантайме)
- `g_GuiInGame` — **userdata** (tolua), `pairs` по нему НЕ работает; поля читаются обычным `.`
- Инстансы `makeClass` — таблицы; методы лежат в `getmetatable(o).__objectClass` и дальше по
  цепочке `getmetatable(t).__index`. У C++-базы `__index` — функция, перечислению не поддаётся.
- `panel.m_Controls[name]` — все контролы панели. У контрола есть `m_Name`, у панели-объекта нет
  (это надёжный способ отличить вложенную панель от контрола: у контролов тоже есть `lm_pPanel`).
- Геометрия: `CDefineGUIPanel:GetScreenVector(nil, c.lm_Definition)` → Aurora-единицы
  (10.24 x 7.68, Y РАСТЁТ ВВЕРХ). Все игровые под-панели стоят в модели (0,0,z), поэтому
  координаты разных под-панелей сравнимы напрямую. У контролов, созданных в рантайме
  (строки настроек), `lm_Definition` нет — фолбэк на `c.m_pModel:GetPosition()`.
  ВНИМАНИЕ: у части контролов `m_pModel:GetPosition()` даёт 0,0 — `lm_Definition` приоритетнее.
- `m_Status`: у кнопки 0=Disabled 1=Normal 2=Clicked; у `CDragSlot` 0=Disabled 1=Normal
  2=Occupied 3=Dragged. `m_ButtonType ~= nil` — признак кнопки.
- Сравнивать userdata через `~=` НЕЛЬЗЯ (tolua `__eq` падает на разнотипных операндах) —
  только `rawequal` / глобальная `eq()`.
- `os.clock()` ≈ настенное время, `os.remove` есть, `loadstring` есть.

## Карта UI (что где лежит)
- Инвентарь `g_GuiInGame.lm_pNewInventoryPanel`: `lm_pEquipmentPanel` (слоты BackSword,
  BeltSword, SilverSword, SmallWeaponOne/Two, Armour, Amulet, RingLeft/Right, Trophy,
  Elixir1..3), `lm_pRepositoryPanel` (сетка `RepoSlot<строка1..6>_<колонка1..14>`,
  `lm_tRepository[x][y] = {Item=oid, Control=CDragSlot}`, квестовые `QuestSlot1..12`,
  фильтры алхимии `FilterAll`+`Filter0..6`, `AutoSortSmallBag/AlchemyBag`),
  `lm_pGroundPanel`, `lm_pTransferPanel` (торговля/контейнер, `TransSlot<x>_<y>`).
- Персонаж `lm_pInGameSummaryPanel`: `lm_pTraitsPanel` (левая колонка — модели `Label<Trait>`,
  НЕ кнопки; выбор = `hero:SetTraitActive(trait)`, подсветка = `traits:SetTraitSelected/DeselectTrait`),
  `lm_pDetailedTraitPanel` (дерево, кнопки `Level<N>`/`Level<N>Upgrade<M>`), `lm_pSummaryPanel`.
  Список веток: Strength Dexterity Endurance Intelligence Aard Axi Igni Yrden Quen
  SteelStrong SteelFast SteelGroup SilverStrong SilverFast SilverGroup.
- Игровое меню `g_pGuiMan.lm_pInGameNewSystemPanel`: кнопки Resume/Save/Load/Options/Exit,
  под-панели `lm_pInGameNewSystemLoadPanel` (список сейвов — `CListControl` по имени `ScrollView`),
  `lm_pSettingsPanel`, `lm_pControlsPanel`.
- Настройки: строки лежат НЕ в `m_Controls` панели, а в `sp.lm_SettingSets[sp.lm_sType].Panel.m_Controls`,
  у каждой `lm_sType == "setting"` и `lm_Setting`. Чекбокс: `lm_Value ~= nil`, клик = переключение.
  Слайдер (`CGuiSlider`): `SetScrollPos(pos±1)` + `sp:OnLMouseUp(control)` применяет значение.
- `CListControl`: строки в `lm_tListItems[i] = {Button=, Text=, Enabled=}`;
  выбор = `CListControl:OnItemClicked(list, item.Button)`; прокрутка =
  `list.lm_pScrollView.lm_pScrollBar:SetScrollPos(range*frac)` + `scrollview:OnLMouseUp()`.
- Диалоги `g_GuiInGame.lm_pDialogPanel`: реплики — контролы `Reply1..ReplyN`,
  выбор = `Reply_i:OnLMouseDown()`, признак «идёт диалог» = `lm_bLowerActive`.
  Диалог НЕ входит в `IsAnyPanelOpen()` — режим UI для него определяется отдельно.
- Открытие панелей из Lua (обходит хоткеи, которые в прологе ведут себя странно):
  inventory `inv:ShowIndependent()`, alchemy `:UnToggleOff()`, diary `gi:ToggleDiary()`,
  hero `:ShowIndependent()`, map `:TogglePanel()`, system `g_pGuiMan.lm_pInGameNewSystemPanel:TogglePanel()`.
  Все они ТОГГЛЫ — перед открытием проверять, не открыто ли уже.

## Контракт с мостом (согласован с параллельной сессией)
Мост → Lua: `<game>/System/wxp_nav.txt`, одна строка `<seq> <intent>`, перезаписывается,
не удаляется. seq монотонный, но при перезапуске моста начинается заново → сравнивать на
НЕравенство. Интенты: `up down left right activate cancel alt sect+ sect- tab+ tab-`
(+ поддержаны `close`, `open:<inventory|alchemy|diary|hero|map|system>`).
Lua → мост: `<game>/System/wxp_state.ini`, пишется ~1 раз в секунду ДАЖЕ без изменений
(мост по свежести mtime отличает «Lua жив» от главного меню):
```
Mode=world|ui    Panel=<имя>    Section=<секция>    Focus=<контрол>    Tick=<n>
```
Раскладка в UI-режиме (сторона моста): D-pad/левый стик — направления (автоповтор 110 мс после
420 мс), A — activate, B — cancel, Y — alt, LT/RT — sect-/sect+, LB/RB — tab-/tab+.
При входе в UI мост уводит курсор в мёртвый угол (`g 4 4`) и не двигает его правым стиком,
иначе движок подсвечивает ВТОРОЙ контрол под курсором параллельно с нашим фокусом.
Отладка без пада: `echo "n <intent>" > /tmp/wxp_cmd` — мост запишет строку в wxp_nav.txt.

## Что реализовано в `mod/scripts/wxp_ui.lua`
Секции (переключаются курками): для инвентаря — equipment / bag (только занятые слоты) /
quest / filters / ground / container; для остальных панелей — сама панель + каждая под-панель
+ каждый `CListControl` + строки настроек. Внутри секции — пространственный шаг по Aurora-
координатам (скоринг `along + 2.5*perp`, с обёртыванием), для списков и реплик — по индексу
с автопрокруткой. У элемента может быть свой `hi(on)` (подсветка) и `act()` (действие) —
так сделаны ветки талантов; и `adj(delta)` — так сделаны строки настроек (левo/вправо меняет
значение вместо перемещения фокуса).

## Подтверждено вживую (скриншоты + лог)
- игровое меню: фокус ходит по Save/Load/Options/Exit/Resume, подсветка видна, `activate` жмёт;
- список сейвов: 5 строк, вверх/вниз с прокруткой, имена строк = реальные названия сохранений;
- инвентарь: `equipment[13] / filters[10] / container[1]`, `sect+` циклит, шаги осмысленные;
- Персонаж: 15 веток талантов, `activate` реально меняет `lm_sSelectedSkill`;
- настройки: чекбокс перещёлкнулся 0→1 по `right`;
- канал `wxp_nav.txt` → интент → действие проверен и мостом, и вручную.

## Известные ограничения / TODO
- Текущий сейв — пролог Каэр Морхена: сумка и Дневник ПУСТЫЕ, талантов нет. Ветки
  `bag`/`quest`/список квестов на реальных данных не проверены (механика та же, что у
  проверенных слотов снаряжения, но живой прогон нужен).
- Главное меню: heartbeat не тикает, Lua не работает → навигация там за мостом (курсор+клик,
  путь уже доказан E2E: Загрузить → выбор сейва → Загрузить).
- Карта (`lm_pInGameMapPanel`) не разбиралась.
- Вкладка «Gamepad» в настройках ещё не сделана (`RegisterLuaSetting`, план Фазы 2).
- Радиалка знаков и мягкий автотаргет — Фаза 3, не начаты.
- Геймпад физически не подключён к маку — живой тест самим падом за пользователем.

## Разделение работ с параллельной сессией `witcherxinput-cf`
Моё: `mod/scripts/wxp_gamepad.lua`, `mod/scripts/wxp_ui.lua`, `tools/repl.sh`, `tools/install_lua.sh`,
`System/wxp_cmd.txt`. Её: `bridge/macos/wxp_bridge.m`, `/tmp/wxp_cmd`, `gamepad.ini`,
`tools/launch_injected.sh`, `tools/install_mac.sh`/`resign`, Windows/Proton-сборка, README.
Важное от неё: мост теперь прописан в load-командах бинаря (`tools/inject_loadcmd.py`),
DYLD_INSERT больше не нужен — игра запускается обычным способом и мост поднимается сам.

### Радиальное меню знаков (мост, обе платформы)
Раньше знаки с пада НЕ переключались вообще: из клавиш 1..5 не было ни одной привязки,
доступен был только «активный знак» на X. Сделано: **держать LB + отклонить правый стик** →
5 секторов по 72°, от «вверх» по часовой: Aard, Quen, Yrden, Igni, Axii. При смене сектора мост
шлёт tap соответствующей клавиши 1..5 и интент `sign:<n>`; на нажатие/отпускание LB —
`signmenu:on` / `signmenu:off` (чтобы Lua мог нарисовать колесо). Пока LB зажат, камера стоит.
Отпустил LB, не отклонив стик → обычный тап = стальной меч (прежнее поведение сохранено).
Обоснование выбора LB: все боевые привязки здесь — одноразовые переключатели (меч/стиль/знак),
поэтому «удержание» кнопки ничего не стоит и свободно под модификатор.
Механика tap: `g_tap[kvk]` держит клавишу ~48 мс, иначе down+up в одном тике движок может
не увидеть как нажатие.

### Конфиг в два слоя
`gamepad.ini` (write-dir на macOS / корень игры на Windows) — правится руками.
`<game>/System/wxp_config.ini` — пишет внутриигровая вкладка «Gamepad» (Lua не может построить
путь к write-dir, поэтому пишет рядом со скриптами). Мост читает ОБА по mtime, второй
перекрывает первый, оба перечитываются целиком (чтобы удаление ключа не оставляло старое значение).

### Дистрибуция
`tools/package.sh` → `dist/WitcherPadBridge-<ver>.zip`: оба моста, `install_mac.sh`/
`uninstall_mac.sh`/`inject_loadcmd.py`, `gamepad.ini`, README, и ВСЕ `mod/scripts/*.lua`,
скомпилированные в `.luc` прямо в пакет через `tools/luac`.
`install_mac.sh` ставит и Lua-слой (готовые `.luc`), бэкапя штатный `debug.luc`.

### 🔴 Урок: проверять ХОЛОДНЫМ СТАРТОМ
Оба Lua-слоя долго тестировались инъекцией в уже запущенную игру через REPL. В таком режиме
всё уже проинициализировано, и путь «с нуля» не проверяется. Реальный результат: в v11 арминг
падал на `wxp_load_settings (a nil value)` ВНУТРИ общего `pcall`, цикл установки хуков обрывался
на первом элементе, heartbeat не поднимался вообще — игра висла на чёрном экране и до главного
меню не доходила. Правила отсюда: каждый обработчик армить своим `pcall`, и перед сдачей —
обязательный прогон с холодного старта.

### 🔴 Урок: не переподписывать .app при запущенной игре
`codesign --force` переписывает исполняемый файл на диске; живой процесс, дочитывающий страницы
кода, из-за этого вешается. Сначала `pkill`, потом подпись.

### Инструменты, которые снова работают
`screencapture` работает (права выданы) → визуальная проверка доступна.
Важно: скриншот берёт то, что ВИДНО на экране, поэтому перед снимком окно игры надо вывести
вперёд (`osascript -e 'tell application "The Witcher" to activate'`), иначе снимется чужое окно.

### Два бага моста, найденных второй сессией (починены)
1. **Виртуальный курсор отпускался сам, клик уходил мимо.** `cam_release_if_real_mouse` сравнивает
   позицию настоящей мыши с базовой `g_real_seen`. Базовую сеял ТОЛЬКО `cam_apply`, а
   `cursor_goto_game` (команда `g` и весь курсорный режим главного меню) забирал курсор
   (`g_cam_owned = 1`), НЕ засеяв базовую — там оставалась точка от прошлого запуска процесса.
   Первая же проверка (каждые ~100 мс) видела «мышь уехала» и роняла `sClipping` в 0, после чего
   `getMousePosFromEvent:` брал координату из настоящего NSEvent. Срабатывало гарантированно.
   Фикс: `cursor_goto_game` сеет `g_real_seen`; отпускание требует ДВУХ подряд превышений порога.
2. **`Mode=<непонятное>` парсилось как `world`.** Было `ui = !strcasecmp(word,"ui")`. Теперь
   понимаются ровно `ui` и `world`, всё прочее — «неизвестно», мост сохраняет прежнее убеждение.
   Признак «Lua жив» обновляется по факту записи файла независимо от разбора `Mode`.

### Подтверждено скриншотами (холодный старт, курсорный режим)
- Холодный старт Lua-слоя v12 армится полностью (`cfg: registered 8 settings`, все хуки).
- Мост читает `wxp_config.ini` поверх `gamepad.ini`: `menu sensitivity=700 (in-game tab: yes)`.
- Вкладка настроек: в «Игра» внизу списка видна строка **«Поддержка геймпада»** с чекбоксом,
  подписи по-русски.
- Весь путь по меню пройден ТОЛЬКО курсором и кликами моста (`g` + `b`), включая прокрутку
  списка настроек кликами по стрелке скроллбара в игровых координатах (641, 421).
- F9 из главного меню QuickLoad НЕ делает (подтверждено обеими сессиями) — единственный
  безэкранный способ уехать в мир это `wxp_autoload.txt` + `GetLoadSaveSystem():QuickLoad()`.


---
# ✅ ГЛАВНОЕ МЕНЮ — ТЕПЕРЬ ТОЖЕ НА ФОКУСЕ (жалоба пользователя «в главном меню стрелки не пашут»)

## Причина
В главном меню нет `CNWCModule:OnHeartbeat` (модуль не загружен), поэтому Lua-слой не тикал:
интенты от моста уходили в никуда, а курсорный фолбэк моста промахивался.

## Решение: панель-тикер
`RegisterUpdate()` даёт пофреймовый вызов `OnUpdate` и работает ВЕЗДЕ, включая главное меню
(единственный пример в игре — `gui_settings.lua`). Создаём собственную панель через
`defineGUIPanel({Name="WxpTicker", Position={X=0,Y=0,Z=0}, AutoToggleDisabled=true}, obj)`:
без `Texture` и без `Controls` → `CDefineGUIPanel:Create` делает пустой aur-объект, панель
ничего не рисует. Затем `g_Lua:RegisterHandler(panel,"OnUpdate")` + `panel:RegisterUpdate()`,
и из `OnUpdate` зовётся тот же `wxp_heartbeat`, что и из модуля. Создаётся в хуке
`CMainMenuPanel:OnPostAttachmentInitialize`. Двойной тик (тикер + модуль) безвреден:
poll_nav дедуплицирует по seq, poll_cmd съедает файл, write_state throttled по времени.
Признак успеха в логе: `ticker: per-frame update registered`.

## Что к этому пришлось добавить в `wxp_ui`
- `open_panel()` до обращения к `g_GuiInGame` (в меню он nil):
  модальное подтверждение `g_pOKCancelPanel` (перебивает всё) → `g_pGuiMan.lm_pInGameNewSystemPanel`
  → `wxp_mainmenu`. Плюс в игре `g_pStackPanel` / `g_pBribePanel`.
- `panel_ops("system")` больше не требует `g_GuiInGame` — иначе `cancel` в меню молча ничего
  не делал (панель системы существует и до загрузки игры).
- `cancel` получил фолбэк: если штатного «закрыть» нет, жмём собственный контрол экрана
  с именем Close/CloseButton/Back/BackButton/Exit/SettingsBackButton.
- `build_generic` пропускает под-панели, которые сейчас не показаны (`lm_bActive == false`
  или `IsActive() == false`): экран настроек держит все свои content-панели живыми и просто
  переключает видимую, без этого в кольцо фокуса попадали недостижимые контролы.
- `refresh()` при потере фокуса выбирает НОВУЮ секцию (появившуюся с прошлого раза),
  предпочитая список: выбрал «Загрузить» — фокус сразу в списке сейвов, а не на кнопках.
- `poll_state`: `g_GuiInGame == nil` → `Mode=ui`, `Panel=MainMenu`. Иначе мост оставался бы в
  геймплейной раскладке и слал бы WASD на экран, за которым нет мира.

## Подтверждено вживую (скриншоты)
- В главном меню `Tick=` растёт, `ui: navigation layer loaded`, секция `MainMenu[5]`
  (NewGame/LoadGame/Options/Credits/Exit), `down` ходит по кругу, **«НОВАЯ ИГРА» подсвечивается**.
- `activate` на LoadGame открывает экран загрузки, фокус приземляется в список сейвов,
  **третья строка подсвечена** на скриншоте, `down`/`up` листают с прокруткой.
- `activate` на строке выбирает сейв → `LoadSaveButton`/`DeleteButton` из Disabled становятся
  доступны и появляются в кольце (секция выросла с 1 до 3 элементов) → `activate` на
  «ЗАГРУЗИТЬ» стартует загрузку.
- `cancel` возвращает из экрана системы в главное меню.

## Грабли, найденные по дороге
- `scroll_to` использовался в `refresh()` до своего определения — в Lua 5.0 это `nil`-глобал,
  а не forward-декларация. Порядок определений в файле имеет значение.
- `activate` на `ExitButton` в главном меню открывает модальное «Вы уверены, что хотите выйти?» —
  отсюда и появилась поддержка `g_pOKCancelPanel`.
- Вкладка настроек: подписи надо резолвить ЛЕНИВО, внутри `GetSettingName()`. На момент
  загрузки `debug.luc` talk-таблица пустая и определение языка всегда давало «en».
- Холодный старт ≠ горячая перезагрузка через REPL. Функции-загрузчики обязаны быть определены
  ВЫШЕ блока арминга, а каждый watch-обработчик — в собственном `pcall`, иначе одна ошибка
  обрывает цикл и heartbeat не ставится вообще (был реальный блокер: чёрный экран).

---
# ✅ МЕНЮ: РАЗДЕЛЫ И «ЧАСТЬ ПУНКТОВ НЕ ВЫБИРАЕТСЯ» — РАЗОБРАНО

Жалобы пользователя: «меню странно работает, часть я могу выбирать а часть нет, не интуитивно»
и «курки которые l1 r1 они разделы менять должны».

## Причина 1: вкладки экранов были невидимы для фокуса
Вкладки Дневника и Карты — это `CTextTabControl`: контрол с `lm_tTabs[name] = {Position, Button,
Func}`, чьи КНОПКИ лежат на его собственной панели, а не в `m_Controls` экрана. Поэтому
generic-сборщик их не видел, а `U.tab` умел только `lm_pPanelManager:SwitchPanel` → в Дневнике
`tab+` честно отвечал «no tabs». Карта вообще не давала НИ ОДНОЙ секции (её единственный
интерактив — эта полоска вкладок; сам холст карты рисует движок).
Сделано: `tab_strips()` ищет полоски и в `m_Controls`, и среди полей объекта (у карты это
`lm_pTabs`); `all_tabs()` разворачивает их в один список по `Position`; `build_tabs()` даёт
секцию `<Panel>.tabs`, где подсветка = `OnTabMouseEnter/Leave`, нажатие = `OnTabMouseClick`
(движок сам вызывает свой обработчик, контент меняется как от мыши).
`U.tab(delta)`: полоска вкладок → менеджер панелей → секции. `U.section(delta)` при единственной
секции тоже уходит во вкладки. Итог: L1/R1 меняют «раздел» на любом экране, кнопка не мёртвая.
Дублирование убрано: кнопки вкладок исключаются из общего сбора (`SKIP`), иначе Дневник
показывал свои 4 вкладки дважды.

## Причина 2 (главная): половина кольца фокуса — контролы, которых нет на экране
Движок прячет контрол, ОТЦЕПЛЯЯ его от панели: `control:RemoveFromPanel()`. После этого о нём
НИЧЕГО не говорит, что он скрыт — проверено вживую: `m_pModel:GetVisible()` = true,
`GetAlpha()` = 1, позиция прежняя, `m_Status` прежний, `panel.m_Controls[name]` на месте, а
снимок ВСЕХ полей до и после `RemoveFromPanel()` даёт 0 отличий. Методов-запросов
(`IsAddedToPanel`, `IsVisible`, `GetParent`, hit-test у панели) в биндинге нет — перебрал ~30 имён.
Живой пример: Дневник держит ДВА набора фильтров друг на друге (`Filter1..9` для вкладки и
`QuestFilter*` для заданий) и отцепляет ненужный. Из 28 «контролов» экрана 17 были призраками —
фокус на них не подсвечивается и ничего не делает. Ровно то, что пользователь и описал.
Решение: обернуть `RemoveFromPanel`/`ReAddToPanel` на КЛАССЕ контрола (`getmetatable(c).__objectClass`)
при первой встрече — обёртка сквозная, только ставит/снимает флаг `wxp_offpanel`. Плюс
`seed_diary()` засевает флаги из собственного учёта Дневника (`lm_tFilters[tab][i].Visible`,
`lm_bQuestMode`), потому что отцепления ДО установки обёртки мы не видели. Секция Дневника
сжалась 28 → 5 реальных пунктов.
Грабли обёртки (обе поймались вживую):
- `remove(self, a1, a2, a3)` с нулевыми хвостами → tolua ругается «argument #2 is nil;
  '[no object]' expected» и ломает закрытие панелей. Звать строго `remove(self)`.
- Обёртка живёт на классе движка и переживает наши перезагрузки файла. Нужен `WRAP`-версия +
  `rawset(cls, "RemoveFromPanel", nil)` перед установкой: очистка своего поля ОБНАЖАЕТ родной
  метод (он только затенялся), иначе старая сломанная обёртка остаётся навсегда.
- Тег ставить только если `type(self) == "table"` — userdata не принимает чужие поля.

## Причина 3: направления не выходили за пределы секции
Кольцо было набором островов: стик ходил внутри секции, а на соседний блок можно было попасть
только курками. Добавлен `move_across(dx, dy)`: если внутри секции в нужную сторону кандидата
нет — ищем по ВСЕМ остальным секциям (список представляется одной целью — своим виджетом, вход
в первую строку). Порядок: сосед в секции → соседняя секция → только потом обёртка по кругу
(раньше обёртка выигрывала у реального соседа). Список из одной строки шагать некуда, поэтому
любое направление из него сразу пробует выход.
Проверено в Дневнике: список → `up` → нижний ряд вкладок → `up` → верхний ряд → `right` соседняя
вкладка → `down` → второй ряд → `down` → обратно в список; `activate` на вкладке переключает
раздел и фокус остаётся на вкладке (можно листать дальше).

## Колесо знаков — доделано и проверено
Атлас `ui_hud_signs` под id "RMB" даёт 4 состояния на знак: 0 обычное, 1 наведение,
2 «выбрано» (яркая жёлтая подсветка), 3 недоступно (серое). Было: база 3 + наложение 1 —
разница только в тонком кольце, на скриншотах A/B почти неразличима (max diff 31/255).
Стало: ровно ОДИН слой виден за раз (наложение слоёв смешивает, а не заменяет) —
недоступный знак серый, доступный обычный, выбранный слой 2. На экране разница очевидна.
`known_set()` спрашивает игрока напрямую (`GetNumberKnownSpells`/`GetKnownSpell` + `spells.2da`
через `SpellType`, подтип 1 = групповой каст, пропускаем): кэш полоски `lm_nKnownSpells` для
этого не годится, он остаётся 0, пока полоска не обновится. В прологе Каэр Морхена знаков нет
вообще → всё колесо серое, и это правда.

## Остаётся
- Сумка/квестовые слоты на реальных предметах — в текущем сейве инвентарь пуст, Lua-API создания
  предметов в скриптах нет; механика та же, что у проверенных слотов снаряжения.
- `SexButton/SexButton2`, `ActiveQuestsOnly/ActivePhasesOnly` могут быть призраками на части
  вкладок Дневника — обёртка поймает их при первом же отцеплении движком.
- Мягкий автотаргет в бою и проверка на Windows/Proton — не начаты.

---
# ✅ ЭКРАН НАСТРОЕК — та же болезнь, что была в инвентаре

Жалоба: «в меню настроек такая же странная логика как была в инвентаре». Разобрано по следам
живого лога самого пользователя — там же видно, чем это кончилось: из настроек одним «вниз»
фокус уходил на кнопки МЕНЮ ПОЗАДИ, `activate` попал в «Выход», и игра закрылась.

## 1. Кнопки экрана позади оставались в кольце
`CGuiNewSystemPanel:SwitchContentPanel(name)` перед показом Настроек/Загрузки/Управления делает
`self.lm_pPanel:ToggleOff(); self.lm_bActive = false`. То есть **`lm_bActive == false` у панели
значит «мои собственные контролы сейчас не на экране»** — раньше эта проверка применялась только
к вложенным панелям, а к самому экрану нет. Теперь `build_generic` (и сбор вкладок) пропускает
собственные контролы неактивного экрана. Путь «случайно выйти из игры» закрыт.

## 2. Половина строк настроек вообще не собиралась
`build_settings` фильтровал `type(c) == "table"`, а **ползунки (ST_CONTINOUS и ST_BUTTONSDISCREET)
— это userdata (CGuiSlider)**, а не Lua-таблицы. Из-за этого во вкладке «Графика» в кольцо попадала
одна строка из трёх (не было разрешения экрана и гаммы), в «Звуке» — ни одного ползунка громкости.
Теперь принимаются и userdata. Побочно всплыло: **сравнивать фокус через `==` нельзя** — как только
в фокусе userdata, tolua `__eq` бросает «invalid operand». Все сравнения переведены на `rawequal`.
`describe()` для безымянной userdata пишет «row N».

## 3. Строки живут в ДРУГОЙ системе координат
Строки лежат на контент-панели скроллвью (`sp.lm_SettingSets[type].Panel`), а кнопки экрана — на
самой панели настроек, и та не в (0,0): её контролы идут от -5.3 до +2.9. Сравнивать координаты
двух этих наборов бессмысленно. Решение: секция строк помечена `rows = true` — шаг по индексу,
как у списка, — и ей задан явный якорь `ax/ay` = позиция скроллвью в координатах экрана. Через
него `move_across` и считает переходы «строки ↔ кнопки». Плюс строки сортируются по y сверху вниз
(имена дают Setting12 раньше Setting2, а именно порядок массива превращается в позицию скроллбара).
На краях список строк не заворачивается: сверху вкладки, снизу «По умолчанию/Отменить/Принять».

## 4. Категории — это и есть «разделы» для L1/R1
Пять кнопок Игра/Графика/Звук/Управление/Дополнительно — обычные кнопки, но для игрока это
разделы. Введено соглашение: **любая секция с именем `<Panel>.tabs` — это то, что ходят курками**;
`tab_step` шагает по ней и жмёт запись. Под него подведены и `CTextTabControl` (Дневник, Карта), и
эти кнопки. Работает для обоих экранов: у экрана привязок те же пять кнопок с префиксом `Controls`
(`settings_prefix()` определяет префикс по наличию `<prefix>GameplayButton`). Активная категория —
`sp.lm_pCurrentButton`.

## 5. Фокус на строке был НЕ ВИДЕН
Строки настроек не дают никакой реакции на наведение. Палитра движка здесь чисто серая
(`ChangeColor(1,1,1)` включено / `0.5,0.5,0.5` выключено), поэтому «подсветить ярче» нечем.
Каждая строка держит свои подписи в `control.lm_TextControls` (и чекбоксы, и ползунки) — теперь
фокус красит их золотым `(1, 0.8, 0.3)`, снятие возвращает 1,1,1 или 0.5,0.5,0.5 по
`lm_Setting:IsEnabled()`. `UpdateSettings` перекрашивает подписи после каждого изменения значения,
поэтому после `adj` подсветка ставится заново. Проверено скриншотом: «Громкость музыки» и её
значение золотые на фоне белых соседей.

## Проверено вживую
Звук: 9 строк, шаг вниз/вверх, ползунок 20→19→20 через left/right (значение реально меняется —
это тот же путь, что у мыши: `SetScrollPos` + `sp:OnLMouseUp(ctl)`); выход из строк вверх — на
вкладки, вниз — на кнопки. Графика: 3 строки вместо 1. Курки листают категории и открывают
экран привязок, оттуда есть выход. Кнопки системного меню из-за настроек больше не видны.

## Остаётся
Список привязок клавиш на экране «Управление» в кольцо не входит (у экрана 32 контрола, строки
привязок строятся отдельно). Перебиндить с пада всё равно нечем — низкий приоритет.

## Две поправки, найденные на холодном старте (тот же экран)
- **Порядок строк нельзя брать из координат.** У только что открытой вкладки ползунки ещё не
  привязаны и `m_pModel:GetPosition()` отдаёт (0,0) — в «Игре» так было у 10 строк из 20, и
  сортировка по y ставила их вперемешку. Плюс у чекбокса есть `lm_Definition`, а у ползунка нет,
  то есть их координаты вообще из разных пространств. Надёжный порядок зашит в ИМЯ контрола:
  `AddSetting` нумерует строки по мере раскладки сверху вниз (`Setting<N>CheckBox/Continous/
  Discrete`). Сортируем по этому N, координаты — только запасной ключ.
- **Список — это полоса, а не точка.** `move_across` сравнивал секцию строк по одному якорю
  (позиция скроллвью). Из-за этого «вниз» с кнопки «Игра» у левого края экрана промахивалось мимо
  строк (боковое расхождение 6.4 при допуске 5.2) и улетало на «По умолчанию» внизу. Теперь при
  переходе в непозиционную секцию (список/строки) она считается полосой: при вертикальном
  движении берётся x источника, при горизонтальном — его y. С кнопки «Звук» (ближе к центру)
  работало и раньше — классический баг, который виден только на одном из пяти путей.

Проверено на холодном старте: главное меню → «Настройки» → 20 строк во вкладке «Игра»
(12 штатных + 8 наших геймпадных), вход в строки с любой категории, прокрутка едет за фокусом,
подсветка золотом видна на скриншоте, выход из строк вниз — на «По умолчанию/Отменить/Принять».

## R1 не доходил до «Дополнительно»
Жалоба: листаешь категории R1 — на «Дополнительно» перекидывает на «Игра». Причина двойная и
обе половины про одно: **«Управление» — это не вкладка, а ДРУГОЙ экран**. При переходе на него
панель настроек уступает место панели привязок, и вместе с ней исчезают все её кнопки.
1. `tab_step` возвращал фокус на нажатую кнопку по идентичности объекта — а его больше нет,
   фокус терялся и уходил в секцию кнопок внизу.
2. Следующее нажатие искало текущую вкладку через `sel()`, но у панели привязок
   `lm_pCurrentButton == nil` (её выбор хранится у панели настроек), поэтому «текущей» не
   находилось ни одной и шаг начинался с первой — то есть с «Игры».
Починка: у записей вкладок появился `tabkey` — общий ключ поверх префиксов
(`SettingsAdvancedButton` и `ControlsAdvancedButton` → `AdvancedButton`), фокус после нажатия
восстанавливается по нему; а `sel()` на экране привязок отвечает «активна категория Управление»,
раз уж этот экран ею и открыт. Проверено: цикл Игра → Графика → Звук → Управление →
Дополнительно → Игра идёт по кругу в обе стороны, фокус остаётся на полоске категорий.
