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

---
# ФАЗА 3 — БОЙ: РАЗВЕДКА ЗАКОНЧЕНА, ЦЕЛЬ ЗАХВАТЫВАЕТСЯ (подтверждено в живом бою)

## 🔑 Как вообще узнать, что движок отдаёт в Lua
Имена всех экспортированных функций лежат в СТРОКАХ АРХИВА, а не в Mach-O обёртке (сама игра —
x86-PE внутри `witcher.vpfs`). tolua на ошибку печатает `error in function 'X'`, поэтому:
```
strings -a witcher.vpfs | grep -oE "error in function '[A-Za-z_0-9]+'" \
  | sed "s/error in function '//;s/'//" | sort -u        # → 1275 имён
```
Это единственный способ увидеть API целиком; дальше владельца метода ищем перебором
`type(obj.Name) == "function"` по g_Module / g_Player / area / g_pGuiMan / g_pClientExoApp / proxy.

## Что найдено и проверено
- **`g_Module:SetLockedAttackTarget(id)` принимает ЧИСЛО** — object id, не существо
  («argument #2 is 'CNWCCreature'; 'number' expected»). id берётся из `creature:GetId()`
  (например 2147485607 = 0x800007A7). Обратный `g_Module:GetLockedAttackTarget()` возвращает
  само существо. **id 0 снимает замок**; 0xFFFFFFFF НЕ снимает — это id самого игрока
  (`g_Player:GetId()` и `g_pClientExoApp:GetPlayerCreatureId()` оба дают 0xFFFFFFFF).
- **`lg_tCreatureList` — глобальный реестр всех существ**, движок ведёт его сам:
  `CNWCCreature:OnCreate` пишет `lg_tCreatureList[self] = 1`, `OnDelete` стирает. Готовый
  список кандидатов, перебирать ничего не нужно.
- **🔴 Перебор объектов по id через `g_pClientExoApp:GetGameObject(id)` РОНЯЕТ ИГРУ.** Невалидный
  id разыменовывается без проверки. Проверено ценой краша на скане 3000 id. Не делать.
- **Список врагов даёт сам движок через GUI-события.** `CGuiInGame:OnGuiEvent("enemy.add"/
  "enemy.update"/"enemy.remove"/"enemy.remove.all"/"enemy.hilite", pCreature)` — в EE все эти
  обработчики ПУСТЫЕ заглушки (остались от старого HUD, `CGuiInGameMainPanel` в EE вообще не
  инстанцируется), но движок их по-прежнему шлёт. Оборачиваем `CGuiInGame.OnGuiEvent` (арность
  фиксированная: имя + 15 аргументов, прокидывать поимённо, без `arg`/`unpack`) и получаем живой
  набор именно ВРАЖДЕБНЫХ существ. В живом бою наблюдались только `enemy.update` (по одному на
  каждого противника, повторяются); `enemy.add` ни разу не пришёл — значит опираться надо на
  «любое enemy.*, кроме remove, означает „этот в бою“».
- Проекции «мир → экран» в Lua НЕТ: `GetPositionScreen`/`MapToScreen`/`Display2Screen` не висят
  ни на существе, ни на его модели, ни на камере. Значит «подвести курсор к врагу» — не вариант,
  замок остаётся единственным механизмом. (При этом `g_pGuiMan:SetMousePosition` существует —
  старая запись в журнале «курсор из Lua двигать нельзя» неверна.)
- Полезное по существам: `GetObjectTag()`, `GetId()`, `GetCreatureProxy():GetCurrentVitalityPoints()`
  / `:IsDead()`, `GetPosition(v)`, `GetOrientation(v)`. **Геттеры позиции работают через
  out-параметр**: `local v = Vector:new_local(0,0,0); obj:GetPosition(v)` — без аргумента tolua
  ругается «argument #2 is '[no object]'; 'Vector' expected».
- `getPlayerCombatMode()`: 0 — обычный режим, `CM_COMBAT` = 1, `CM_FISTFIGHT` = 2.
- `g_Player:GetArea():IsAreaSafeNow()` — в безопасной зоне движок не даёт ни меч достать, ни знак
  выбрать (то же условие в `CGuiNewRMBList:ToggleSpell`). Во дворе Каэр Морхена зона НЕ безопасна.
- **Инъекция клавиш и кликов работает только когда окно игры в фокусе.** Полчаса ушло на ложный
  вывод «Q не достаёт меч» — на самом деле окно было неактивно. Перед `k`/`b` всегда
  `osascript -e 'tell application "The Witcher" to activate'`.
- Lua 5.0 в этой сборке **не понимает шестнадцатеричные литералы** (`0x80000000` — ошибка
  компиляции). Писать десятичными.

## Живой бой — что показал лог (2 бандита, `q0001_band01`)
```
cbt: mode=1 enemies=0 target=- lock=-
cbt: event enemy.update userdata: 1C672490
cbt: mode=1 enemies=1 target=q0001_band01 lock=q0001_band01
cbt: mode=1 enemies=1 target=q0001_band01 lock=-          <- движок сам сбросил
cbt: mode=1 enemies=1 target=q0001_band01 lock=q0001_band01  <- наш тик поставил заново
... enemies=2 ...
```
То есть: события приходят, кандидаты набираются, цель выбирается и замок ставится. **Движок
регулярно сбрасывает замок сам** (между замахами), поэтому держать его должен наш пофреймовый
тик — что он и делает. Осталось проверить главное: доходит ли удар по замку без курсора на цели.

## `mod/scripts/wxp_combat.lua` (новый файл в слое)
- `C.enemies` — множество существ из enemy-событий, `C.on_event` их ведёт.
- `C.hook()` — обёртка `CGuiInGame.OnGuiEvent`, ставится при загрузке.
- `C.candidates()` — живые, не игрок, в пределах `C.range` (25 ед.), отсортированы по
  `d * (1.6 - 0.6*cos)` относительно направления Геральта: свои впереди выигрывают у тех, кто
  за спиной, но между двумя впереди решает расстояние.
- `C.set/acquire/cycle/clear`, `C.tick()` — держит замок на живой цели и перезахватывает в
  `CM_COMBAT`, `C.status()` для REPL.
- `C.trace`/`C.watching` — построчный лог событий и смены состояния (сейчас включены).
- Интент `target` / `target:next` / `target:prev` / `target:off` в `wxp_intent`.
- Загружается лениво из `wxp_heartbeat` при первом тике с живым `g_GuiInGame`, тикает только в
  `wxp_mode == "world"`.

## Остаётся по бою
1. Проверить, что удар по замку без курсора реально проходит (нужен бой + нажатие атаки).
2. Если нет — вторая линия: движковый режим `g_cAuroraSettings.m_nAttackLockingMode` (в
   `startup.lua` его ставят в 1, а строкой ниже в 0 — победил 0; смысл значений неизвестен,
   проверять экспериментом).
3. Привязать `target:next/prev` к кнопке пада (кандидат — R3) на стороне моста.

---
# ✅ БОЙ: ГЛАВНЫЙ ВОПРОС ЗАКРЫТ — УДАР ИДЁТ ТОЛЬКО ПО ТОМУ, КТО ПОД ПРИЦЕЛОМ

## Ответ: замок цели НЕ заставляет удар дойти
Проверено в живом бою, тремя разными способами, с пофреймовым логом самих ударов:
- прицел НА враге + замок → `BEGIN self=Wiedzmin part=1hs_lvl1_1_d` и два `HIT Wiedzmin -> q0001_band01`;
- прицел в пустоте (5 подряд замеров `lm_pMouseOverCreature == nil`) + замок стоит на бандите
  в полутора метрах → **ни одного `OnAttackBegin`**;
- то же с `g_cAuroraSettings.m_nAttackLockingMode = 1` — тоже ничего.
`g_pClientExoApp:GetPlayerAttackLock()` при этом ВСЕГДА возвращает 2130706432 (0x7F000000,
OBJECT_INVALID) — то есть «настоящего» боевого замка у движка нет, а `SetLockedAttackTarget`
кормит только визуальный селектор: `CNWCModule:OnHeartbeat` берёт `GetLockedAttackTarget()` и
зовёт `SelectCreature(...)`, больше он нигде не участвует. Кружок под целью — всё, что он даёт.
Подсказка была в самой игре: обучающая карточка «Серии атак» говорит «нажимайте левую кнопку мыши
ТОЛЬКО когда ваш курсор примет форму пылающего меча».

## 🔑 Зато найден недостающий канал «мир → экран»
`CNWCModule:OnHiliteMouseover(pCreature)` — движок КАЖДЫЙ КАДР сообщает в Lua, кто сейчас под
прицелом (и кладёт это в `g_Module.lm_pMouseOverCreature`). Проекции координат в Lua нет, но она и
не нужна: есть готовый ответ «попал/не попал», то есть замкнутая обратная связь для автонаведения.
Родственные события: `CNWCModule:OnSetPlayerAttackLock(pCreature)` (движок ставит свой замок),
`CNWCCreature:OnAttackBegin(sPartName)` и `CNWCCreature:OnHit(pTarget)` — обе висят на игроке и
дают точный лог «замахнулся / попал по кому». Это и есть правильный инструмент для проверки боя,
а не HP цели: рядом дерутся Ламберт, Весемир, Эскель и Лео, и HP падает от их ударов тоже.

## Как устроен прицел (камера 2, TPP)
- Курсор в геймплее ЗАПИНАН В ЦЕНТР: `g_pGuiMan:GetMousePos` всегда отдаёт 512,384 (центр
  1024x768), сколько бы мост ни двигал `sCurrentCursorPos`. Прицел = центр экрана, целятся
  ПОВОРОТОМ КАМЕРЫ. Для геймпада это удача: правый стик и так крутит камеру.
- **Чувствительность поворота измерена и линейна: 200 px мыши = 1.0123 рад** (три шага подряд
  дали 1.0123 / 1.0124 / 1.0122). То есть **≈197.6 px на радиан**, положительный dx уменьшает yaw.
- Yaw камеры считается по её позиции: `g_CameraGob:GetPosition(v)` работает, `GetOrientation` —
  нет. Направление взгляда ≈ (позиция игрока − позиция камеры), но **камера смотрит не в игрока,
  а мимо его плеча**: измеренный систематический сдвиг ≈ 60–85 px (0.3–0.43 рад) вправо.
  Поэтому чисто геометрическое наведение промахивается — за один шаг ошибка падает с 62° до 10°,
  дальше нужен доворот по `lm_pMouseOverCreature`.
- Ширина цели по прицелу — около 85 px мыши, то есть попадание не игольное, но враг в ближнем бою
  ходит вокруг и признак мигает: удар надо слать в тот кадр, когда прицел на цели.

## Что из этого следует для мода
Автонаведение = **доворот камеры**, а не замок. Схема: Lua считает нужный поворот в пикселях
(геометрия даёт первый шаг), мост его применяет, Lua подтверждает по `lm_pMouseOverCreature` и
досылает поправку; удар — только при подтверждённом прицеле. Замок цели остаётся полезен как
подсветка выбранной цели и как память «кого бьём».
Нужен новый канал Lua → мост (сейчас его нет): в `wxp_state.ini` добавить `Aim=<dx> <dy>`,
мост применяет как дельту камеры. Плюс участить запись state, пока идёт доводка.

## Побочно
- 🔴 **Обучающие всплывашки ПАУЗЯТ игру** (`CGuiNewTutorialPanel:Show` → `TogglePanelPause`).
  Из-за этого два первых прогона «замок не работает» были недействительны: кадры не шли вообще.
  Всегда проверять `wxp_mode`/`open_panel` перед боевым замером.
- 🔴 **Дохлое существо в Lua — это висячий указатель, и обращение к нему роняет игру** (SIGBUS в
  JIT-коде, `pcall` не спасает — это не Lua-ошибка). Игра упала на переборе `g_Module.lm_Selector`.
  Единственная безопасная проверка — `lg_tCreatureList[c] ~= nil`: это поиск по указателю в
  таблице, без разыменования. `wxp_combat` теперь пропускает через `registered()` каждый путь.
- Тренировочный «Ржавый меч» лежит в правой руке, но Q/E/R/T/U его не достают, а
  `getPlayerCombatMode()` остаётся 0 — меч выходит сам, когда начинается скриптовый бой.

---
# ✅ ВСПЛЫВАЮЩИЕ ОКНА — ТЕПЕРЬ ОТВЕЧАЮТСЯ С ПАДА

Жалоба пользователя: «эти всплывашки только меню отменяются». Их действительно не было ни в одном
экране навигации: `open_panel()` знал про подтверждение, диалог и большие панели, а модальные
попапы `CGuiInGame` — нет. Между тем `CGuiInGame:IsAnyPanelOpen()` перечисляет их сам:
обучающая карточка `lm_pInGameNewTutorialPanel` (`IsShown() and lm_bActive`), медитация
`lm_pInGameNewRestPanel`, карточка романа `lm_pInGameNewSexCardPanel`.
Сделано: все три — отдельные экраны в `open_panel()`, выше диалога (движок и сам гасит диалог,
когда показывает карточку — см. `ShowTutorialDialog`). `cancel` закрывает их штатными вызовами
(`CloseTutorialDialog` / `ToggleOff`), `activate` жмёт OK. У карточки текст длиннее экрана,
поэтому её секция помечена `textscroll` — вверх/вниз крутят `lm_pScroll`, а не ищут второй
контрол, которого нет. У панели медитации круговой ползунок часов лежит НЕ в контролах, а полем
`lm_pSlider`, поэтому он добавлен в секцию вручную с `adj` (`SetScrollPos` + `OnLMouseUp`).
Проверено вживую: `Tutorial / Tutorial[1] / OKButton`, `activate` → `mode=world`, игра
разпаузилась.

---
# ✅ АВТОНАВЕДЕНИЕ: КАНАЛ ПОСТРОЕН И РАБОТАЕТ ВЖИВУЮ

Замок цели удар не наводит (см. предыдущий раздел), значит наводить надо камерой. Собрано и
проверено в живом бою.

## Канал Lua → мост: `<game>/System/wxp_aim.txt`
Одна строка `<seq> <dx> <dy> <ready>`, перезаписывается ~30 раз в секунду, пока идёт бой и есть
цель; мост читает 50 раз в секунду и дедуплицирует по seq.
- **`dx` — АБСОЛЮТНЫЙ остаток**, а не приращение: Lua пересчитывает его каждый кадр по камере,
  которая уже повернулась, поэтому мост заменяет, а не накапливает. Это и делает пару замкнутым
  контуром, а не слепым толчком.
- **`dy` — приращение**: обратной связи по тангажу нет (см. ниже), мост его прибавляет.
- `ready` — «прицел на цели прямо сейчас», по нему мост решает, пора ли отпускать удар.

Мост тратит остаток, только пока зажата кнопка атаки И правый стик не трогают (игрок всегда
главнее), со скоростью `AimSpeed` px/с — не прыжком: рывок читался бы как «игра забрала камеру».
И **придерживает нажатие до 350 мс**, пока прицел не доедет: клик на кадр раньше — это удар по
воздуху, ровно то, ради чего всё и затевалось. Ограничение обязательно: цель, которую не удаётся
взять, не должна лишать игрока возможности бить.
Новые ключи `gamepad.ini`: `AimAssist` (1), `AimSpeed` (2200 px/с).
Тестовый ввод без пада: `echo "a <ms>" > /tmp/wxp_cmd` — держит кнопку атаки.

## Геометрия (всё измерено, не выведено)
- **200 px мыши = 1.0123 рад поворота**, три шага подряд совпали до четвёртого знака → одна
  константа, 197.6 px/рад. +dx уменьшает yaw.
- Направление рига = `bearing(позиция игрока − позиция камеры)`; поворачивается один-к-одному с dx.
- **Азимут цели брать ОТ ИГРОКА, а не от камеры.** Камера стоит меньше чем в шаге от Геральта,
  поэтому азимут от неё для цели на длине меча гуляет на десятки градусов — а именно на длине меча
  это и работает чаще всего. От Геральта тот же угол устойчив, а на дистанциях, ради которых стоит
  поворачиваться, оба варианта совпадают.
- Камера смотрит не в Геральта, а мимо плеча: остаётся постоянный сдвиг (~-72 px), он засеян и
  дальше **доучивается** — в кадре, где прицел подтверждён на цели, геометрический остаток и есть
  этот сдвиг с обратным знаком. **Учить только по целям дальше 3 единиц:** вблизи параллакс между
  игроком и камерой того же порядка, что измеряемое расстояние, и выученное там значение ломает
  наведение на всё дальнее (поймано вживую: сдвиг, выученный в полутора метрах, сделал бандита в
  двадцати недосягаемым).
- **Тангаж из Lua не наблюдаем.** `g_CameraGob` — не глаз: когда вид уходит от неба к земле, его
  угол над Геральтом остаётся 45°, меняется только расстояние. Наивная формула упирает камеру в
  предел тангажа и держит там. Поэтому высота отдана поиску: серия толчков `{40,-80,80,-40}`,
  сумма ноль, шаг 0.16 с, запускается только когда yaw сошёлся, а прицел молчит.
  **Прерванный поиск обязан вернуть камеру** (`aim_hunt_reset`): без этого остатки копятся и через
  полминуты боя вид смотрит в небо, а все удары идут в стену. Поймано вживую.

## Что подтверждено
- Камера отвёрнута, под прицелом пусто, остаток -330..-600 px, зажата атака →
  `BEGIN Wiedzmin part=1hs_lvl1_1_d` + два `HIT Wiedzmin -> q0001_band01`. Воспроизведено
  на трёх ревизиях кода.
- Контроль: то же самое при `AimAssist=0` — ни одного `OnAttackBegin`.

## Что ещё не доведено
- В свалке попадание не стопроцентное: бывает `ready=true`, а замах не начинается. Похоже на
  ритм самой игры (карточка «Серии атак» прямо говорит, что слишком ранний щелчок ломает серию) и
  на то, что `lm_pMouseOverCreature` — не строгий хит-тест, а «с кем игрок сейчас связан»:
  он показывал бандита, когда прицел смотрел в стену. Нужен прогон живым падом.
- 🔴 **`getWorldTimeDelta() == 0` — признак того, что мир на паузе** (обучающая карточка). Два
  круга «автонаведение перестало работать» оказались замерами замороженного кадра. `C.tick`
  теперь на этом выходит, и любой боевой замер надо начинать со снятия всплывашек.
- 🔴 Перезагрузка `wxp_combat` посреди боя оставляет `C.enemies` пустым до следующего события
  движка, а API «враждебности» в Lua нет вообще — список врагов приходит только из GUI-событий.

---
# ✅ ЛОГИРОВАНИЕ ДЛЯ ЧУЖИХ МАШИН (запрос: «для остальных систем добавь логирование»)

Windows/Proton нельзя отладить интерактивно — там нет ни REPL, ни скриншотов, ни возможности
подойти к машине. Значит лог обязан отвечать на вопрос «куда копать» сам, без второго захода.
Сделано на обеих платформах симметрично.

## Логи мостов
- Баннер сессии: `==== WitcherPadBridge (macOS|Windows) <версия>, pid N, <дата>, epoch <N> ====`.
  **Версия штампуется при сборке** (`-DWXP_VERSION=`, `tools/package.sh` передаёт её и в
  `build.sh`, и в clang), поэтому лог с чужой машины сам говорит, какая это сборка.
- Каждая строка со временем (`чч:мм:сс.мс`).
- Ротация на 512 КБ, предыдущий остаётся как `.log.1`.
- `LogLevel` в `gamepad.ini`: 0 тишина, 1 обычный, 2 подробный (каждая клавиша и клик).
  Перечитывается на лету — проверено вживую переключением 1→2 без перезапуска.
- **Дамп окружения при старте**: версия ОС (на Windows ещё Wine/Proton через
  `wine_get_version` из ntdll), корень игры, чем инжектировались (load command или
  DYLD_INSERT), наличие и размеры `wxp_gamepad.luc`/`wxp_ui.luc`/`debug.luc`/конфигов,
  и **записываем ли мы в `System/`** (без этого каналы мертвы, а симптом — «ничего не работает»).
- **Пульс раз в ~10 с**: `alive: pad=yes/NO lx.. ly.. rx.. ry.. keys=N mode=ui|menu|gameplay
  lua=ticking|stale|absent aim=...`. Одна строка отличает «пад не виден» от «пад виден, но игра
  его игнорирует» и от «Lua-слой не установлен».
- Подключение/отключение пада логируется **по фронту**, а не состоянием: строка раз в секунду
  «пада нет» топит лог ровно в том случае, когда его собираются читать.
- Понижено до verbose: посекундный дамп стиков (`pad lx=...`), он ничего не добавляет к пульсу.
  Было 51 строка за 75 с — стало 0. Общий объём старта: ~30 строк.

## Лог Lua-слоя (`wxp_gamepad.log`)
Тот же набор: баннер с версией и epoch, время в каждой строке, ротация на 512 КБ.
🔴 **Часы движка идут в своей зоне** — в живом прогоне Lua писал `13:15:27`, мост `15:15:27`.
Поэтому в оба баннера добавлен `epoch`: числа совпали (1787487325 / 1787487327), то есть
расхождение чисто в форматировании, и два лога всегда можно свести точно.

## Отчёт установки `<игра>/WitcherPadBridge/install.log`
`tools/_log.sh` (bash) и `tools/_log.ps1` (PowerShell) — общий слой для всех четырёх
установщиков: `say`/`note`/`die` пишут и в консоль, и в файл. Заголовок — дата, версия пакета,
`uname`/ОС, папка игры. В конце — **список положенных файлов с размерами**: этим ловится
«установщик отработал, а скопировалась вчерашняя сборка», что иначе выглядит ровно как
«мод не работает». На macOS добавляется вывод `codesign -dv`.
Намеренно не `tee`: подстановка процесса теряет хвост при выходе, а хвост — это и есть то,
чем всё кончилось.

## Сборщик диагностики
`tools/diagnose.sh` (macOS + Linux/Proton) и `tools/diagnose.ps1` + `.bat` (Windows).
Кладут рядом с собой папку `wxp-diag-<дата>` и архив, никуда ничего не отправляют.
Собирают: версию пакета и размеры бинарей, ОС, папку игры, **записываемость `System/`**,
наличие и размеры всех `.luc` (включая проверку, что `debug.luc` действительно зовёт
`wxp_gamepad` — Steam-verify это откатывает), все логи и `.1`, конфиги и файлы каналов,
на macOS ещё `eon.txt`/`lightfx.txt` из write-dir, список контроллеров, живые процессы.
Проверено вживую на этой машине: находит игру, DualSense, все файлы. `gamepad.ini` существует
в двух местах сразу — копии разводятся суффиксом (`gamepad-2.ini`), иначе тот, который мост
реально читал, затирался бы вторым.

## Поправки, найденные по дороге
- 🔴 **Удаление ключа из `gamepad.ini` не возвращало значение по умолчанию.** Комментарий в
  `cfg_load` обещал обратное, но парсер писал поверх живой структуры. Поймано на себе: вернул
  файл из бэкапа без `LogLevel`, а мост остался в verbose. Теперь обе платформы сбрасывают
  конфиг к дефолтам перед перечитыванием (`WXP_CFG_DEFAULTS` — один инициализатор на две копии).
- `g_aim_ready` инициализируется единицей, поэтому пульс без единой строки автонаведения писал
  `ready`. Теперь поле помечается `stale`, если данных нет свежее 2 с.
- Убран второй баннер `=== WitcherPadBridge v0.1 (phase 1) ===` — версия в нём была заморожена.
- `nav:` на Windows был verbose, а на macOS обычный. Выровнено на обычный: интенты редкие и
  это ровно то доказательство, которое нужно при «меню не реагирует».
- Тестовый канал `k <kVK> <ms>` зовёт `p_KeyDown/Up` напрямую, минуя `kbd_apply`, поэтому
  строк `key DOWN` от него не будет — это не баг, у него свои `>>> TEST`.
- `-Wall -Wextra` включены в `bridge/windows/build.sh` по умолчанию; четыре
  `-Wformat-truncation` от новых `snprintf` сняты запасом в буферах.

## CI
- Новый шаг на ubuntu: **разбор всех `tools/*.ps1` через `pwsh`**
  (`[Parser]::ParseFile`). Раньше проверка стояла на macOS-раннере под `command -v pwsh` и
  молча пропускалась; PowerShell-половина уходила бы к пользователю непроверенной.
- Смоук-тест установщиков дополнен прогоном `diagnose.sh` на машине, где ничего не установлено.
- `package.sh` проверяет, что версия действительно попала в `wxp_gamepad.luc`, и что все
  вспомогательные скрипты и `VERSION` лежат в пакете.

## Проверено вживую (холодный старт, 0.6-test)
Баннеры с версией и epoch в обоих логах, дамп окружения, `alive:` отслеживает
`pad=NO → pad=yes` и `mode=gameplay → menu → ui`, `lua=stale → ticking`,
`LogLevel=2` включается без перезапуска. Отчёт установки записан реальным прогоном
`install_mac.sh` из собранного пакета. `diagnose.sh` собрал 9 файлов и корректный `report.txt`.

---
# ✅ АВТОНАВЕДЕНИЕ: РЕЖИМ ВЫНЕСЕН В НАСТРОЙКИ + УБРАНА «БОЛТАНКА» КАМЕРЫ

Жалоба: «иногда это блювотрон, оно то влево то вправо крутит камеру».

## Причина болтанки найдена — два правила кормили друг друга
`C.tick()` перенацеливался на того, кто под прицелом («что игрок выбрал, важнее чем что лучше
по скорингу»). Но пока автонаведение ВЕДЁТ камеру к цели A, оно проносит прицел через
стоящего рядом B → перенацеливание на B → остаток считается для B → камера едет обратно через
A → перенацеливание на A. И так до конца боя. Это и есть «то влево, то вправо».
Починка (`mod/scripts/wxp_combat.lua`):
- `C.retarget_hold = 0.8` — прицел может отобрать цель только если текущая держится дольше
  0.8 с. `C.target_since` штампуется **только при смене существа**, иначе бесполезно: `tick()`
  переставляет замок на ту же цель каждый кадр, и штамп никогда бы не устаревал.
- `C.aim_dead = 30` px — остаток меньше этого не тратится. Ширина прицела ~85 px, то есть 30
  уже внутри; без этого цель в ближнем бою (она не стоит на месте) даёт вечное дрожание около
  нуля, и камера не успокаивается никогда.
- Вертикальный поиск (`HUNT_Y`) стартует через 0.6 с вместо 0.3 — именно покачивание вверх-вниз
  укачивает сильнее всего, а в большинстве случаев доворот по yaw успевает раньше.

## Режим автонаведения — теперь настройка (обе платформы + вкладка в игре)
`AimAssist`: **0** выкл · **1** при атаке (как было, остаётся по умолчанию) · **2** по кнопке.
`AimButton` (только для режима 2): `r3 l3 lb rb lt rt`, по умолчанию `r3`.
В режиме 2 выбранная кнопка **теряет своё обычное действие** (r3 — переворот камеры; если
выбрать lb, не откроется и колесо знаков) — иначе удержание каждый раз дёргало бы действие.
Придержка клика (до 350 мс, пока прицел не доедет) теперь тоже привязана к `aim_active`:
в режиме 2 удар без зажатой кнопки наведения — это удар игрока, задерживать его нельзя.
Вкладка «Игра» в настройках получила «Геймпад: автонаведение» (ползунок 0..2 с текстовыми
подписями через `GetValueName`) и «Геймпад: скорость автонаведения».

## Мелочи реализации
- `AimButton` — первый ключ со СТРОКОВЫМ значением. Парсеры на обеих платформах разбирают его
  до числовой ветки (иначе строка просто терялась). Обе формы `sscanf` проверены отдельной
  программой на реальных строках ini, включая комментарий, где перечислены имена кнопок.
- macOS-парсер `%63[^= ] = %31s`, Windows `%63[A-Za-z] = %31s`; на комментариях обе дают SKIP.
- Сброс к дефолтам при перечитывании (сделан в прошлой правке) распространяется и на
  `AimButton`.

## Проверено
Обе сборки чистые с `-Wall -Wextra`, все шесть скриптов компилируются, пакет собирается.
Горячая перезагрузка `wxp_combat` в живой игре подхватила новые константы
(`dead=30 hold=0.8`), список врагов восстановился из событий движка за ~1 с — как и описано
в журнале. Замер самой болтанки в бою не сделан: игра в этот момент встала на обучающей
карточке (`worldDelta=0`), это проверяет пользователь падом. Половина в мосте (режимы 0/1/2)
требует перезапуска игры — dylib на ходу не подменить.

---
# ✅ ЭКРАН «УПРАВЛЕНИЕ»: СПИСОК ПРИВЯЗОК ТЕПЕРЬ ХОДИТСЯ КРЕСТОВИНОЙ

Жалоба: «в разделе управление не даёт крестиком менять». Это был известный TODO из журнала
(«список привязок в кольцо не входит»), доведённый до конца.

## Почему список был невидим для фокуса
`CGuiNewSystemControlsPanel:PostInitialize` строит строки НЕ на панели экрана, а на
контент-панели скроллвью, и держит их в `cp.lm_pItems` — 80 записей
`{Name, ActionId, StrRef, Control, Key, RevKey, DefKey}` в порядке раскладки: по ДВЕ на действие
(основная привязка и альтернативная). Общий сборщик обходит `panel.m_Controls`, поэтому не видел
ни одной. Крестовина доставала только 5 кнопок категорий сверху и 3 кнопки снизу.

## Что сделано (`build_bindings` в `wxp_ui.lua`)
- Секция `<Panel>.bindings` из `lm_pItems`. Координаты берутся из `m_pModel:GetPosition()`
  (у этих контролов они настоящие), поэтому шаг внутри — ПРОСТРАНСТВЕННЫЙ: вверх/вниз по
  строкам, влево/вправо между двумя колонками привязок. Индексный шаг (как у строк настроек)
  здесь не годится — «вниз» уходило бы сначала вправо.
- `activate` → `cp:OnButtonClick(item.Name)`, то есть штатный путь движка: ячейка выделяется и
  включается `SetDoKeyBindCapture(true)`. **Саму клавишу всё равно даёт клавиатура** — на экране
  биндятся внутренние key id движка, а на паде букв нет. Честное ограничение, так и написано.
- `alt` (Y) → очистка привязки через `cp:BindControl(10)`: id 10 — это то, что захват трактует
  как «удалить». Через движок, а не напрямую `RemoveBinding`, чтобы поднялось то же
  подтверждение, что и от мыши, — а его фокус-слой уже умеет отвечать.
- `esc`/`cancel` и уход фокуса с ячейки **снимают захват** (`CancelBinding` +
  `SetDoKeyBindCapture(false)`). Иначе движок остался бы слушать клавишу для строки, которую
  игрок уже покинул, или для экрана, который он уже закрыл.
- 🔴 Тонкость: снимать захват можно ТОЛЬКО когда `lm_bKeyCaught == false`. После `BindControl(10)`
  флаг становится true — это состояние «висит диалог подтверждения», и `refresh()` в этот момент
  переводит фокус на попап, дёргая `hi(false)` у ячейки. Без проверки флага мы бы отменяли ровно
  то, что игрок собирается подтвердить, и «Удалить» молча ничего не делало бы.

## Две общие правки, которые для этого понадобились
1. **`band`-секции.** Ячейки живут в системе координат контент-панели, а кнопки экрана — в
   координатах экрана; сравнивать их напрямую нельзя (та же болезнь, что была у строк настроек).
   Но и «непозиционной» секцию сделать нельзя — нужны две колонки. Введён флаг `band`:
   внутри секции шаг по координатам, а при ВХОДЕ/ВЫХОДЕ она считается полосой и адресуется через
   `ax/ay` (позиция скроллвью). `positional()` оставлен как был, добавлен `crossable()`,
   и `move_across` теперь спрашивает его.
2. **Прокрутка по строкам, а не по элементам.** `scroll_to` гнал `(pos-1)/(n-1)`, что при двух
   ячейках на строку смещало бы бегунок вдвое быстрее фокуса и упиралось бы в конец на середине
   списка. Теперь запись несёт `row`, секция — `nrows`, и дробь считается по ним.
3. `U.alt` научился уважать `focus_entry.alt` (как `U.activate` давно уважает `.act`),
   `U.close` — `focus_entry.esc`.

## Проверено вживую (горячая перезагрузка `wxp_ui` в запущенной игре, скриншоты)
`System.ControlsPanel.bindings n=80 BAND nrows=40`. Вниз — строка за строкой, бегунок едет ровно
(38 на строку). Вправо/влево — между колонками. Скриншот: подсвечена ячейка «Игни / 4», затем
пустая ячейка второй колонки той же строки — обе видны. `activate` armed захват
(`activeItem=Igni2 keyCaught=false`), `esc` его снял (`activeItem=nil`). `alt` на «Игни»
поднял штатное подтверждение (`Confirm / Confirm[2] / CancelButton`), «Отменить» вернуло всё как
было (`Igni key=34 remove=nil` — ничего не изменилось). Выход вниз — на «Принять», вверх — на
полоску категорий. Экран настроек (Игра/Графика/Звук) после правки `crossable` не пострадал:
вкладки листаются, 20 строк шагаются.

## Стоимость
`refresh()` вызывается только на ввод (в `wxp_gamepad.lua` его нет вообще), так что 80 pcall'ов
на пересборку секции — это раз на нажатие, а не раз на кадр.

---
# ✅ «НОВАЯ ИГРА»: КРЕСТОВИНА ЛИСТАЛА НЕВИДИМОЕ МЕНЮ ПОЗАДИ

Жалоба: «в новой игре выбор режима и сложности странный», и точное наблюдение самого
пользователя — **«вверх-вниз стрелками листаешь заднее невидимое меню»**. Так и было.

## Причина
«Новая игра» — это мастер, который главное меню держит рядом с собой: `mm.lm_tPanels` —
список шагов (контент → сложность → режим управления), `mm.lm_nActivePanel` — какой сейчас на
экране (0 = само меню). Эти шаги — **движковые панели-userdata** (`m_Name` = GamePanel /
DifficultyPanel / ControlsPanel), а не Lua-обёртки, из которых сделан весь остальной UI:
`lm_pPanel` у них нет, поэтому `sub_panels()` (он требует `type(v)=="table"` и userdata в
`lm_pPanel`) не находил ни одной. Кольцо оставалось на пяти кнопках главного меню, поверх
которых мастер и нарисован. Проверено вживую: после `activate` на «НОВАЯ ИГРА»
`activePanel=1`, а секция по-прежнему `MainMenu [5] Credits Exit LoadGame NewGame Options`.

## Второй слой: два контрола на один вариант
`m_Controls` панели сложности — 26 контролов, из них **кнопок семь**: `Easy Medium Hard` (большие
иллюстрированные карточки) и `EaseLabel MediumLabel HardLabel` (подписи под ними, где и висит
`OnClick`, который реально выбирает вариант), плюс `Exit`. То есть на три сложности пришлось бы
шесть остановок фокуса, и каждое второе нажатие подсвечивало бы другую вещь.
Отбор по суффиксу `Label`: оставляем карточки, подписи пропускаем. Пары именуются
НЕПОСЛЕДОВАТЕЛЬНО (`Easy` ↔ `Ease`Label), поэтому связывать их по имени нельзя — суффикса
достаточно, чтобы понять, кто есть кто. Подсветку карточки прокидываем на подпись через её
собственные хуки `OnHilight`/`OnUnhilight`, которые игра сама и назначила: получается ровно то,
что делает мышь. Клик карточки движок уже делегирует подписи (`Easy.OnLMouseDown` →
`EaseLabel:OnLMouseDown`), так что `activate` работает без спецкода.

## Мелочи
- Порядок в секции — по чтению (сверху вниз, слева направо), а не по имени: иначе каждый шаг
  мастера открывался бы с фокусом на «НАЗАД» (алфавитно `Exit` первый).
- `cancel` (B) на любом шаге = «назад»: у записей есть `esc`, который жмёт `Exit` панели, а тот
  вызывает `SwitchToPrevPanel`. Без этого B был бы мёртв — у главного меню нет своего «закрыть»,
  которое нашёл бы `U.close`.
- `U.close` теперь делает `refresh()` до `describe()` в ветке `esc`, иначе в лог уходило имя
  шага, которого уже нет.

## Проверено вживую (скриншоты, все три шага)
«Выберите режим»: `NewGame [3] Mouse... ` — карточки «Ведьмак»/«Новые приключения» + «НАЗАД»,
подсветка (белый мазок под подписью) переезжает между ними.
«Выберите уровень сложности»: `[4] Easy Medium Hard Exit`, влево-вправо по карточкам,
вниз — на «НАЗАД», вверх — обратно; карточка «ЛЕГКО» в фокусе видимо ярче соседних.
«Выберите режим управления»: `[3] Mouse Key Exit`, фокус открывается на первой карточке.
`cancel` откатывает шаги 4 → 3 → 1 → 0, и на нуле кольцо возвращается к
`MainMenu [5]`. Новая игра при этом НЕ запускалась — мастер до конца не доводился.

## Побочно: настройка на первом запуске брала не свой дефолт
`AimSpeed` показывал 12 при `GetDefaultValue()` = 22, и вкладка писала в конфиг `AimSpeed = 1200`
вместо документированных 2200. Замер: `ReadSettingIniEntry("WxpGamepadAimSpeed")` возвращает
`true, "12"` — то есть в реестре УЖЕ лежало 12, и `Read()` честно его восстанавливал (его
фолбэк на дефолт срабатывает только когда записи нет вовсе; для незнакомого ключа он отдаёт
`false`). Значит на первой же регистрации туда попало не то. Теперь `define()` спрашивает реестр
сам и, если записи не было, ставит документированный дефолт явно. Round-trip проверен вживую:
`SetValue(22)` → `ApplyChanges` → `wxp_config.ini: AimSpeed = 2200` → мост в логе
`aim assist=1 (on attack) speed=2200 px/s`.

---
# ✅ АКТИВНАЯ ПАУЗА НА СРЕДНЕЙ КНОПКЕ + ФОКУС В ИНВЕНТАРЕ СТАЛ ВИДЕН

Жалобы: «паузу не учли, можем повесить на кнопку посередине?» и «меню снаряжения тоже странно
работает». Обе половины сделаны и проверены вживую.

## Пауза: что это вообще такое в этой игре
Пробел не привязан ни к чему в `actions.2da` — активная пауза приходит в Lua ГОТОВЫМ СОБЫТИЕМ
движка `pause.on` / `pause.off` (`gui.lua:1520`), которое поднимает `lm_pPausePanel` и ставит
`lm_bUserPause`. То есть перебивать нечего: достаточно нажать Пробел, и всё остальное сделает
движок. Проверено инъекцией `k 49 120`:
`userPause=nil panelActive=false worldDelta=0.018` → `userPause=true panelActive=true
worldDelta=0` → и обратно. Обе стороны переключателя работают.

## Кнопка: тачпад, потому что он единственный свободный
`PauseButton` = `touchpad menu back l3 r3 lt rt none`, по умолчанию `touchpad`.
На DualSense клик по тачпаду — та самая «кнопка посередине», и она ничем не занята.
L3/R3 тоже свободные КНОПКИ, но не свободные ДЕЙСТВИЯ: L3 — групповой стиль, R3 — переворот
камеры и кнопка автонаведения в режиме 2. Поэтому они в списке, но не по умолчанию.
- **На паде без тачпада фолбэк на `menu` делается сам** (`respondsToSelector:@selector(touchpadButton)`,
  плюс проверка, что объект кнопки не nil: селектор может существовать и отдавать nil).
  Иначе на Xbox-паде фича просто молча отсутствовала бы, а это худший вид поломки.
  На Windows тачпада в XInput нет вообще, поэтому там `touchpad` резолвится в `menu` всегда —
  имя оставлено, чтобы один `gamepad.ini` одинаково читался на обеих платформах.
- Занятая кнопка **теряет своё обычное действие** (Menu→Esc, Back→F5, l3→C, r3→F, lt→X, rt→Z).
  Menu не жалко: Esc всё равно висит на B.
- Пауза жмётся **только в мире**: в панели те же кнопки заняты меню, и пауза, включённая из
  меню, — это пауза, которую игрок не просил.
- Строка в логе по фронту нажатия (`active pause: touchpad pressed`) — на чужой машине это
  единственный способ отличить «кнопку не видно» от «Пробел не сработал».
  Подтверждено вживую: `gamepad connected: DualSense Wireless Controller (GCDualSenseGamepad,
  touchpad yes)`.

Настройка есть и в игре: «Геймпад: кнопка активной паузы», ползунок 0..7 с именами
(тачпад/Menu/Back/L3/R3/LT/RT/нет). Первый ключ, у которого `map` возвращает СТРОКУ, а не число —
`cfg_write` уже писал `tostring(map(v))`, так что менять ничего не пришлось.
Round-trip проверен целиком: слайдер → `SetValue(5)` + `ApplyChanges` → `wxp_config.ini:
PauseButton = lt` → мост в логе `active pause on lt` → вернул 0 → `touchpad`.
Оба парсера (`%63[^= ]` на macOS, `%63[A-Za-z]` на Windows) прогнаны отдельной программой по
реальному `mod/gamepad.ini`: строка ловится обеими, комментарии не ловятся, в числовую ветку
ничего не утекает.

## Инвентарь: фокус был, но его не было видно
Слот в снаряжении не даёт НИКАКОЙ реакции на наведение: `SelectButton`, `HilightSlot`,
`DimmButton`, `EnableButton` на этом классе = nil, `m_Status` = 0, `OnMouseEnter` есть, но на
пустом слоте не рисует ничего. Пиксельный диф двух соседних сфокусированных слотов был пустой —
то есть фокус ходил правильно, а игрок этого не видел. Ровно то, что описано как «странно
работает».
Починка: `slot_focus()` в `wxp_ui.lua` — `c:SetScale(1.35)` на фокусе, 1.0 при уходе, плюс
`OnMouseEnter/Leave` и `OnTooltip`. Ставится на секции equipment/bag/quest/ground/container.
Проверено дифом: шаг RingLeft → Armour даёт области `154x166+2186+620` (слот вырос) и
`84x84+2028+928` (соседний вернулся) — на скриншоте центральный слот заметно крупнее соседей.

## Побочно
- Игра на этой машине после холодного старта сама уезжает в мир (остался `wxp_autoload.txt`
  из боевых прогонов) — удобно, но об этом легко забыть и удивиться `Mode=world` вместо главного
  меню через две минуты после запуска.
- Проверка «нажатие тачпада доходит» физически не сделана: пад подключён к машине, но нажать
  его из кода нечем. Доказаны обе половины по отдельности (Пробел паузит; кнопка читается,
  объект не nil) — остаётся один живой тык пальцем.

---
# ✅ ДИАЛОГ: СОН/ПОДАРОК/ТОРГОВЛЯ БЫЛИ НЕДОСТУПНЫ С ПАДА

Жалоба со скриншотом трактирщика: «тут не могу сон выбрать». Под строкой «1. Пока.» рисуется
иконка спящей головы — и она была невидима для кольца фокуса.

## Причина
`CGuiDialogPanel:AddReplyText` разветвляется по `nReplyAction`: обычная реплика становится парой
`Reply<N>` + `Index<N>`, а «геймплейное действие» (сон = 8, подарок = 3, торговля и т.д.) —
контролом `Icon<N>` БЕЗ текста, который создаётся в рантайме через `DefineControl` и получает
замыкание `function pIconControl.OnClick() self:OnReplyClick(nReplyID) end`. Наш `build_dialog`
собирал только `Reply1..ReplyN` по `lm_nNumNormalReplies`, поэтому иконок в кольце не было
вообще. Живая проба это подтвердила: `normal=1 gp=1 total=2`, при этом
`Icon1: status=1 btnType=0 offpanel=nil onclick=function`.

## Сделано
`build_dialog` добавляет `Icon1..Icon<lm_nNumGPActions>` после реплик.
- **Порядок по координате, а не по имени**: движок кладёт их в один горизонтальный ряд
  `X = -375 - (i-1)*75`, то есть первая иконка — самая ПРАВАЯ. Сортировка по x даёт порядок,
  который игрок видит слева направо.
- **Disabled пропускаем** (`m_Status == 0`): действие есть, но игра его не даст, а остановка
  фокуса, которая ничего не делает, — ровно та болезнь, из-за которой эти экраны и считались
  сломанными.
- **`hi` зовёт `OnTooltip()`**: иконка голая, без подписи, и подсказка — единственное, что
  говорит, что это вообще такое.
- **`act` идёт мышиным путём** (`OnLMouseDown` + `OnLMouseUp`), чтобы движок сам поднял
  `OnClick`: только его замыкание знает, какому `nReplyID` соответствует иконка. Фолбэк на
  прямой `c.OnClick()`.

Проверено вживую в диалоге с трактирщиком: секция выросла `replies[1]` → `replies[2]`,
`down` переводит фокус на `Icon1`, на скриншоте вокруг иконки появляется зелёное кольцо
наведения, у реплики подсветка снимается.

---
# ✅ ВИБРАЦИЯ: КАНАЛ ПОСТРОЕН, ОБЕ ПЛАТФОРМЫ (Lua-половина проверена вживую)

Запрос: «вибрацию возможно как-то прикрутить?» + догадка пользователя «движок под консоли
заточен тоже». Догадка оказалась верной, но не там, где её ждали.

## Что показала разведка
- **У ИГРЫ вибрации нет вообще.** Полный список из 1275 экспортов
  (`strings -a witcher.vpfs | grep -oE "error in function '[A-Za-z_0-9]+'"`) содержит ровно одно
  имя похожей формы — `ShakeCamera`, и оно двигает камеру. В PE есть строки `VibrationAngles.*`
  / `VibrationFrequency.*`, но это параметры эффектов, а не пада.
- **У ОБОЛОЧКИ eON вибрация есть.** В Mach-O импортируются `GCHapticsLocalityLeftHandle`,
  `GCHapticsLocalityRightHandle`, `GCHapticsLocalityLeftTrigger/RightTrigger`,
  `CHHapticEventTypeHapticContinuous`, `CHHapticDynamicParameterIDHapticIntensityControl`,
  `GCHapticDurationInfinite`, плюс есть `SCH_DirectInputEffectImp_Start/Stop/Unload/Escape` —
  то есть eON эмулирует DirectInput force feedback и выводит его в Core Haptics.
  Witcher 1 такой эффект не создаёт НИКОГДА, поэтому гаптика свободна и мы берём её напрямую.
  Побочная польза: выбор локалей самим eON — хорошее доказательство, что именно эти работают.

## Канал и формат
`<game>/System/wxp_rumble.txt`, одна строка `<seq> <low> <high> <ms>`, дедупликация по seq,
мост читает 50 раз в секунду (как `wxp_aim.txt`). Моторы 0..1000 целыми:
**формат провода следует за более скупым API** (XInput принимает ровно два мотора 0..65535),
а macOS уже выводит из него параметры Core Haptics, а не наоборот. Целые — ещё и чтобы Lua не
зависел от десятичного разделителя.

## Мост
- **macOS**: `GCController.haptics` → по движку на `GCHapticsLocalityLeftHandle` (тяжёлый мотор)
  и `RightHandle` (лёгкий); если пад отдаёт только одну локаль — берём её и различаем моторы
  через `sharpness` (0.15 тяжёлый / 0.9 лёгкий). Движок может остановиться сам (сон, другое
  приложение, переподключение) — `stoppedHandler`/`resetHandler` только помечают его, следующий
  импульс пересоздаёт. Отключение пада сносит движки.
- **Windows/Proton**: `XInputSetState` подгружается рядом с `XInputGetState` из той же
  библиотеки. У `xinput9_1_0` его нет — это отсутствующая фича, а не сбой, поэтому логируется
  один раз и мост живёт дальше. **Вибрация в XInput — это уровень, а не событие**: включил и
  забыл = пад жужжит до выхода из игры, поэтому мост держит дедлайн и сам глушит моторы.
- Настройки `Rumble` (0/1) и `RumbleStrength` (проценты) в ini и во вкладке «Игра».

## Lua: `mod/scripts/wxp_rumble.lua`
Главный триггер — **`CNWCModule:OnCameraShake(vOffset)`**: движок сам зовёт его каждый раз,
когда что-то должно тряхнуть вид, и передаёт смещение — то есть готовую интенсивность.
Остальное: `CNWCCreature:OnHit` (наш удар дошёл; фильтр `rawequal(self, g_Player)`),
полученный урон (события нет — читаем `GetCurrentVitalityPoints` на тике, масштаб по величине
потери), и GUI-события `combatsequence.next`, `medallion.modechange`, `statspanel.levelup`,
`playerhealth.poisoned`, `spells.update`.
- **`combatsequence.next(nAnimLength, nHitTime)` — самое ценное**: движок отдаёт время удара
  следующего звена серии. Тик планируется НА этот момент, а не играется сразу: игра сама на
  обучающей карточке говорит, что ранний щелчок ломает серию, — значит вибрация должна быть
  «жми сейчас», а не «серия пошла».
- GUI-события идут через ЕДИНСТВЕННУЮ обёртку `OnGuiEvent`, которой уже владеет `wxp_combat`:
  она форвардит их сюда. Вторая обёртка доставляла бы всё дважды.
- `min_gap = 0.05` — размен в ближнем бою не должен превращать пад в дверной звонок.
- `R.test()` — короткий импульс, чтобы ответить на «вибрация вообще включена?» без боя.

## Что проверено — ВИБРАЦИЯ РАБОТАЕТ ВЖИВУЮ (подтверждено пользователем на DualSense)
Обе сборки чистые с `-Wall -Wextra`, все семь скриптов компилируются, пакет собирается.
- Lua: `rum: vibration layer loaded`, `rum: hooks installed (camera shake, hit)`,
  в `System/wxp_rumble.txt` появилась строка `1 800 200 200`.
- Мост на первом же импульсе: **`rumble: haptics ready (heavy=yes light=yes)`** — DualSense
  отдаёт ОБЕ локали (`LeftHandle`/`RightHandle`), оба движка Core Haptics поднялись.
- Прогнаны четыре импульса: `800/200 200мс`, `1000/0 400мс` (только тяжёлый),
  `0/1000 400мс` (только лёгкий), `1000/1000 700мс`. **Пользователь подтвердил: все три
  разных ощущаются по-разному.** То есть разделение моторов по локалям реально работает,
  а не сваливается в один.
- Половина в мосте требует перезапуска игры — dylib на ходу не подменить.

### Бой, ~50 секунд с трассировкой — что реально срабатывает
```
18 x 0.45/0.30   hit_dealt   наш удар дошёл
19 x 0.43..0.48  hit_taken   получили урон (масштаб ~0.52, то есть раны по 1-4 HP)
14 x 0.00/0.55   chain       тик серии ударов
 2 x 0.35/0.55   sign
 0 x             ТРЯСКА КАМЕРЫ
```
Все 56 импульсов дошли до моста (`rumble:` в его логе совпадает один в один).
Темп ~1 импульс в секунду — не навязчиво.

🔴 **Поправка к собственной гипотезе: `OnCameraShake` в обычном бою НЕ СРАБАТЫВАЕТ НИ РАЗУ.**
Он был выбран «главным триггером», потому что движок сам отдаёт в него интенсивность — но на
деле движок трясёт камеру только на крупных событиях (взрывы, сбивание с ног Аардом), а не на
ударах мечом. Ощущение обычного боя целиком держится на `OnHit`, полученном уроне и тике серии.
`OnCameraShake` остаётся правильным каналом для того, для чего он есть, — просто это редкость,
а не основа.
Тик серии (`combatsequence.next`) отрабатывает штатно: 14 раз за бой, значит `nHitTime` реально
попадает в диапазон 0.05..3 и планирование работает.

### Настройка по отзыву: «совпадает с ударами, но вибрация везде лёгкая»
Такт признан верным, силы не хватало. Две причины, и **длительность оказалась важнее амплитуды**:
Core Haptics раскачивает continuous-событие, поэтому импульс в 45 мс просто не успевает дойти до
запрошенной интенсивности. Теперь ничего короче ~70 мс в таблице нет, а амплитуды подняты
(`hit_dealt` 0.45/0.30 → 0.70/0.55, `chain` 0.55@45мс → 0.90@70мс, `hit_taken` 0.85 → 1.00).
Отдельно поднят ПОЛ масштаба полученного урона: было `0.5 + lost/60` с полом 0.5, а в прологовой
драке раны по 1–4 HP, то есть почти каждый удар приходил ровно на пол и читался как ничто.
Стало `0.7 + lost/45` с полом 0.7. Проверено вживую тем же пользователем: «вот щас лучше».
Запас на вкус остаётся в `RumbleStrength` (проценты; всё, что ниже 1.0, реально усилится).

## Найдено попутно (в очередь)
- **Экран медитации перекрывает «Персонажа»**: `open_panel()` отдаёт самую специфичную панель,
  поэтому при открытой медитации в кольцо попадает только она, а таланты рядом недоступны.
  Пользователь просит переключаться курками между ними.

---
# ✅ ИНВЕНТАРЬ НА РЕАЛЬНЫХ ВЕЩАХ — ПРОВЕРЕН (закрыт старый TODO)

Механика сумки/квестовых слотов держалась на допущении «та же, что у проверенных слотов
снаряжения»: прологовый сейв был пуст. Теперь у игрока есть вещи, и проверено вживую.

- 🔴 **При ЗАКРЫТОЙ панели инвентарь не отражает содержимое**: `lm_tRepository` пуст, а слоты
  снаряжения отдают `m_Status = 0`. Первый заход намерился по закрытой панели и дал «0 предметов»
  при полной сумке. Любой замер по инвентарю — только с открытой панелью.
- Кольцо на реальных данных: `equipment[8] / bag[6] / filters[10] / container[1]`.
  Секция `quest` не появилась — квестовых предметов нет, и это правильное поведение, а не пропажа.
- Все 6 предметов сумки — `RepoSlot1_1..1_6`, `m_Status = 2` (Occupied), у каждого есть
  `SetScale` и `OnDoubleClick`. Шаг вправо переводит фокус `RepoSlot1_1 → RepoSlot1_2`, на
  скриншоте у второго предмета видна зелёная рамка, наверху меняется название предмета.
- **Ложная тревога про «мешок алхимии»**: `AlcSlots1..3` и `BagSlots1..3` выглядят как
  под-панели (у каждой «126 контролов»), но это обычные контролы-подложки — их `lm_pPanel`
  указывает на ВЛАДЕЮЩУЮ панель, а не на дочернюю, поэтому все шесть отдают один и тот же
  набор из 126 контролов самой панели репозитория. Отдельного набора алхимических слотов нет,
  `build_inventory` видит всё.
- Порядок в списке секции не совпадает с порядком на экране (`RepoSlot1_1` идёт последним), но
  секция позиционная — шаг считается по координатам, так что на навигацию это не влияет.
  Единственное следствие: начальный фокус попадает не на первый предмет.

# 📋 АНАЛОГОВАЯ СКОРОСТЬ БЕГА — разведка сделана, реализация впереди

Запрос: «скорость бега в зависимости от отклонения стиков».
- В `actions.2da` только `Forward/Backward/StrafeLeft/StrafeRight` — отдельной клавиши «идти»
  нет, поэтому раскладкой это не решается.
- Но у движка есть **`g_pClientExoApp:SetAlwaysRun(bool)`** (найдено перебором владельцев по
  списку экспортов; там же `IsAnyDriveModeKeyPressed` и `StopPlayerDriveMode`).
  `startup.lua:160` ставит `g_cAuroraSettings.m_bAlwaysRun = true` — то есть по умолчанию
  Геральт всегда бежит, и опции в меню для этого нет.
- `SetSpeed`/`SetAnimationSpeed` в списке экспортов есть, но ни на игроке, ни на прокси, ни на
  g_Module/g_pClientExoApp их нет — непрерывную скорость взять неоткуда, да и она рассинхронила
  бы анимацию с перемещением.
- **План**: две скорости по порогу отклонения стика. Мост знает величину отклонения, на переходе
  через порог шлёт интент `run:0` / `run:1`, Lua зовёт `SetAlwaysRun`. Порог с гистерезисом,
  иначе на границе будет дребезг. Ровно так это делали консольные порты того времени.

# 🔑 МИНИ-ИГРЫ: в EE ЖИВА ТОЛЬКО ОДНА
`CMiniGamesInterface:InitializeMinigames` регистрирует `l_tGames = { ["Poker"] = MGPoker:new() }`
и грузит только `mg_poker_main`. Файлы `mg_dices_main.lua` (4649 строк, с STATE_PLAYER_ATTACK и
действиями Аард/Ирден/Квен) и `minigame_dices_ex.lua` — мёртвый прототип отдельной игры в кости,
он не грузится никогда. То есть работы вдвое меньше, чем казалось: только покер на костях.
Кулачные бои — это боевой режим (`CM_FISTFIGHT = 2`), своей панели у них нет, атака уже на A.
`MGPoker` разложен на под-панели `MGPokerStatusGUI / SetupGUI / BidGUI / ResultGUI / RulesGUI /
HelpGUI`, каждая — `CLuaPanel`, плюс выбор костей идёт через `OnLMouseDown(pObject)` по 3D-объекту
(хит-чек `OnHitCheck`), а не по контролу. Значит для пада нужны две вещи: кольцо по кнопкам
активной под-панели и отдельный способ выбирать кости. Проверять всё равно только на живом
сопернике — в прологе их нет.

---
# ✅ ШАГ И БЕГ ОТ ОТКЛОНЕНИЯ СТИКА

Запрос: «скорость бега в зависимости от отклонения стиков».

## Что оказалось правдой
Непрерывной скорости взять неоткуда, а вот ВТОРАЯ скорость у игры есть — просто выключена.
`startup.lua:160` ставит `g_cAuroraSettings.m_bAlwaysRun = true`, клавиши «идти» в `actions.2da`
нет вообще, и Геральт носится бегом даже по комнате. Движок отдаёт в Lua
`g_pClientExoApp:SetAlwaysRun(bool)` — этого достаточно.

## Как мерили (первый подход был неверным)
🔴 Первый замер — «пройденный путь за 1.5 с» — дал 6.2 против 6.9 и вывод «разницы нет».
Неправда: Геральт упирался в стены лаборатории, и при ОДНОЙ И ТОЙ ЖЕ настройке путь скакал
10.9 → 13.8. Расстояние здесь мерить нельзя.
Правильный замер — МГНОВЕННАЯ скорость: временный сэмплер подвешен к `wxp_rumble.tick` (он и так
зовётся каждый heartbeat в мире), пишет позицию с отметкой `os.clock()`, дальше берётся максимум
по соседним парам. Стены при этом просто дают низкие пары в конце и на максимум не влияют.
Результат однозначный:
```
alwaysRun=true    7.54 и 9.44 ед/с
alwaysRun=false   2.48 и 2.07 ед/с
```
Вчетверо. Это и есть шаг против бега.

## Реализация
- Мост: величина отклонения ЛЕВОГО стика берётся с СЫРОГО стика, а не после мёртвой зоны, —
  иначе «0.70» значило бы не семь десятых хода, а что-то, что зависит от `DeadzoneLeft`.
  Гистерезис 0.08: стик, лежащий ровно на пороге, иначе переключал бы походку по несколько раз
  в секунду. Центрованный стик ИЛИ открытая панель возвращают игре её умолчание — иначе шаг
  унаследовало бы всё остальное, что двигает Геральта (click-to-move, катсцена).
- На переходе через порог мост шлёт интент `run:1` / `run:0`; `wxp_intent` зовёт
  `SetAlwaysRun` И выставляет `m_bAlwaysRun` — флаг это то, чем пользуется `startup.lua`, и
  оставлять их расходящимися значит однажды получить настройку обратно самопроизвольно.
- `RunThreshold` в ini (0 = всегда бег, как было) и ползунок «Геймпад: бег при отклонении, %».

## Проверено
Канал целиком, ещё до перезапуска: `n run:0` → **2.04 ед/с**, `n run:1` → **8.66 ед/с**.
Половина в мосте (чтение стика) требует перезапуска игры.

## 🔴 ПЛАВНОЙ СКОРОСТИ НЕ БУДЕТ — и это про движок, а не про мод
Вопрос «а промежуточные стадии, как в современных играх?» закрыт отрицательно. Проверено,
чтобы никто не начинал заново:
- Скорость игрока — `creaturespeed.2da`, строка 0 `PC_Movement`: WALKRATE 2.00, RUNRATE 11.00.
  Статическая таблица. Рантайм-сеттера в Lua нет: `SetSpeed` из списка экспортов — это метод
  панели затемнения (`gui.lua:2035`), а не существа, и ни на игроке, ни на прокси, ни на
  g_Module/g_pClientExoApp его нет.
- `CE_HASTE` (единственный CE_* похожий на ускорение, зовётся из
  `CNWCCreature:EnableHasteEffect`) на перемещение НЕ влияет: замерено дважды на шаге
  (1.87 / 1.89) и дважды на беге (7.96 / 8.13). Это скорость атаки и MotionBlur.
- `SetAnimationSpeed` есть на `g_Player:GetModel(255)` и принимается в форме `("", x)`, но она
  меняет АНИМАЦИЮ, а не темп перемещения. Замеры вышли неубедительными (в лаборатории Геральт
  упирается в стены, разброс при одной настройке больше эффекта) — но и по смыслу это тупик.
- Главное: **локомоторных анимаций ровно две**, `walk` и `run`. Современные игры дают плавность
  деревом смешивания с параметром скорости; у Aurora нет ни параметра, ни смешивания. Даже
  протащив промежуточный темп, получили бы едущие по земле ноги.

**Что вместо этого можно**: в `witcher.ini` есть `OVERRIDE=..\Data`, значит можно положить свою
`creaturespeed.2da` и поменять строку 0 — она касается только игрока. Ступеней не добавит, но
позволит выбрать, КАКИЕ две скорости. Разрыв 2.0 против 11.0 сейчас огромен, отсюда ощущение
«или крадусь, или несусь»; шаг около 4.0 сделал бы медленную походку деловой. Не сделано —
это правка данных игры, её откатывает проверка целостности Steam.

## Приёмы замера, которые пригодятся снова
- 🔴 **Расстояние за время мерить нельзя** — стены. При ОДНОЙ настройке путь скакал 10.9 → 13.8.
- 🔴 **Сэмплер бьёт чаще, чем движок обновляет позицию.** Соседние пары нулевые, и «медиана по
  парам» даёт мусор (в одном прогоне 1 значимая пара из сотен). Брать пары, разнесённые минимум
  на 0.25 с.
- Сэмплер удобно вешать на `wxp_rumble.tick` — он и так зовётся каждый heartbeat в мире.
- Разницу вчетверо (шаг/бег) видно любым способом; разницу в 10-20% в этом окружении не поймать
  вообще — нужен открытый участок и управление направлением.

---
# 🔴 БАГ, ИЗ-ЗА КОТОРОГО МОД МОГ МОЛЧА НЕ РАБОТАТЬ ВСЮ СЕССИЮ

Пойман случайно: тестовый канал перестал отвечать, и в логе моста нашлась одна строка
`---- second copy in pid 55605, standing down ----`, при том что процесс игры был ровно один.

Защита от двойной загрузки была написана как `getenv("WXP_BRIDGE_ACTIVE")` + `setenv(...,"1")`.
Но лаунчер переисполняет процесс: первый процесс армится, ставит переменную и отдаёт СВОЁ
ОКРУЖЕНИЕ настоящему процессу игры — тот видит готовую «1» и встаёт смирно. Мод при этом не
делает ничего вообще, а единственный след — эта одна строка в логе.
Поведение непостоянное (вчера всё работало через тот же `open -a`), поэтому баг из тех, что
у пользователя проявляются «иногда» и не воспроизводятся у автора.

Починка: в маркере лежит pid, в котором он поставлен, и сравнивается с `getpid()`. Тогда маркер
означает ровно то, что задумано, — «другая копия В ЭТОМ процессе». Унаследованный маркер от
другого pid логируется отдельной строкой и перетирается.
На Windows такой защиты нет и не нужно: `DllMain` вызывается на загрузку в конкретном процессе.

# ✅ КАРТА: МАРКЕРЫ СТАЛИ КОЛЬЦОМ ФОКУСА

Раньше на карте с пада ходились только вкладки — и это было почти правдой: у экрана 18 контролов,
но из них два служебных (`FogOfWar`, `MapTexture`) и одиннадцать — ШАБЛОНЫ маркеров
(`ActiveQuest`, `ActiveShop`, `ActiveHerb`…), которые движок клонирует в `AddMarker`. Обработчики
есть ровно у двух, и оба пустые (`l_tGuiMapInfo`). Кликать на карте нечего.

Зато есть `lm_tMarkers[uniqueName] = {Control, Template}` — то, что реально на карте нарисовано,
с настоящими координатами (проверено: шесть маркеров, позиции различаются) и с готовыми
`OnTooltip` / `OnMouseEnter` / `SetScale`. Для игрока, который не может ткнуть в карту курсором,
«шагнуть к следующему объекту и услышать, что это» — и есть всё, чем карта полезна.
Сделано: секция `markers`, шаг пространственный, подсветка `SetScale(1.6)` + наведение + тултип.
Порядок сортировки — по чтению; координаты у всех маркеров из одного пространства (одна панель,
одна точка привязки), так что это обычная сортировка, а не та задача с двумя системами координат,
что была у строк настроек.
Проверено вживую (мост в тот момент стоял смирно, поэтому шаги слались прямо в `wxp_intent`):
`markers[6]`, `down → 80000248 → 80000244`, `right → 80000245`, `up → вкладки`, `left → назад`.

---
# ✅ ПОКЕР НА КОСТЯХ — СДЕЛАНО, НО НЕ ПРОВЕРЕНО (соперника в прологе нет)

## Что выяснилось
- В EE зарегистрирована ОДНА мини-игра: `InitializeMinigames` строит
  `l_tGames = { ["Poker"] = MGPoker:new() }` и грузит только `mg_poker_main`.
  4649 строк `mg_dices_main.lua` и `minigame_dices_ex.lua` не грузятся никогда.
- Покер прячет весь игровой интерфейс (`PrepareGui` → `g_GuiInGame:Hide()`) и поднимает свои
  `CLuaPanel` по одной на фазу: `lm_pGuiSetup` (ставка), `lm_pGuiBid` (торговля),
  `lm_pGuiResult`, `lm_pGuiStatus`. Поэтому ни одна ветка `open_panel` его не узнавала.
- Кнопки этих панелей — обычные контролы, их берёт тот же `build_generic`, что и везде;
  панели неактивных фаз отсеиваются проверкой `lm_pPanel:IsActive()`, а `lm_pGuiBid` вдобавок
  сам дёргает `RemoveFromPanel`/`ReAddToPanel` — это уже ловит наша обёртка `wxp_offpanel`.
- **Выбор костей для переброса — клик по кости в 3D-сцене**, контрола нет вовсе.
  Но `MGPoker:OnLMouseDown(pObject)` сверяет `pObject:GetName()` с моделью каждой кости, то есть
  ему можно отдать эту модель НАПРЯМУЮ — и движок сам сделает остальное: эффект выделения
  `mgp_sel_dice`, звук `DICE_SELECT` и переключение в обе стороны.
  Он отказывается работать, пока не поднята камера стола (`lm_nCamera == 4`), а это ровно тот
  момент, когда выбор костей осмыслен, — секция появляется и исчезает сама.
- Подсветка фокуса на кости: контрола нет, поэтому геометрия. У моделей есть `SetScale`
  (проверено на модели игрока: `SetScale`, `SetIllumination`, `SetAlpha`, `SetVisible` есть,
  `SetHighlight` нет), берём `SetScale(1.25)`.
- `cancel` → `MGPoker:OnKeyboardEsc()`, штатный выход движка.

🔴 **Не проверено вживую** — в прологе Каэр Морхена нет ни одного соперника по костям.
Половина с кнопками идёт через тот же сборщик, что и все проверенные экраны, поэтому она
настолько же надёжна; половина с костями — новая земля, и смотреть надо именно её.

# ✅ ШАГ СТАЛ БЫСТРЕЕ: ОВЕРРАЙД CreatureSpeed.2da

Разрыв 2.00 против 11.00 читался как «или крадусь, или несусь». Строка 0 `PC_Movement` касается
ТОЛЬКО игрока, WALKRATE поднят 2.00 → 4.00.
- Путь взят из `System/restype.ini`: у типа 2DA `Path0="OVERRIDE:\2DA"`, а `OVERRIDE=..\Data`
  из `witcher.ini` — значит `<игра>/Data/2DA/`. Игра и сама кладёт `attackeffects.2da` и
  `languages.2da` россыпью в `Data/`, так что корень тоже читается.
- Имя файла взято ровно так, как движок его знает: в строках архива есть `CreatureSpeed`.
  На macOS регистр не важен, на Linux/Proton — может быть.
- **Для игрока без пада это no-op**: клавиши «идти» в игре нет, `startup.lua` включает вечный
  бег, поэтому до строки WALKRATE немодифицированная игра не доходит.
- Установщики кладут и удаляют файл, `.gitattributes` держит CRLF (2DA — формат самой игры,
  её парсер единственный судья).

# 📚 СОВМЕСТИМОСТЬ С ЧУЖИМИ МОДАМИ — по файлам игры, а не по форумам
- **Текстуры/модели/звуки** → `Data/Textures`, `Data/Meshes` (в инструкциях модов почти всегда
  пишут `Data/Override`). С нами не пересекаются вообще.
- **`.2da`** → `Data/2DA/`. Пересечение только по `CreatureSpeed.2da`.
- **Скрипты** → 🔴 **каталога перекрытий у скомпилированных скриптов НЕТ**: у типа `LUC` в
  `restype.ini` нет ни одного `Path`, а алиасы `SCRIPTS` и `SCRIPTS2` оба указывают в
  `System/Scripts`. Значит любой скриптовый мод (Full Combat Rebalance — 182 скрипта) обязан
  переписывать файлы прямо там, как и мы. Мы трогаем ровно один штатный файл — `debug.luc`,
  одна добавленная строка. Порядок: сначала чужой мод, потом наш.
- Текстурные паки на macOS никто не проверял; eON транслирует x86 и DirectX на лету.

---
# ✅ КАРТА ПРОВЕРЕНА · 🔑 КАК ЧИТАТЬ 2DA ИЗ LUA · 🔴 ЗАМЕР СКОРОСТИ БЫЛ НЕДЕЙСТВИТЕЛЕН

## Карта: маркеры работают, и подсказка — главное в них
Скриншоты двух соседних кадров (`down` между ними): фокус `80000244` → `80000248`, и вместе с
ним переезжает всплывающая подпись — «Лестница на второй этаж» → «Вход в лабораторию».
`SetScale(1.6)` на маркере заметен слабо (маркер маленький и тёмный), а вот ИМЯ объекта видно
однозначно. Для игрока без курсора это и есть вся польза карты: шагаешь по объектам и читаешь,
что это. Считаю проверенным.

## 🔑 2DA ИЗ LUA ЧИТАЕТСЯ — не хватало `Load2DArray()`
Старая запись в журнале («`C2DA:new_local("appearance", true)` возвращает 0 строк для любой
таблицы, проверить оверрайд можно только поведением») — НЕВЕРНА. Пропущен один вызов:
```lua
local t = C2DA:new_local("creaturespeed", true)
t:Load2DArray()                     -- <-- без этого GetNumRows() = 0
t:GetNumRows()                      -- 10
t:GetFLOATEntry(0, "WALKRATE", -1)  -- -> ok, "WALKRATE", 4.00
t:GetCExoStringEntry(i, "Label", "")   t:GetINTEntry(i, "Col", 0)
```
Образец был всё это время в `camera.lua:269` (`lm_pDlgCameraShots2DA`).
Значение этого шире одной проверки: теперь ЛЮБУЮ таблицу игры можно прочитать из REPL —
`actions.2da`, `spells.2da`, `attackeffects.2da` — не выковыривая её из `2da00.bif`.

**Результат по нашему оверрайду: `PC_Movement WALKRATE = 4.00` (штатное — 2.00).**
То есть менеджер ресурсов движка находит наш файл в `Data/2DA/` и отдаёт нашу строку.
Путь и имя файла подтверждены на живой игре, а не выведены из `restype.ini`.

## 🔴 Замер походки в этой сессии ничего не доказывал — игра старше файла
Процесс игры стартовал в 12:48:14, а `CreatureSpeed.2da` записан в 12:54:24 — на шесть минут
ПОЗЖЕ. `C2DA:new_local` читает файл с диска сейчас (поэтому и показал 4.00), а движок свою
копию таблицы кэширует, и в запущенном процессе она штатная. Любые замеры походки в такой
сессии сравнивают стоковую таблицу саму с собой.
Отсюда правило: **оверрайд данных проверять ТОЛЬКО с холодного старта, положив файл ДО запуска.**
Сами числа (шаг 1.17, бег 5.0 ед/с) при этом внутренне согласованы — отношение шаг/бег ~4.3,
походка переключается, канал `run:0/run:1` живой. Абсолютные величины вдвое ниже прошлых замеров
в лаборатории; при том же соотношении это разница окружения замера, а не поведения.

## 🔴 `QuickLoad()` из Lua не убирает главное меню
Мир грузится и живёт (HUD рисуется, `Mode=world`, позиция игрока меняется, W работает), но
панель главного меню остаётся сверху — её штатно снимает UI-поток загрузки, который мы обошли.
Симптом обманчивый: скриншот показывает главное меню, а состояние говорит `Mode=world`, и оба
правы. Лечится одной строкой — у игры есть своя `unloadMM()` (`gui_mainmenu.lua:611`), после неё
`g_pMainMenuPanel = nil` и на экране мир.
Полезно и для будущих безэкранных прогонов: `GetLoadSaveSystem():QuickLoad()` + `unloadMM()` —
это заезд в мир без единого клика.

## Замер скорости: мерить надо по НАСТЕННОМУ времени
`getWorldTimeDelta()` идёт РОВНО вдвое быстрее реального времени (проверено: за 3.0 с настенных
накапливается 6.0). Это не «игра тормозит» — просто другая единица. Для «ощущается ли быстрее»
осмысленно только настенное время, по нему игрок и судит.

---
# 🔴 CreatureSpeed.2da УБРАН: он никогда не работал. Разбор с пятью холодными стартами

Прошлая запись обещала «шаг 2.00 → 4.00 делает медленную походку деловой». Проверка с
холодного старта показала: файл не менял НИЧЕГО, и обещание было основано на замере, которого
не было. Пять перезапусков подряд, каждый — файл на диске ДО старта, значения подтверждены
через `C2DA` уже в загруженной игре, замер с одной и той же точки 1388 1484:

| что в файле | шаг | бег |
|---|---|---|
| штатные значения | 1.18 | 5.05 |
| строка 0 `PLAYER` WALKRATE 2.00→4.00 | 1.17 | 5.05 |
| строка 9 `WITCHER` WALKRATE 1.70→3.40 | 1.18 | 5.21 |
| строка 9 `WITCHER` MOVERATE 1.0→2.0 | 1.09 | 4.74 |
| строка 0 `PLAYER` MOVERATE 1.0→2.0 | 1.12 | 4.96 |
| ВСЕ строки WALKRATE 9.00 + MOVERATE 3.0 | 3.20 | 14.09 |

## Почему ни одна «правильная» строка не сработала
Строку скорости существо берёт из СВОЕГО blueprint-поля `WalkRate` — это целый индекс строки
в `creaturespeed`, и видно это в шаблоне редактора самой игры
(`djinni_templates.lua:471`: `VisibleAs = "Movement Rate"`, `_2daFileName = "creaturespeed"`,
`_2daColName = "Label"`, `GFFName = "WalkRate"`, `GFFType = "INT"`).
То есть колонка `MOVERATE` в `appearance.2da` (у внешности игрока `cr_witch1_c1g1` там стоит
`WITCHER`) — НЕ то, чем движок пользуется в рантайме, и именно она увела в сторону.
Какая строка у Геральта на самом деле — из Lua не спросить: геттера нет
(`proxy:GetAppearanceType()` = 0, ничего вроде `GetWalkRate` в 1275 экспортах нет).

## Почему это всё равно тупик
В последнем прогоне обе походки выросли ОДИНАКОВО (×2.71 и ×2.77 при `MOVERATE` 1.0→3.0),
хотя `RUNRATE` не трогался вовсе. Значит `MOVERATE` — равномерный множитель, а `WALKRATE`/
`RUNRATE` на перемещение игрока не влияют. Равномерный множитель разрыв между шагом и бегом
(≈4.3×) не сужает — а сузить его и было единственной целью. Отношение задано АНИМАЦИЯМИ.

## Ещё две находки по дороге
- **`creaturespeed` в ресурсах игры под этим именем НЕТ.** Убрали файл — `GetNumRows()` стал 0
  (для сравнения `appearance` отдаёт 723). То есть мы не перекрывали таблицу, а ДОБАВЛЯЛИ её.
  Отсюда и мораль: прежде чем «перекрывать» 2DA, спросить `C2DA` без своего файла — есть ли она.
- **`SetAnimationSpeed("", x)` на модели игрока перемещение не меняет** (проверено 1.0/2.0/3.0 —
  1.18/1.19/1.16). Локомоция не ведётся корневым движением анимации.

## 🔴 Метрика «максимум по парам» ловит рельеф
Единственный прогон, где скорость выросла, стартовал с ДРУГОЙ точки (1374 1491). Шесть
контрольных замеров на ровном месте (dz ≈ 0) дали 1.12–1.13 без единого выброса. Считать
результат замера действительным можно только вместе с координатой старта и Δz.

## Итог
`mod/data/2DA/CreatureSpeed.2da` удалён; вычищен из `package.sh` и трёх установщиков; в
деинсталляторах снос ОСТАВЛЕН — у тех, кто ставил версии до 0.6, файл лежит в игре.
В README убрано обещание про скорость шага и строка про столкновение модов по этой таблице
(своих таблиц мод больше не ставит). Две скорости на стике остаются и работают — менялся
только этот несостоявшийся довесок.

## Ответ на «а динамическую скорость на стик?» — окончательно нет
Перебрал экспортированные имена по владельцам (`g_Player`, прокси, модель, `g_Module`,
`g_pClientExoApp`, `g_cAuroraSettings`): из скоростного есть только
`g_pClientExoApp:SetAlwaysRun` и `model:SetAnimationSpeed` (на перемещение не влияет).
Рантайм-ручки скорости нет, таблица читается при загрузке, анимаций две и смешивания нет.

## 🔴 Побочно: `zip` ДОПИСЫВАЕТ в архив, а не пересоздаёт его
`package.sh` чистил папку сборки (`rm -rf "$OUT"`), но не сам `.zip`. `zip -qr` по существующему
архиву делает обновление, поэтому удалённый из мода `CreatureSpeed.2da` остался в пакете —
с датой прошлой сборки, что и выдало. Любой убранный файл уезжал бы в релиз так же тихо.
Добавлен `rm -f` архива перед упаковкой. Проверено: в пересобранном пакете 2DA-записей ноль.

## 🔴 ПОПРАВКА К ПРЕДЫДУЩЕМУ РАЗДЕЛУ: таблица РАБОТАЕТ, вывод был перегибом
Предыдущая запись объявила единственный «быстрый» прогон артефактом рельефа. Это неверно, и
опроверг это пользователь, смотревший в экран: «побежал аки конь» пришло сразу после прогона
3.21/14.09, а «сейчас очень медленно» — после следующего, где вышло 1.09/4.74. Наблюдения глазами
совпали с числами один в один, то есть эффект был настоящий и держался весь прогон, а не был
всплеском на паре сэмплов.
Ошибка рассуждения: шесть «контрольных» замеров по ровному месту делались уже БЕЗ файла и мерили
базовую скорость. К прогону со всеми поднятыми строками они отношения не имели, а я предъявил их
как опровержение. Контроль обязан отличаться от опыта РОВНО одним условием.

**Как есть на самом деле:**
- `creaturespeed.2da` (как добавленный файл) движком читается и на игрока влияет.
- Строка Геральта — не 0 `PLAYER` и не 9 `WITCHER` (обе проверены по отдельности, ноль эффекта),
  а одна из {2 VSLOW, 3 SLOW, 4 NORM, 5 FAST, 6 VFAST, 8 DFAST}: только они менялись в общем
  прогоне. Спросить движок нельзя — строка лежит в blueprint-поле `WalkRate` самого существа.
- Рычаг — `MOVERATE`: в общем прогоне обе походки выросли ОДИНАКОВО (×2.71 и ×2.77), хотя
  `RUNRATE` не трогался, а `WALKRATE` рос в 5 раз. Это равномерный множитель.
- Поэтому вывод «разрыв шаг/бег не сузить» ОСТАЁТСЯ верным, и решение не шипать файл тоже:
  равномерный множитель ускоряет и шаг, и бег, а просили сузить разрыв.

**Как найти строку за ОДИН холодный старт (если понадобится):** дать шести кандидатам РАЗНЫЕ
множители (`MOVERATE` 1.5/2.0/2.5/3.0/3.5/4.0), замерить шаг один раз и опознать строку по
отношению к базовым 1.18. Перебор по одной строке стоил бы шести перезапусков.

## ✅ СТРОКА ГЕРАЛЬТА НАЙДЕНА: 5 `FAST`. И именно поэтому её трогать нельзя
Опознана за ОДИН холодный старт приёмом «разные множители кандидатам»: строкам 2/3/4/5/6/8 роздан
`MOVERATE` 1.5/2.0/2.5/3.0/3.5/4.0, замер шага один раз.
Результат: **3.18 / 3.24 / 3.20** на ровном месте (dz ≈ 0). Множитель 3.0 стоял только на строке 5.
Проверка сходится дважды: прогон, где 3.0 стояло на ВСЕХ строках, дал ровно те же 3.20/3.21;
будь Геральт на `NORM` (там сейчас было 2.5), вышло бы ≈2.7.

**Строка общая, и это ставит крест на затее.** Пользователь во время замера сам заметил:
«Ламберт как будто быстрее анимации ходьбы стали». На `FAST` сидит не только Геральт — как минимум
остальные ведьмаки тоже. Значит `MOVERATE` здесь не «скорость игрока», а темп заметной части
персонажей игры; настройкой мода такое выдавать нельзя.
Дать Геральту собственную строку не выйдет: номер строки лежит в его blueprint-поле `WalkRate`
(GFF, INT), а писать туда из Lua нечем — добавленная строка 10 осталась бы ничьей.

Итог не изменился: файл в мод не возвращается, две скорости на стике остаются как есть.
Зато вопрос закрыт до конца и переспрашивать его больше не нужно.

### Приём, который стоит помнить
Когда кандидатов N, а проверка стоит холодного старта, не перебирать по одному — раздать всем
РАЗНЫЕ величины и опознать нужного по значению отклика. Шесть перезапусков превратились в один.

### И ещё раз про наблюдателя
Второй раз за сессию решающее свидетельство дал человек, смотревший в экран, а не замер:
сперва «побежал аки конь» опровергло мой вывод «таблица не работает», потом «Ламберт стал быстрее»
показало, что строка общая, — этого ни один мой замер скорости игрока показать не мог.

---
# ✅ WINDOWS-МОСТ ЗАПУЩЕН ВЖИВУЮ — ПОД CROSSOVER, БЕЗ ИГРЫ

Windows-половина не проверялась ни разу и была самым большим риском. Оказалось, её можно
проверить прямо здесь: CrossOver — это Wine, а мост рассчитан ровно на обычный PE-загрузчик
Wine (которого у eON нет и быть не может). Игру для этого устанавливать НЕ пришлось.

## Обстановка
CrossOver 25.0, бутылка `Steam` (шаблон win10_64), macOS 27 на arm64. 32-битные PE тянутся
новым WoW64 поверх 64-битного хоста — отдельного 32-битного загрузчика больше нет, поэтому
`lipo` показывает только x86_64, и это не препятствие. `drive_c/windows/syswow64` — 893 файла,
`xinput1_3/1_4`, `dinput8`, `user32`, `ucrtbase`, `msvcrt` на месте.

## 🔑 Снято допущение про UCRT
Файлов `api-ms-win-crt-*` в бутылке НОЛЬ — ровно те импорты, из-за которых PE не грузился под
eON. В журнале стояло «Wine/Proton апісеты UCRT предоставляют» — допущением. Проверено опытом:
32-битный тест сделал `LoadLibraryA` нашего `LightFX.dll` → **OK, база 0x7BAF0000**, все четыре
проверенных экспорта (`LFX_Initialize/Release/Update/GetNumDevices`) резолвятся по неукрашенным
именам. Значит Wine разрешает апісеты своим механизмом в ntdll, без файлов на диске.
Требование «собирать freestanding» окончательно снято — и теперь по факту, а не по вере.

## 🔑 XInput под Wine щедрее настоящей Windows
Грузятся ВСЕ четыре: `xinput1_4`, `1_3`, `9_1_0`, `1_2`, и у КАЖДОЙ есть `XInputSetState`.
На настоящей Windows у `xinput9_1_0` его нет — мост это предусматривает и логирует как
отсутствующую фичу. Под Wine/Proton вибрация будет работать при любой подхваченной библиотеке.

## Мост поднят полностью (лог из бутылки)
Разложено фальшивое дерево `C:\wxpgame\System\lightfx\wxp\LightFX.dll` (мост считает корень,
поднимаясь на 4 уровня) + `gamepad.ini`. Тест держал DLL загруженной 12 секунд:
```
==== WitcherPadBridge (Windows) dev, pid 212, 2026-08-24, epoch ... ====
game root   : C:\wxpgame
runtime     : Wine/Proton 10.0          <- проба wine_get_version работает
xinput: xinput1_4.dll (vibration yes)
config: dzL=0.20 dzR=0.16 sens=1400/900 curve=1.70 invY=0 en=1 menu=700
config: aim=1 (on attack) aimSpeed=2200 logLevel=2
config: active pause on touchpad   rumble=1 strength=100%   run threshold=0.70
System writable: yes
pad: no controller on any XInput slot.
```
То есть проверено вживую: DllMain, самопиннинг, вычисление путей, ротация лога, определение
среды, дамп окружения, проверка записи в `System`, загрузка XInput, разбор ОБОИХ конфигов
включая строковый `PauseButton`, `LogLevel=2` без перезапуска, и корректный отчёт об отсутствии
пада с подсказкой про Steam Input.

## Что осталось непроверенным
1. Грузит ли САМА игра `System\lightfx\wxp\LightFX.dll` — это её поведение, а не наше;
   на macOS оно подтверждено логами eON, но под Wine не наблюдалось. Нужна игра в бутылке.
2. Доходит ли `SendInput` со скан-кодами до Aurora и `SetCursorPos` до камеры. Нужна игра.
3. Чтение пада через XInput Wine — пад в момент проверки просто не был подключён.
   Это проверяется БЕЗ игры: воткнуть DualSense и перезапустить тот же тест.

## Как повторить
```
B="$HOME/Library/Application Support/CrossOver/Bottles/Steam/drive_c"
CX=/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin
"$CX/wine" --bottle Steam --workdir 'C:\wxp' --cx-app 'C:\wxp\wxphold.exe'
cat "$B/wxpgame/System/wxp_bridge.log"
```
Артефакты теста лежат в бутылке: `C:\wxp\` (wxptest.exe, wxphold.exe) и `C:\wxpgame\`.

---
# ✅✅ WINDOWS/PROTON РАБОТАЕТ НА ЖИВОМ ЖЕЛЕЗЕ (ROG Ally X, Bazzite)

Последняя недоказанная опора проекта закрыта. Установка по SSH, Bazzite 43 (Kinoite),
kernel 6.17.7, Proton 11.0, appid 20900, игра в `~/.local/share/Steam/steamapps/common/`.

## 🔴 БЛОКЕР, КОТОРОГО НИКТО НЕ ЖДАЛ: игра не грузила DLL из-за ВЕРСИИ WINDOWS
Первый запуск: Lua-слой поднялся идеально, а `wxp_bridge.log` не появился вовсе.
Причина нашлась в строках `witcher.exe`:
```
lightfx\%s\LightFX.dll
Unable to connect to LightFX.dll. Path: '%s', GetLastError() returned: 0x%x
Not supported version of Windows!            <-- вот оно
No lightfx.2da present.
```
`%s` — имя папки по версии Windows (SDK AlienFX возил свои DLL по папкам под каждую ОС;
на macOS eON представляется XP, поэтому там путь и был `lightfx\wxp\`). Префикс Proton
представляется **Windows 10 Pro build 19045**, игра 2007 года такую версию не знает, пишет
«Not supported version of Windows!» и до построения пути ВООБЩЕ НЕ ДОХОДИТ.

**Лечение — оверрайд версии только для одного exe**, остальной префикс остаётся десяткой.
В `compatdata/20900/pfx/user.reg`:
```
[Software\\Wine\\AppDefaults\\witcher.exe] <время>
#time=...
"Version"="winxp"
```
🔴 Правку делать ТОЛЬКО при закрытой игре: wineserver при выходе перезаписывает `user.reg`
своей копией и правка потеряется.
Подтверждение в логе моста после перезапуска: `reported ver: 5.1 build 2600` (было 6.2/10.0).

Это ОБЯЗАТЕЛЬНЫЙ шаг установки на Proton, а не местная особенность — он следует из кода самой
игры. Должен уехать в установщик и README.

## Что подтверждено логом моста (ROG Ally X, живой прогон)
```
==== WitcherPadBridge (Windows) 0.6-rc1, pid 316 ====
loaded from : S:\common\The Witcher Enhanced Edition\System\lightfx\wxp\LightFX.dll
game root   : S:\common\The Witcher Enhanced Edition
runtime     : Wine/Proton 11.0
reported ver: 5.1 build 2600
System writable: yes
xinput: xinput1_4.dll (vibration yes)
config: ... (gamepad.ini + wxp_config.ini)     <-- оба конфига, вкладка тоже
lua: state file seen -- the script layer is installed and ticking
pad: connected on slot 0
nav: 1 down / 2 up / ...
```
- **Игра сама грузит наш DLL** своим механизмом LightFX — без инжектора, без патча exe.
  На macOS этот путь невозможен в принципе (см. разбор VPFS), здесь он живой.
- **Proton отдаёт игре диск `S:`** — корень игры вычислился как `S:\common\The Witcher...`,
  то есть подъём на 4 уровня от пути DLL отработал на непривычной раскладке дисков.
- Пад виден на слоте 0, `xinput1_4` с вибрацией.
- Обе половины видят друг друга: мост читает `wxp_state.ini`, Lua читает `wxp_nav.txt`.
- Навигация с креста дошла до экрана загрузки и листает список сейвов:
  `Section=System.InGameNewSystemLoadPanel:ScrollView`,
  `Focus=ListButton_39_Дом Трисс 2016/09/14 23:32:19_For_ScrollView`.

## Lua-слой на Proton — с холодного старта, без единой правки
```
==== WitcherPadBridge Lua layer 0.6-rc1 ====
cfg: registered 14 settings
hook installed: OnHeartbeat / TogglePanel / OnPostAttachmentInitialize / SwitchPanel
```
Те же `.luc`, собранные нашим пропатченным luac, исполняются и на eON, и на Proton.

## Обстановка на Ally
- Пад системе виден как `Microsoft X-Box 360 pad` (плюс js0..js2).
- **Steam Input для игры надо выключать**: у The Witcher нет штатной поддержки пада, поэтому
  Steam накидывает шаблон «клавиатура и мышь» и шлёт в игру клавиши вместо XInput.
- SSH на Bazzite выключен по умолчанию (`systemctl enable --now sshd`), `~/.ssh` создаётся руками,
  и на Fedora Atomic не забыть `restorecon -R ~/.ssh` — иначе SELinux не даст sshd прочитать ключ.

## Что подтверждено на Ally сверх загрузки моста
- **Вибрация работает под Proton** — пользователь подтвердил на слух, мост записал
  `rumble: 1000/1000 for 700 ms`. Путь XInput → SDL → evdev живой, догадка «должно работать»
  больше не догадка.
- **Походка от стика** — `nav run:0 -> walk` / `nav run:1 -> run` в логе Lua.
- **Горячее перечитывание конфига** — `logLevel=1` → `logLevel=2` на ходу, без перезапуска игры.
- **REPL-канал `wxp_cmd.txt` работает и на Ally**: пишем Lua по SSH, ответ приходит в
  `wxp_gamepad.log`. То есть удалённая отладка на чужой машине возможна ровно так же, как локальная.
- **Оба конфига** читаются: `gamepad.ini + wxp_config.ini`, вкладка в игре пишет свой.

## 🔴 НАХОДКА: с пада играбельна ТОЛЬКО камера слежения
Жалоба: «правый стик как мышь работает». Причина не в мосте. У игры три камеры (изометрия,
гибрид, слежение из-за плеча), и **курсор запинан в центр только в камере слежения** — там его
сдвиг поворачивает вид, и это то, на чём делалась вся работа с прицелом. В изометрии и гибриде
курсор свободный, им тычут в землю, поэтому правый стик честно работает указателем.
Пользователь переключил на слежение — «и всё ок».
**Переключения камер на кнопках пада у нас нет вообще** (F1/F2/F3 не привязаны), то есть игрок,
у которого сейв сделан в другой камере, упирается в это сразу и без клавиатуры не выберется.
Механизм известен: `CGuiInGame:OnSwitchCameraMode(nMode)`, `nMode` 0/1/2 или -1 для цикла
(`gui.lua:967`), режим лежит в `g_Camera.lm_nGameOptionsMode`.
Сделать: интент `camera` + кнопка, и/или предупреждение в README.

---
# 📏 МАСШТАБ ИНТЕРФЕЙСА: разведка на живой игре (запрос с Ally, экран 7")

Жалоба: «на экране элементы маленькие, не хватает настройки масштаба интерфейса в разделе графика».
Разбиралось прямо на Ally через REPL по SSH, со снимками экрана после каждого шага.

## 🔑 Снимок экрана игры БЕЗ внешних инструментов
На Bazzite в игровом режиме ни `grim`, ни `import` не подключаются (нет доступа к дисплею,
`/proc/<pid>/environ` чужих процессов не читается). Зато снимок умеет сама игра:
```lua
console("snapshot wxp_shot")     -- -> <game>/System/wxp_shot.tga, 1920x1080
```
`console` доступна в Lua с самого старта. Это же работает на любой машине пользователя.

## Почему снижение разрешения НЕ поможет
`g_pGuiMan:GetGuiWidth()/GetGuiHeight()` на экране 1920x1080 дают **1365 x 768**.
Высота GUI ВСЕГДА 768 единиц, ширина = 768 × соотношение сторон (768 × 16/9 = 1365).
То есть интерфейс — постоянная доля экрана при любом разрешении, и он растягивается, а не
рисуется в пикселях. Смена разрешения или соотношения сторон физический размер не меняет:
на 4:3 панели заняли бы всю ширину кадра, но сам кадр стал бы уже ровно во столько же раз.

## Что пробовали и что вышло
1. **`panel.lm_pPanel.m_pModel:SetScale(1.3)`** — метод есть, возвращает true, но
   `GetObjectScale()` остаётся 1, а на экране **исчезает вся декоративная подложка панели**
   (у дневника пропали рамка и рисунок, текст и кнопки остались на местах). То есть модель
   панели — это только её задник, дочерние контролы к нему не привязаны. Путь ломает вид.
2. **`control:SetScale(1.4)` на всех контролах HUD** — РАБОТАЕТ и выглядит почти хорошо:
   медальон, кольцо и полосы выросли, кластер не рассыпался, потому что все контролы прижаты
   к одному углу экрана. НО **полоса здоровья разъезжается со своей оправой**: каждый контрол
   растёт от СВОЕГО угла, поэтому элементы, которые должны совпадать, расходятся.
3. **Масштаб + перенос позиций от якоря экрана** (`x*k`, `AY-(AY-y)*k` в Aurora-единицах
   10.24x7.68, Y вверх) — позиции читаются нормально
   (`EnduranceBarColors` = 1.222, 7.379), но на экране НИЧЕГО не меняется:
   **панель HUD пересчитывает положение своих контролов каждый кадр** (полосы живые) и
   затирает нашу правку следующим тиком.

## Вывод и что реально можно
Глобального рычага у движка нет: у `g_pGuiMan` нет ни одного метода масштаба
(`GetActualGuiWidth`/`GetStandardGuiHeight` есть только в списке экспортов, на объекте их нет).
Честный масштаб = увеличивать КАЖДЫЙ контрол и одновременно разводить позиции от якоря,
**переприменяя это каждый кадр** — heartbeat у нас есть, так что технически возможно.
Цена: борьба с собственной раскладкой игры, риск дрожания, и делать придётся отдельно для
HUD и для каждой панели (у панелей настроек и привязок координаты вообще в других
пространствах — это уже ловило нас раньше).
Начинать имеет смысл с HUD: элементов мало, смотришь на них постоянно, и там уже видно, что
масштабирование само по себе работает.

## Побочно увидено на снимках
Панели сделаны под 4:3 и на 16:9 занимают правые ~75% ширины — у дневника слева остаётся дыра,
сквозь которую видно мир. Это не наша поломка, так игра и рисует.

## Доведено до конца: масштаб HUD НЕ выйдет, и вот почему именно
Продолжение опытов на Ally. Две мои прошлые ошибки исправлены, после чего механика стала ясна.

🔴 **`SetPosition` тремя числами — ОШИБКА tolua**, нужен `Vector`:
```lua
local v = Vector:new_local(x, y, z)
c.m_pModel:SetPosition(v)          -- работает
c.m_pModel:SetPosition(x, y, z)    -- error in function 'SetPosition'
```
Прошлый вывод «перенос не подействовал» был неверен: вызов молча падал внутри `pcall`.

🔴 **Панель восстанавливает позиции своих контролов**: поставили (3.0, 3.0) — прочиталось
(3.0, 3.0), через секунду снова (-0.375, 6.096). Значит правку надо переприменять каждый кадр.
Это сделано (слой поверх `wxp_rumble.tick`) и РАБОТАЕТ — позиции держатся.

**И всё равно тупик, по двум независимым причинам:**
1. **Динамические элементы.** Полосы здоровья и выносливости панель пересчитывает по текущему
   значению каждый кадр. Масштаб с этим не складывается: красная и жёлтая полосы разъезжаются
   друг с другом и с декоративной оправой.
2. **Композиция размазана по РАЗНЫМ панелям.** Отмасштабировали только миникарту — диск вырос
   и выехал из своей оправы, потому что кольцо, «когти» и колонка иконок принадлежат другой
   панели. Масштабировать надо всё вместе, а вместе с ними приезжает пункт 1.
   Плюс у панелей разные якоря (статус — левый верх, миникарта — правый верх), то есть
   единой формулы переноса нет в принципе.

**Что это значит:** честный «масштаб интерфейса» — это не ползунок, а поштучная перевёрстка
каждой группы HUD со своим якорем и исключением динамических элементов, переприменяемая каждый
кадр. Выполнимо, но это отдельный проект с высоким риском получить дрожание и разъезды, и
делать пришлось бы отдельно для HUD и для каждой панели.
Всё в опытах обратимо: масштаб 1.0 + возврат сохранённых позиций восстанавливает вид полностью
(проверено снимком).

**Что дёшево и помогает на маленьком экране:** у нас уже есть увеличение того, что в фокусе
(`SLOT_SCALE` 1.35, `MARKER_SCALE` 1.6). Это единственное масштабирование, которое здесь
работает надёжно — потому что касается ОДНОГО контрола и не ломает ничьё выравнивание.

---
# 🔤 РАЗМЕР ТЕКСТА: решается, и через 2DA. Полный разбор

Масштаб интерфейса целиком невозможен (см. выше), но настоящая жалоба на маленьком экране —
это ЧИТАЕМОСТЬ. Она решается, и штатным механизмом игры.

## Таблица `fonts.2da` — 15 строк, 5 колонок
Читается из Lua (`C2DA` + `Load2DArray`), но имена колонок оттуда не достать
(`GetColumnLabel` отдаёт nil в обеих формах вызова). Достаём из архива напрямую — надёжно
и без ключа: в `Data/2da00.bif` 219 таблиц, ищем блоб, начинающийся с `2DA V2.0` и содержащий
`gui_default`:
```
	Label            	TrueType 	Points	Outline	MinSize
0	default          	arial    	16    	1      	11
1	console          	lucon    	14    	1      	10
2	smallinfo        	arial    	16    	1      	11
3	gui_infopanel    	garamond 	30    	1      	11
4	gui_default      	garamonds	18    	0      	11     <- основной текст панелей
5	gui_label        	garamonds	24    	1      	11
6	gui_bigger       	garamonds	24    	1      	11
7	gui_huge         	garamond 	30    	1      	11
8	gui_icon         	garamonds	18    	0      	11
9	gui_infopanel_big	garamond 	30    	1      	10
10	fnt_galahad14    	arial    	16    	1      	11
11	subtitle         	arial    	20    	1      	11     <- субтитры
12	choices          	arial    	16    	1      	11     <- реплики в диалоге
13	tutorial         	garamond 	20    	0      	11
14	credits          	garamond 	30    	1      	11
```

## ✅ Оверрайд `Data/2DA/fonts.2da` РАБОТАЕТ (в отличие от creaturespeed)
Положили свой файл — движок читает наши значения (`gui_label=28` вместо 24). Разница с
`creaturespeed` в том, что `fonts` В ресурсной системе есть (15 строк и без нашего файла),
поэтому перекрытие срабатывает штатно. Популярный мод (#782) для того же самого
**перезаписывает весь `2da00.bif`** — наш путь обратим удалением одного файла.
🔴 Таблица кэшируется при старте: правка требует ПЕРЕЗАПУСКА игры, `rebuildfontcache` не помогает.

## 🔴 ГЛАВНОЕ ОГРАНИЧЕНИЕ: размер можно взять только ГОТОВЫЙ
Первая попытка (Points 32/27) не дала НИЧЕГО, хотя движок новые числа прочитал. Причина:
игра не растеризует шрифт, а берёт готовый атлас `System/__cache/<шрифт>_<размер>_<o|n>.fontcache`
(81 файл). Своих TTF у игры нет вообще, `rebuildfontcache` не создал ни одного файла.
Значит выбирать можно ТОЛЬКО из напечённых размеров. Ровно это и делает мод #782:
«заменяет мелкие шрифты более крупными, КОТОРЫЕ УЖЕ ЕСТЬ В ИГРЕ, но редко используются».
Ладдеры (сняты с живой игры, `o` = с обводкой, `n` = без):
```
arial      o: 11 12 14 15 16 17 18 20 23     n: —
garamond   n: 11 15 17 20 23                 o: 17 22 23 26 30 35
garamonds  n: 11 13 14 15 18 21              o: 14 18 21 24 28
```
Отсюда приём: **колонка `Outline` меняет не только вид, но и доступный ладдер**. У `gui_default`
без обводки потолок 21 (всего +17%), а с обводкой открывается 24 и 28. Обводка на пёстром фоне
читаемости обычно помогает, так что размен выгодный.

## Проверено на Ally
Первый заход (потолки без смены обводки): `default` 16→23, `gui_default` 18→21, `gui_label` 24→28,
`subtitle` 20→23. Снимки до/после одного и того же экрана дневника: разница есть, но скромная —
строки списка чуть крупнее, межстрочный интервал шире. Ровно те +17% у `gui_default`.
Второй заход: `gui_default` и `gui_icon` 18→24 с обводкой, `tutorial` 20→26 с обводкой.

## Приёмы, которые тут пригодились
- **Снимок экрана силами самой игры**: `console("snapshot имя")` → `System/имя.tga`.
  На Bazzite в игровом режиме это единственный работающий способ (ни `grim`, ни `import`
  не подключаются, `/proc/<pid>/environ` чужих процессов не читается).
- **Достать любую таблицу из `2da00.bif` без ключа**: искать `2DA V2.0` и опознавать по
  содержимому. 219 таблиц, заголовок с именами колонок — первая строка после пустой.

## 🔴 ПОЧЕМУ ПРОПАДАЛ ТЕКСТ: в атласе нет кириллицы (а не формат файла)
Три захода закончились исчезновением ВСЕГО текста. Формат файла был ни при чём — холостой
прогон патчера дал байт-в-байт тот же md5, что и оригинал из архива, и точная копия работала.

Разгадка пришла от двух наблюдений:
1. Метрики текста НЕНУЛЕВЫЕ (`control:GetTextDimensions()` отдавал 103.1 x 37.7 и для латиницы,
   и для кириллицы) — то есть разметка идёт, а глифы не рисуются.
2. На снимке ВКЛАДКИ дневника рисовались, а список — нет. Значит ломались не все строки таблицы,
   а конкретные.

**Вывод: атлас существует, но кириллицы в нём нет.** Файлы вроде `garabd_21_n` / `garabd_23_n`
лежат в `__cache`, но испечены для латинских языков (Польша, кодовая страница 1250) — русская
таблица их не использует. Подставляем такой размер → метрики есть, глифы пустые, текст невидим.

**Для русского годятся ТОЛЬКО размеры из штатной русской таблицы:**
```
garabd без обводки: 18, 20      garabd с обводкой: 24, 30      arial: 16, 20      lucon: 14
```
Отсюда итоговая (проверенная) русская таблица: `default/smallinfo/choices/fnt_galahad14` 16→20,
`gui_default`/`gui_icon` 18→20, `gui_label`/`gui_bigger` 24→30. Прибавка четверть на репликах и
заголовках, одна девятая на основном тексте панелей. Больше — только со своими атласами
(этим, судя по всему, и занимается русский мод Nexus #777).

**Цена:** длинные названия в списках обрезаются, ширина фиксированная. Пользователь заметил,
что это уже решено — полное название показывает наша всплывашка на элементе под фокусом.

## Оформлено как отдельная, обратимая вещь
`mod/extras/bigger-text/{fonts.2da,fonts_rus.2da}` + `tools/bigger_text.sh on|off`.
Ставится и снимается независимо от мода, кладёт два файла в `Data/2DA/` и больше ничего.
Русская таблица проверена на живой игре, латинская собрана тем же способом, но не проверена —
английской сборки под рукой нет, и в README это написано прямо.

## Инструменты, которые появились по дороге (SSH-цикл без человека)
- `wxp_restart.sh` — быстрое сохранение через Lua, если мы в мире, затем `pkill` и
  `steam steam://rungameid/20900`. Ожидание — по СЧЁТЧИКУ баннеров в логе Lua; первая версия
  ждала «свежести файла состояния» и ловила хвост умирающей сессии.
- `wxp_cycle.sh` — перезапуск → `QuickLoad()` → `unloadMM()` → `wxp_intent("open:diary")` →
  `console("snapshot ...")`. Полный круг проверки правки данных без единого касания приставки.

---
# 🔴 ПОПРАВКА: скорость шага РЕГУЛИРУЕТСЯ. Я копал не ту таблицу

Журнал дважды утверждал, что разрыв шаг/бег задан анимациями и не сужается. Это неверно.
Подсказка пришла от пользователя — описание мода Faster Movement (Nexus #256) называет **вторую**
таблицу, о которой я не знал.

## `moverates.2da` — вот где живёт скорость игрока
173 строки, ключ — имя существа, у Геральта строка `chr_geralt`. Колонки:
```
	Label        	default	walk	run 	walkdrn	cf_pain02_walk	cf_fear02_run	walkb
0	Default      	1.7    	1.52	3.22	1.55   	1.2           	2.6          	1.52
1	chr_geralt   	1.7    	1.54	3.30	1.55   	1.2           	2.6          	1.52
```
**`walk` и `run` — отдельные колонки.** То есть шаг можно менять, не трогая бег, — ровно то,
что я объявил невозможным. `creaturespeed.2da`, в которую я упирался, к перемещению игрока
отношения не имеет (все мои правки там действительно ничего не давали — и это было верно,
неверен был вывод «значит нельзя вообще»).

Оверрайд `Data/2DA/moverates.2da` подхватывается (проверено). Автор мода кладёт файлы в
`Data/Override` россыпью и предупреждает: после первой загрузки эффекта может не быть, надо
перезайти в сейв или сменить локацию.

## 🔴 Зависимость НЕ линейная: есть порог, за которым шаг превращается в бег
Замер на живой игре (Ally, сэмплер мгновенной скорости, пользователь держит стик):
```
walk 1.54 (штат) -> шаг 1.17   бег 5.05
walk 2.30        -> шаг 5.12   бег 4.95   <- шаг стал бегом
```
Табличное значение выросло в 1.5 раза, измеренная скорость — вчетверо, и упёрлась в беговую.
Похоже, движок выбирает локомоторную анимацию по скорости: перевалило порог — включается бег,
и дальше темп задаёт уже она. Это, кстати, объясняет старое наблюдение «анимаций ровно две»:
они действительно две, но выбор между ними управляем.
Рабочий диапазон — между 1.54 и порогом; ищем перебором.

## Как мерить без клавиатуры на приставке
У windows-моста тестового канала ввода нет (это есть только на macOS через `/tmp/wxp_cmd`),
поэтому нажать W из кода нечем. `g_pClientExoApp:WalkPlayerToPoint(Vector)` существует, но
надёжнее оказалось попросить пользователя держать стик, пока Lua-сэмплер снимает позицию.

## 🔴 Осторожно с `unloadMM()` в автоматическом цикле
`unloadMM()` удаляет и `g_pGuiMan.lm_pInGameNewSystemPanel`. Если вызвать его, когда загрузка
ещё не завершилась и игра осталась в меню, панель исчезает из-под ног, и следующая же навигация
с пада роняет игру (проверено: процесс закрылся). Звать только при `Mode=world` И живом
`g_GuiInGame`.

---
# ✅ РЕЛИЗ 0.6 — и блокер, который чуть не уехал в него

Вопрос «у нас релизы актуальные?» вскрыл больше, чем просроченный тег.

## Опубликовано было v0.5 (23 августа), а с тех пор произошло примерно всё
30 коммитов: вибрация на обеих платформах, активная пауза, шаг/бег на стике, автонаведение как
настройка, экраны «Управление» и «Новая игра», иконки в диалогах, маркеры карты, покер,
логирование для чужих машин, снос несостоявшегося `CreatureSpeed.2da` — и, главное, вся
Windows/Proton-половина, доказанная на живом железе.

## 🔴 Блокер: обязательный шаг для Proton не был нигде записан
`grep -rn 'winxp|AppDefaults|user.reg' tools/ README.md` — пусто. То есть находка 25 августа
(игра печатает `Not supported version of Windows!` и до построения пути `lightfx\<версия>\
LightFX.dll` не доходит вовсе) жила только в журнале. Собранный пакет `0.6-rc4` был технически
исправен и при этом бесполезен для КАЖДОГО пользователя Steam Deck / Bazzite / Ally: мост не
загрузился бы, а выглядело бы это как «мод молча не работает» — ровно тот симптом, на который
здесь ушло полдня.
Мораль общего вида: **находка, добытая на живом железе и записанная только в журнал, для
пользователя не существует.** Проверять надо не «зафиксировано ли», а «попадает ли в пакет».

## Что сделано
- `tools/install_win.sh` — шаг «версия Windows»: ищет префикс (`<библиотека>/steamapps/
  compatdata/20900/pfx` + три стандартных места), правит `user.reg`, бэкапит его в
  `<игра>/WitcherPadBridge/backup/user.reg`. Идемпотентно: второй прогон говорит «уже выставлена».
  Если игра запущена — отказывается работать с объяснением (wineserver перезапишет `user.reg`
  при выходе, и правка пропадёт молча). Префикса нет → не Proton, шаг пропускается с подсказкой
  про режим совместимости на обычной Windows.
- `tools/uninstall_win.sh` — снимает ровно свой блок `AppDefaults\witcher.exe`.
- README: отдельный подраздел с объяснением, ручной формой правки, вариантом через
  `protontricks 20900 winecfg` и способом проверить (`reported ver: 5.1 build 2600` в логе моста).
- 🔴 `IGNORECASE` в awk — расширение gawk. На mawk (а он на части систем по умолчанию) проверка
  «уже выставлено» молча стала бы ложной и блок дописывался бы каждый раз. Везде `tolower()`.
- `#time=` печатается сразу за заголовком ключа, как это делает сам wine.

Проверено не глазами, а прогонами: на настоящем `user.reg` с Ally (1618 строк) три случая —
блок есть / блока нет / блок есть, но версия другая; затем полный круг установка → повторная
установка → удаление из СОБРАННОГО пакета на фальшивой библиотеке Steam. Реестр после удаления
возвращается к исходному (разница — одна пустая строка, wine их игнорирует), чужие
`"Version"="win10"` не тронуты.

## Порог бега 0.70 → 0.85 (по живому отзыву)
«Диапазон, когда он ходит, а потом бежит, маловат» — ходьба занимала 0.20–0.70 хода стика.
Стало 0.20–0.85: шагом Геральт идёт почти на всём ходу, бежит у самого упора.
🔴 Попутно вскрылось, почему все замеры походки дрались с мостом: `RunThreshold` я правил в
`gamepad.ini`, а его перекрывает `wxp_config.ini` от внутриигровой вкладки, где лежало 0.7.
**Второй слой конфига сильнее — правку для замера надо класть именно в него.**
Дефолт выровнен во всех четырёх местах сразу: `mod/gamepad.ini`, оба моста, вкладка в игре.

## Ещё две неправды в README, вычищенные заодно
- «Разрыв между шагом и бегом задан анимациями, а не таблицей» — неверно, это `moverates.2da`
  (поправка от 25 августа была внесена в журнал, но не в README).
- «Из трёх скриптов два новые» — их давно семь.

## Итог
`v0.6` собран, проверен смоук-прогоном из пакета и опубликован. `moverates.2da` в релиз НЕ
входит: подбор `walk` не закончен, зависимость резко нелинейная.
