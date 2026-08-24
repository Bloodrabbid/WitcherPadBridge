# WitcherPadBridge

Полноценное управление геймпадом для **The Witcher: Enhanced Edition** — аналоговое движение и
камера, навигация по меню и панелям с пада, бой. Ничего не нужно запускать отдельно: поставил и
играешь. Работает на macOS (порт eON) и на Windows/Proton (Steam Deck, ROG Ally, Bazzite).

*(English below)*

---

## Что умеет

| | |
|---|---|
| Левый стик | движение; **слабое отклонение — шаг, сильное — бег** |
| Правый стик | камера |
| A | атака / подтвердить |
| B | отмена / закрыть панель |
| X | активный знак |
| Y | инвентарь (в панели — контекстное действие) |
| LB | стальной меч; **удержать + правый стик — колесо знаков** (в панели — вкладка назад) |
| RB | серебряный меч (в панели — вкладка вперёд) |
| LT / RT | быстрый / силовой стиль (в панели — предыдущая / следующая секция) |
| L3 / R3 | групповой стиль / переворот камеры |
| Крестовина | дневник / карта / герой / алхимия (в панели — перемещение фокуса) |
| Тачпад | **активная пауза** (на паде без тачпада — Start; см. `PauseButton`) |
| Вибрация | тряска камеры, удары, ритм серии, знаки, медальон (`Rumble`) |
| Start | меню |
| Back | быстрое сохранение |

В панелях и меню пад не «возит курсор»: фокус переходит по контролам, как в современных играх.

**Знаки.** Зажмите LB и отклоните правый стик — знак под выбранным сектором становится активным,
X его кастует. Секторы по часовой стрелке от «вверх»: Аард, Квен, Ирден, Игни, Аксий. Если
отпустить LB, не трогая стик, это просто достаёт стальной меч.

## Установка

Готовый архив — на [странице релизов](../../releases). Распакуйте и запустите установщик своей
платформы; папку игры он находит сам через библиотеки Steam, а если не нашёл — передайте путь
аргументом.

| Платформа | Установка | Удаление |
|---|---|---|
| macOS | `tools/install_mac.sh` | `tools/uninstall_mac.sh` |
| Steam Deck / Bazzite / ROG Ally (Proton) | `tools/install_win.sh` | `tools/uninstall_win.sh` |
| Windows | двойной клик по `tools/install_windows.bat` | `tools/uninstall_windows.bat` |

Всё, что установщик трогает, сначала копируется в `<игра>/WitcherPadBridge/backup`.

### macOS — что именно делает установщик

Бэкап оригинального исполняемого файла, мост внутрь `The Witcher.app`, запись моста в
load-командах бинаря и переподпись бандла. После этого игра запускается обычным способом — из
Steam или по иконке. Инжектор и переменные окружения не нужны.

**Важно.** Steam «Проверить целостность файлов игры» откатывает и мост, и Lua-слой — после
проверки установку надо повторить. Подпись бандла становится ad-hoc: это нужно, чтобы система
разрешила загрузить неподписанную Apple библиотеку.

### Windows / Proton — что именно делает установщик

1. Бэкап штатного `<игра>/System/Scripts/debug.luc` — мод его заменяет.
2. `LightFX.dll` → `<игра>/System/lightfx/wxp/LightFX.dll`
3. `mod/scripts/*.luc` → `<игра>/System/Scripts/`
4. `mod/gamepad.ini` → `<игра>/gamepad.ini`

Игра сама пытается загрузить `LightFX.dll` при каждом старте, поэтому ни инжектора, ни
изменения бинаря здесь не нужно. Те же четыре шага легко сделать руками, если установщик
почему-то не подошёл.

Из трёх скриптов два новые (`wxp_gamepad.luc`, `wxp_ui.luc`), а `debug.luc` — штатный файл игры
с одной добавленной строкой: это единственный скрипт, который движок грузит безусловно, поэтому
он и служит точкой входа мода. Удаление = вернуть сохранённую копию и убрать остальные файлы.

В Steam **выключите Steam Input** для этой игры (Свойства → Контроллер → «Отключить Steam Input»)
или переведите его в passthrough: мод читает пад напрямую через XInput, а Steam Input перехватил
бы его и превратил в клавиатуру.

## Настройки

`gamepad.ini` (macOS: `~/Library/Application Support/com.cdprojektred.TheWitcher/gamepad.ini`,
Windows: в корне игры). Файл перечитывается на лету — менять можно не выходя из игры.

```ini
Enabled          = 1
DeadzoneLeft     = 0.20   ; мёртвая зона стиков, 0..1
DeadzoneRight    = 0.16
SensitivityX     = 1400   ; скорость камеры, пикселей в секунду
SensitivityY     = 900
CameraCurve      = 1.7    ; 1.0 — линейно, больше — точнее у центра
InvertY          = 0
MenuSensitivity  = 700    ; скорость курсора в главном меню

AimAssist        = 1      ; 0 выкл · 1 при атаке · 2 по кнопке
AimButton        = r3     ; кнопка для режима 2: r3 l3 lb rb lt rt
AimSpeed         = 2200   ; как быстро доворачивается камера, px/с

PauseButton      = touchpad  ; активная пауза: touchpad menu back l3 r3 lt rt none

RunThreshold     = 0.70   ; слабее — шаг, сильнее — бег; 0 = всегда бег
Rumble           = 1      ; вибрация
RumbleStrength   = 100    ; сила в процентах: 0 — тишина, 150 — сильнее
LogLevel         = 1      ; 0 тишина · 1 обычный лог · 2 подробный
```

Те же настройки есть **внутри игры**: Настройки → Игра, внизу списка блок «Геймпад».

### Автонаведение

Удар в этой игре достаётся тому, кто под прицелом, а прицел — центр экрана, поэтому «навести»
здесь означает «довернуть камеру». Мост доворачивает её только пока его просят и пока правый
стик не трогают: игрок всегда главнее.

* `AimAssist = 1` — доворот, пока зажата кнопка удара. Так и было раньше.
* `AimAssist = 2` — доворот **только пока держишь `AimButton`** (по умолчанию R3). Ничего не
  двигается, пока вы сами этого не попросите. В этом режиме кнопка теряет своё обычное
  действие (R3 — переворот камеры).
* `AimAssist = 0` — камеру не трогает вообще.

Если камера мотается из стороны в сторону — уменьшите `AimSpeed` или переключитесь на режим 2.

### Активная пауза

Пробел останавливает мир, не закрывая экран, — в бою это половина тактики: можно спокойно
посмотреть, кто где стоит, и сменить стиль. На паде она висит на **клике по тачпаду**
DualSense/DualShock: это единственная свободная кнопка посередине.

На геймпаде без тачпада (Xbox и совместимые) мост сам переключается на **Menu** — Esc никуда
не денется, он есть на B. Другую кнопку можно выбрать через `PauseButton`: `menu`, `back`,
`l3`, `r3`, `lt`, `rt` или `none`, если пауза на паде не нужна. Выбранная кнопка теряет своё
обычное действие, поэтому имейте в виду, чем жертвуете: L3 — групповой стиль, R3 — переворот
камеры (и кнопка автонаведения в режиме 2), LT/RT — быстрый и силовой стиль.

### Шаг и бег

У игры нет клавиши «идти»: `actions.2da` знает только вперёд/назад/вбок, а `startup.lua`
принудительно включает вечный бег — поэтому Геральт носится даже по комнате. Мод возвращает
вторую скорость и вешает её на стик: слабое отклонение — шаг, сильное — бег. Замерено на живом
персонаже: бег примерно вчетверо быстрее шага.

Двумя скоростями всё и ограничивается: сделать их плавно-переменными, как в новых играх, нельзя.
Рантайм-сеттера скорости движок в Lua не отдаёт (есть только «всегда бежать» вкл/выкл), а
локомоторных анимаций ровно две, без смешивания, — промежуточный темп означал бы едущие по земле
ноги. Разрыв между шагом и бегом тоже фиксирован: он задан анимациями, а не таблицей.

Порог — `RunThreshold`, доля отклонения стика (0.70 = семь десятых хода). `0` возвращает старое
поведение «всегда бег». В игре: Настройки → Игра → «Геймпад: бег при отклонении, %».

### Вибрация

Своей вибрации у игры нет вообще: The Witcher 2007 года про геймпады не знал, и в движке нет ни
одного вызова на этот счёт. Зато оболочка eON на macOS уже умеет Core Haptics — дорога есть,
по ней просто никто не ездил. Мод по ней и едет: слушает события движка и сам крутит моторы
(Core Haptics на macOS, XInput на Windows/Proton).

Что чувствуется: тряска камеры (движок сам говорит, насколько сильная), свой удар по врагу,
полученный урон — тем сильнее, чем больше потеряно здоровья, ритм серии ударов (короткий тик
ровно в тот момент, когда игра ждёт следующего нажатия), знаки, дрожь медальона рядом с магией,
новый уровень и отравление.

Выключается `Rumble = 0` или в игре: Настройки → Игра → «Геймпад: вибрация». Сила —
`RumbleStrength` в процентах.

## Другие моды: с чем уживаемся

Разложено по тому, что говорит сама игра (`System/restype.ini` и `System/witcher.ini`), а не по
советам с форумов — там пути называют по памяти и часто по-разному.

| Что за мод | Куда ставится | Мешает нам? |
|---|---|---|
| Текстуры, модели, звуки (HD-паки, ретекстуры) | `Data/…` (`Textures`, `Meshes`; в инструкциях часто пишут `Data/Override`) | **Нет.** Разные файлы, разные каталоги |
| Таблицы `.2da` (баланс, скорости, предметы) | `Data/2DA/` — так задано в `restype.ini`; игра и сама кладёт пару штук россыпью в `Data/` | **Нет.** Своих таблиц мод не ставит |
| Скриптовые моды (например Full Combat Rebalance) | `System/Scripts/*.luc` | **Возможно.** См. ниже |

**Почему со скриптами сложнее.** У скомпилированных скриптов нет каталога перекрытий вообще:
в `restype.ini` у типа `LUC` нет ни одного `Path`, а алиасы `SCRIPTS`/`SCRIPTS2` оба указывают в
`System/Scripts`. Значит любой скриптовый мод обязан переписывать файлы прямо там — как и мы.

Мы меняем **ровно один** штатный скрипт — `debug.luc`, и добавляем в него одну строку. Конфликт
возможен только если другой мод меняет тот же файл. Порядок установки: **сначала другой мод,
потом наш** — тогда наша строка ляжет поверх и точка входа сохранится. Если после этого что-то
из другого мода отвалилось, значит он тоже правил `debug.luc`; напишите, разберёмся.

Штатный `debug.luc` мы сохраняем в `<игра>/WitcherPadBridge/backup` до всех правок, так что
откатить можно всегда.

**На macOS текстурные моды не проверялись.** Порт eON транслирует x86-код и DirectX на лету;
крупные паки туда, скорее всего, встанут, но ручаться не за что — если попробуете, расскажите.

## Steam и проверка целостности

Мод состоит из добавленных файлов и **одного изменённого штатного** —
`System/Scripts/debug.luc`. Это единственный скрипт, который движок грузит безусловно, ещё до
создания интерфейса, поэтому он и служит точкой входа. На macOS изменяется ещё и исполняемый
файл игры (в него дописывается ссылка на библиотеку мода) и подпись бандла.

Steam → Свойства → Установленные файлы → **«Проверить целостность файлов игры»** возвращает
и `debug.luc`, и исполняемый файл в исходное состояние — мод после этого молчит. Это не поломка:
просто **запустите установщик заново**, всё вернётся. Добавленные файлы проверка обычно не трогает.

## Если что-то не так

Сначала соберите отчёт — он собирает логи, настройки и состояние установки в одну папку:

| Платформа | Команда |
|---|---|
| macOS, Steam Deck / Bazzite / ROG Ally (Proton) | `tools/diagnose.sh` |
| Windows | двойной клик по `tools\diagnose.bat` |

Скрипт ничего никуда не отправляет: он кладёт папку `wxp-diag-<дата>` и архив рядом с собой и
печатает путь. Загляните в `report.txt` перед тем, как отправлять — там пути с вашим именем
пользователя. Сохранения и прочее личное он не трогает.

Где что лежит, если хочется посмотреть самому:

* Лог моста: macOS `/tmp/wxp_bridge.log`, Windows/Proton `<игра>/System/wxp_bridge.log`.
  Начинается баннером с версией и датой, дальше — строки со временем. Раз в 10 секунд пишется
  строка `alive:` — по ней видно, видит ли мост пад, в каком он режиме и жив ли Lua-слой.
* Лог Lua-слоя: `<игра>/System/wxp_gamepad.log` — то же самое со стороны игры.
* Отчёт установки: `<игра>/WitcherPadBridge/install.log` — что и куда положил установщик,
  с размерами файлов (этим ловится «установил, но скопировалась старая сборка»).
* Оба лога ротируются на 512 КБ: предыдущий остаётся рядом с суффиксом `.1`.
* `LogLevel = 2` в `gamepad.ini` включает подробный режим (каждое нажатие и клик), `0` — тишина.

Что проверить в первую очередь:

* Пад не виден — подключите его до запуска игры и **выключите Steam Input** для этой игры.
  В логе это выглядит как `pad=NO` в строке `alive:`.
* Меню не реагирует на пад, а камера работает — не установился Lua-слой. В логе моста строка
  `lua layer ... NOT PRESENT`, в `report.txt` — `MISSING ... wxp_gamepad.luc`.
* Всё установилось, но мод молчит — Steam-проверка целостности вернула штатный `debug.luc`
  (`debug.luc calls wxp_gamepad: NO` в отчёте). Запустите установщик ещё раз.
* `System writable: NO` в отчёте — игра лежит в папке, куда нет доступа на запись; каналы
  между мостом и Lua живут там, без записи не заработает ничего.

---

# WitcherPadBridge (English)

Native-feeling gamepad support for **The Witcher: Enhanced Edition**: analogue movement and
camera, pad-driven menus and panels, combat. Nothing extra to launch — install it and play.
Runs on macOS (the eON port) and on Windows/Proton (Steam Deck, ROG Ally, Bazzite).

Ready-made archives are on the [releases page](../../releases); the installers find the game
through Steam's own library list, or take the path as an argument.

**Install (macOS):** run `tools/install_mac.sh`. It backs up the original executable, puts the
bridge inside `The Witcher.app`, names it in the executable's load commands and re-signs the
bundle, so the game launches normally afterwards. Remove with `tools/uninstall_mac.sh`.

**Install (Windows/Proton):** run `tools/install_win.sh` on Linux (Steam Deck, Bazzite, ROG Ally)
or double-click `tools/install_windows.bat` on Windows. It backs up the stock `debug.luc`, drops
`LightFX.dll` into `<game>/System/lightfx/wxp/`, the compiled scripts into `<game>/System/Scripts/`
and a default `gamepad.ini` into the game root. No injector and no patched executable: the game
tries to load that DLL on every start by itself. Turn **Steam Input off** for the game — the mod
reads the pad through XInput itself.

**Settings:** `gamepad.ini`, re-read live, and the same values in-game under Options -> Gameplay.
Deadzones, camera speed in pixels per second, response curve, Y inversion, menu cursor speed.

**Aim assist:** a blow in this game lands on whoever is under the reticle, and the reticle is
pinned to the centre of the screen -- so aiming here means turning the camera, and that is what
the assist does, only while asked and only while the right stick is left alone. `AimAssist = 1`
turns the view while the attack button is held (the old behaviour); `AimAssist = 2` turns it
only while `AimButton` is held (R3 by default, which gives up its camera flip in that mode);
`AimAssist = 0` never touches the camera. If the view swings about, lower `AimSpeed` or switch
to mode 2.

**Active pause:** Space stops the world without covering the screen, which in a fight is half the
tactics -- look at where everyone is standing, change combat style, carry on. On the pad it is the
**touchpad click** of a DualSense/DualShock, the one free button in the middle. A pad without a
touchpad falls back to **Menu** by itself (Escape is on B anyway). `PauseButton` picks another:
`menu`, `back`, `l3`, `r3`, `lt`, `rt`, or `none`. Whichever you pick gives up its usual job --
L3 is the group style, R3 the camera flip (and the aim button in mode 2), LT/RT the fast and
strong styles.

**Walk and run:** the game has no walk key -- actions.2da knows only forward, back and strafe --
and startup.lua turns always-run on, so Geralt sprints across a room. The mod gives the second
speed back and puts it on the stick: push a little to walk, push far to run. Measured on the live
character, running is about four times walking. `RunThreshold` is the fraction of stick travel
where it switches (0.70 by default); `0` restores always-run. Two speeds is all there is: the
engine exposes no runtime speed setter to Lua, only always-run on or off, and there are exactly
two locomotion animations with no blending between them -- an in-between pace would slide Geralt's
feet along the ground. The gap between the two is set by those animations, not by a table.

**Rumble:** the game has none of its own -- a 2007 PC title with not one vibration call in it --
but eON already links Core Haptics to emulate DirectInput force feedback, so the road existed and
nobody drove it. The mod listens to the engine's own events and drives the motors itself (Core
Haptics on macOS, XInput on Windows/Proton): camera shakes scaled by how hard the engine says
they are, blows landed, damage taken scaled by how much was lost, a short tick on the beat of the
attack chain, signs, the medallion trembling near magic, level-ups. `Rumble = 0` turns it off, or
Options -> Gameplay in game; `RumbleStrength` is a percentage.

**Other mods:** taken from what the game says about itself (`System/restype.ini`,
`System/witcher.ini`) rather than from forum instructions, which name these paths from memory and
disagree. Textures, meshes and sounds live under `Data/` (`Textures`, `Meshes`; instructions
usually say `Data/Override`) and cannot collide with us. Tables go to `Data/2DA/` -- the path
restype.ini gives -- and cannot collide with us either, since we ship no tables of our own.
Script mods are the awkward case: compiled scripts have no override directory
at all -- the `LUC` type in restype.ini has no `Path` entry and both `SCRIPTS` aliases point at
`System/Scripts` -- so every script mod has to overwrite files in place, as we do. We change
exactly one stock script, `debug.luc`, by one line, so install the other mod first and ours
second. The stock `debug.luc` is backed up before anything is touched. Texture packs on macOS are
untested: eON translates x86 and DirectX on the fly, and large packs probably survive that, but
nobody has checked.

**Caveat:** the mod is all added files plus **one modified stock file**, `System/Scripts/debug.luc`
— the only script the engine loads unconditionally, which is why it is the entry point. On macOS
the game executable and the bundle signature are modified too. Steam's "Verify integrity of game
files" reverts those, and the mod goes quiet; just run the installer again.

**When something is wrong:** run `tools/diagnose.sh` (macOS, Steam Deck, Bazzite, ROG Ally) or
double-click `tools\diagnose.bat` (Windows). It collects the logs, the settings and the state of
the install into one folder and a zip next to itself, and uploads nothing — read `report.txt`
before sending it on, the paths in it contain your user name.

The logs themselves: `/tmp/wxp_bridge.log` on macOS, `<game>/System/wxp_bridge.log` on
Windows/Proton, `<game>/System/wxp_gamepad.log` for the script layer, and
`<game>/WitcherPadBridge/install.log` for what the installer did. Each starts with a banner
naming the build, every line is timestamped, and an `alive:` line every ten seconds says whether
the pad is seen, which mode the bridge thinks it is in and whether the script layer is ticking.
Both logs roll over at 512 KB, keeping the previous one as `.1`. `LogLevel = 2` in `gamepad.ini`
adds a line per keypress and click; `0` silences the log entirely.
