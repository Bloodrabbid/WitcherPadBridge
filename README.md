# WitcherPadBridge

Полноценное управление геймпадом для **The Witcher: Enhanced Edition** — аналоговое движение и
камера, навигация по меню и панелям с пада, бой. Ничего не нужно запускать отдельно: поставил и
играешь. Работает на macOS (порт eON) и на Windows/Proton (Steam Deck, ROG Ally, Bazzite).

*(English below)*

---

## Что умеет

| | |
|---|---|
| Левый стик | движение |
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
| Start | меню |
| Back | быстрое сохранение |

В панелях и меню пад не «возит курсор»: фокус переходит по контролам, как в современных играх.

**Знаки.** Зажмите LB и отклоните правый стик — знак под выбранным сектором становится активным,
X его кастует. Секторы по часовой стрелке от «вверх»: Аард, Квен, Ирден, Игни, Аксий. Если
отпустить LB, не трогая стик, это просто достаёт стальной меч.

## Установка — macOS

```sh
tools/install_mac.sh
```

Скрипт делает бэкап оригинального исполняемого файла, кладёт мост внутрь `The Witcher.app`,
прописывает его в load-командах бинаря и переподписывает бандл. После этого игра запускается
обычным способом — из Steam или по иконке.

Удаление: `tools/uninstall_mac.sh`.

**Важно.** Steam «Проверить целостность файлов игры» откатывает и мост, и Lua-слой — после
проверки установку надо повторить. Подпись бандла становится ad-hoc: это нужно, чтобы система
разрешила загрузить неподписанную Apple библиотеку.

## Установка — Windows / Proton (Steam Deck, ROG Ally, Bazzite)

1. Сохраните копию `<игра>/System/Scripts/debug.luc` — мод её заменяет.
2. `bridge/windows/LightFX.dll` → `<игра>/System/lightfx/wxp/LightFX.dll`
3. `mod/scripts/*.luc` → `<игра>/System/Scripts/`
4. `mod/gamepad.ini` → `<игра>/gamepad.ini`

Игра сама пытается загрузить `LightFX.dll` при каждом старте, поэтому ни инжектора, ни
изменения бинаря здесь не нужно.

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
```

## Steam и проверка целостности

Мод состоит из добавленных файлов и **одного изменённого штатного** —
`System/Scripts/debug.luc`. Это единственный скрипт, который движок грузит безусловно, ещё до
создания интерфейса, поэтому он и служит точкой входа. На macOS изменяется ещё и исполняемый
файл игры (в него дописывается ссылка на библиотеку мода) и подпись бандла.

Steam → Свойства → Установленные файлы → **«Проверить целостность файлов игры»** возвращает
и `debug.luc`, и исполняемый файл в исходное состояние — мод после этого молчит. Это не поломка:
просто **запустите установщик заново**, всё вернётся. Добавленные файлы проверка обычно не трогает.

## Если что-то не так

* Лог моста: macOS `/tmp/wxp_bridge.log`, Windows `<игра>/System/wxp_bridge.log`.
* Лог Lua-слоя: `<игра>/System/wxp_gamepad.log`.
* Пад не виден — проверьте, что он подключён до запуска игры, и что Steam Input выключен.
* После Steam-проверки целостности — переустановите мод.

---

# WitcherPadBridge (English)

Native-feeling gamepad support for **The Witcher: Enhanced Edition**: analogue movement and
camera, pad-driven menus and panels, combat. Nothing extra to launch — install it and play.
Runs on macOS (the eON port) and on Windows/Proton (Steam Deck, ROG Ally, Bazzite).

**Install (macOS):** run `tools/install_mac.sh`. It backs up the original executable, puts the
bridge inside `The Witcher.app`, names it in the executable's load commands and re-signs the
bundle, so the game launches normally afterwards. Remove with `tools/uninstall_mac.sh`.

**Install (Windows/Proton):** keep a copy of `<game>/System/Scripts/debug.luc` (the mod replaces
it — it is the one script the engine always loads, so it serves as the entry point), then copy
`bridge/windows/LightFX.dll` to `<game>/System/lightfx/wxp/LightFX.dll`, `mod/scripts/*.luc` to
`<game>/System/Scripts/`, and `mod/gamepad.ini` to `<game>/gamepad.ini`. Turn **Steam Input off**
for the game — the mod reads the pad through XInput itself.

**Settings:** `gamepad.ini`, re-read live. Deadzones, camera speed in pixels per second, response
curve, Y inversion, menu cursor speed.

**Caveat:** the mod is all added files plus **one modified stock file**, `System/Scripts/debug.luc`
— the only script the engine loads unconditionally, which is why it is the entry point. On macOS
the game executable and the bundle signature are modified too. Steam's "Verify integrity of game
files" reverts those, and the mod goes quiet; just run the installer again.
