import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_state.dart';
import 'prefs.dart';

/// Значок в трее, автозапуск и глобальная горячая клавиша.
///
/// Всё трое живут вместе не случайно: это одна мысль — приложение должно
/// быть под рукой, не занимая панель задач. Значок держит его на виду,
/// автозапуск поднимает его сам, клавиша вызывает окно откуда угодно.
///
/// Каждое можно выключить по отдельности, и по умолчанию всё выключено:
/// программа, самовольно поселившаяся в автозапуске, — дурной тон.
class TrayService extends ChangeNotifier with TrayListener, WindowListener {
  TrayService(this._prefs, this._app);

  final Prefs _prefs;
  final AppState _app;

  static LaunchAtStartup get _startup => LaunchAtStartup.instance;

  /// Значок один и тот же, что у окна: в трее он должен читаться как то же
  /// самое приложение, а не как что-то ещё.
  static const _icon = 'assets/icon/app_icon.ico';

  /// Ctrl + Shift + N. Клавиша не настраивается: выбор сочетания — отдельная
  /// работа с записью нажатий и проверкой, что оно не занято системой.
  static final _hotKey = HotKey(
    key: PhysicalKeyboardKey.keyN,
    modifiers: [HotKeyModifier.control, HotKeyModifier.shift],
    scope: HotKeyScope.system,
  );

  bool _tray = false;
  bool _closeToTray = false;
  bool _startAtLogin = false;
  bool _hotkey = false;

  bool get tray => _tray;
  bool get closeToTray => _closeToTray;
  bool get startAtLogin => _startAtLogin;
  bool get hotkey => _hotkey;

  /// Подпись сочетания для настроек — чтобы текст и код не разъезжались.
  static const hotkeyLabel = 'Ctrl + Shift + N';

  Future<void> init() async {
    _tray = _prefs.readTrayEnabled();
    _closeToTray = _prefs.readCloseToTray();
    _hotkey = _prefs.readHotkeyEnabled();

    _startup.setup(
      appName: 'Nexus Nimbus',
      appPath: Platform.resolvedExecutable,
    );
    try {
      _startAtLogin = await _startup.isEnabled();
    } catch (_) {
      // Реестр может быть недоступен — считаем, что автозапуска нет.
      _startAtLogin = false;
    }

    windowManager.addListener(this);
    trayManager.addListener(this);

    // Чужие регистрации после перезапуска система за нами не убирает.
    await hotKeyManager.unregisterAll();

    if (_tray) await _showTray();
    await _applyCloseToTray();
    if (_hotkey) await _registerHotkey();
    notifyListeners();
  }

  // ------------------------------------------------------------ переключение

  Future<void> setTray(bool value) async {
    if (_tray == value) return;
    _tray = value;
    await _prefs.writeTrayEnabled(value);
    if (value) {
      await _showTray();
    } else {
      // Без значка сворачивать в трей некуда — окно стало бы недостижимым.
      if (_closeToTray) await setCloseToTray(false);
      await _hideTray();
    }
    notifyListeners();
  }

  Future<void> setCloseToTray(bool value) async {
    if (_closeToTray == value) return;
    _closeToTray = value;
    await _prefs.writeCloseToTray(value);
    await _applyCloseToTray();
    notifyListeners();
  }

  Future<void> setStartAtLogin(bool value) async {
    try {
      final ok = value ? await _startup.enable() : await _startup.disable();
      _startAtLogin = ok ? value : await _startup.isEnabled();
    } catch (_) {
      _startAtLogin = false;
    }
    notifyListeners();
  }

  Future<void> setHotkey(bool value) async {
    if (_hotkey == value) return;
    _hotkey = value;
    await _prefs.writeHotkeyEnabled(value);
    if (value) {
      await _registerHotkey();
    } else {
      await hotKeyManager.unregister(_hotKey);
    }
    notifyListeners();
  }

  // ------------------------------------------------------------------ окно

  Future<void> showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  /// Клавиша работает переключателем: окно поверх всего — спрятать,
  /// иначе — показать. Так одно сочетание делает обе половины дела.
  Future<void> toggleWindow() async {
    final visible = await windowManager.isVisible();
    final focused = await windowManager.isFocused();
    if (visible && focused) {
      _tray ? await windowManager.hide() : await windowManager.minimize();
      return;
    }
    await showWindow();
  }

  Future<void> quit() async {
    // Снимаем перехват закрытия, иначе выход из меню уткнётся в него же.
    await windowManager.setPreventClose(false);
    await _hideTray();
    await hotKeyManager.unregisterAll();
    await windowManager.destroy();
  }

  // ------------------------------------------------------------ внутреннее

  Future<void> _applyCloseToTray() async {
    // onWindowClose приходит только при setPreventClose — на этом и держится
    // весь перехват. Без сворачивания в трей перехват не нужен.
    await windowManager.setPreventClose(_closeToTray && _tray);
  }

  Future<void> _showTray() async {
    try {
      await trayManager.setIcon(_icon);
      await trayManager.setToolTip('Nexus Nimbus');
      await _refreshMenu();
    } catch (_) {
      // Трей может быть недоступен — приложение от этого не перестаёт работать.
      _tray = false;
    }
  }

  Future<void> _hideTray() async {
    try {
      await trayManager.destroy();
    } catch (_) {
      // Значка и так нет.
    }
  }

  Future<void> _refreshMenu() async {
    final hasSession = _app.session != null;
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(label: 'Открыть Nexus Nimbus', onClick: (_) => unawaited(showWindow())),
      MenuItem.separator(),
      MenuItem(
        label: 'Синхронизировать сейчас',
        disabled: !hasSession,
        onClick: (_) => unawaited(_syncNow()),
      ),
      MenuItem.separator(),
      MenuItem(label: 'Выход', onClick: (_) => unawaited(quit())),
    ]));
  }

  Future<void> _syncNow() async {
    final sync = _app.session?.sync;
    if (sync == null) return;
    await showWindow();
    await sync.syncNow();
  }

  Future<void> _registerHotkey() async {
    try {
      await hotKeyManager.register(_hotKey, keyDownHandler: (_) => unawaited(toggleWindow()));
    } catch (_) {
      // Сочетание мог занять кто-то другой — тогда просто живём без него.
      _hotkey = false;
      await _prefs.writeHotkeyEnabled(false);
    }
  }

  // ------------------------------------------------------------- слушатели

  @override
  void onTrayIconMouseDown() => unawaited(showWindow());

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onWindowClose() {
    // Сюда попадаем только при setPreventClose — то есть когда сворачивание
    // в трей включено. Значит, закрытие означает «убрать с глаз».
    unawaited(windowManager.hide());
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    unawaited(hotKeyManager.unregisterAll());
    super.dispose();
  }
}
