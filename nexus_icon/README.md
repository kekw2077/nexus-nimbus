# Nexus Nimbus — набор иконок

## Что внутри

```
app/
  nexus_nimbus.ico        ← иконка ярлыка/exe (16,20,24,32,40,48,64,96,128,256)
  app_icon.png            ← 1024×1024, источник для flutter_launcher_icons
  nexus_nimbus_256.png
  png/icon_16 … icon_1024 ← отдельные размеры
tray/
  ico/tray_<theme>_<state>.ico    ← 16,20,24,32,48 в одном файле
  png/tray_<theme>_<state>_<size>.png
source/
  nexus_nimbus.svg        ← мастер для 64 px и выше (объёмная заливка + тень)
  nexus_nimbus_small.svg  ← мастер для 48 px и ниже (плоская заливка, без тени)
  _alt_with_mark.svg      ← вариант со знаком связи, в наборе не используется
  tray_white.svg / tray_black.svg
  build_icons.py          ← скрипт пересборки всего набора
preview.png
```

theme: `white` — для тёмной панели задач, `black` — для светлой.
state: `idle`, `sync`, `error`, `offline`.

## Логика размеров

Иконка построена на чистом облачном силуэте. На 64 px и выше облако идёт с
объёмной заливкой и мягкой тенью, на 48 и ниже — плоская белая заливка без тени:
тень на мелких размерах превращается в грязный ореол и съедает контраст.
Геометрия силуэта одинаковая, так что переход незаметен.

## Куда класть

**Flutter Desktop (Windows)**
- `windows/runner/resources/app_icon.ico` ← `app/nexus_nimbus.ico`
- иконка трея для `tray_manager`: `tray/ico/tray_white_idle.ico`
  (Windows требует именно `.ico`; для Linux/macOS отдавать PNG из `tray/png/`)

**flutter_launcher_icons**
```yaml
flutter_launcher_icons:
  image_path: "assets/icon/app_icon.png"
  windows:
    generate: true
    icon_size: 256
```

**Ярлык вручную**: свойства ярлыка → «Сменить значок» → указать `nexus_nimbus.ico`.
Если Windows показывает старую иконку — сбросить кэш:
`ie4uinit.exe -show` или удалить `%LocalAppData%\IconCache.db` и перезапустить explorer.

## Смена темы трея

Windows не сообщает тему панели напрямую — читается из реестра:
`HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize\SystemUsesLightTheme`
(1 → светлая панель → `tray_black_*`, 0 → тёмная → `tray_white_*`).

## Пересборка

```bash
pip install cairosvg pillow
python source/build_icons.py
```
Палитра, геометрия облака и размеры бейджа состояния задаются константами в начале скрипта.
