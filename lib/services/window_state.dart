import 'dart:async';
import 'dart:ui';

import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'prefs.dart';

/// Запоминает размер, положение и развёрнутость окна между запусками.
///
/// Отдельным классом, а не парой строк в main: сохранять надо с задержкой
/// (при перетаскивании событие приходит на каждый кадр), а восстанавливать —
/// с проверкой, что окно не уедет на монитор, которого больше нет.
class WindowStateKeeper with WindowListener {
  WindowStateKeeper(this._prefs);

  final Prefs _prefs;
  Timer? _debounce;

  static const defaultSize = Size(1180, 760);
  static const minimumSize = Size(880, 560);

  /// Пауза перед записью. Изменение размера сыплет событиями каждый кадр;
  /// без задержки настройки переписывались бы сотни раз за одно перетаскивание.
  static const _settle = Duration(milliseconds: 700);

  Size get savedSize => _prefs.readWindowSize() ?? defaultSize;
  bool get savedMaximized => _prefs.readWindowMaximized();

  /// Положение из настроек, если оно попадает хоть на один подключённый
  /// монитор. Иначе null — и окно встанет по центру.
  Future<Offset?> validPosition() async {
    final saved = _prefs.readWindowPosition();
    if (saved == null) return null;
    try {
      final displays = await screenRetriever.getAllDisplays();
      final size = savedSize;
      for (final d in displays) {
        final origin = d.visiblePosition ?? Offset.zero;
        final area = (d.visibleSize ?? d.size);
        final screen = Rect.fromLTWH(origin.dx, origin.dy, area.width, area.height);
        final window = Rect.fromLTWH(saved.dx, saved.dy, size.width, size.height);
        // Достаточно, чтобы на экране осталась заметная часть окна: тогда
        // его можно ухватить за заголовок и перетащить.
        final overlap = screen.intersect(window);
        if (overlap.width > 120 && overlap.height > 60) return saved;
      }
    } catch (_) {
      // Список мониторов не прочитался — безопаснее поставить по центру.
      return null;
    }
    return null;
  }

  /// Ставит окно туда, где оно было в прошлый раз. Вызывается внутри
  /// waitUntilReadyToShow, до show — иначе окно мигнёт на старом месте.
  Future<void> restore() async {
    final position = await validPosition();
    if (position != null) {
      await windowManager.setPosition(position);
    } else {
      await windowManager.center();
    }
    if (savedMaximized) await windowManager.maximize();
  }

  /// Опрос геометрии вместо надежды на события.
  ///
  /// На Windows window_manager отдаёт onWindowResized не при всяком изменении
  /// размера, а onWindowClose приходит только при setPreventClose — то есть
  /// на обычном закрытии последний размер терялся. Опрос раз в две секунды
  /// стоит одного вызова через канал платформы и работает всегда.
  static const _poll = Duration(seconds: 2);

  Timer? _ticker;
  Rect? _lastSaved;

  void attach() {
    windowManager.addListener(this);
    _ticker = Timer.periodic(_poll, (_) => unawaited(_save()));
  }

  void detach() {
    _debounce?.cancel();
    _ticker?.cancel();
    windowManager.removeListener(this);
  }

  @override
  void onWindowResized() => _schedule();

  @override
  void onWindowMoved() => _schedule();

  @override
  void onWindowMaximize() => _schedule();

  @override
  void onWindowUnmaximize() => _schedule();

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(_settle, () => unawaited(_save()));
  }

  Future<void> _save() async {
    try {
      final maximized = await windowManager.isMaximized();
      await _prefs.writeWindowMaximized(maximized);
      // Размер развёрнутого окна запоминать нельзя: свернув его обратно,
      // пользователь получил бы окно во весь экран без рамки.
      if (maximized) return;
      if (await windowManager.isMinimized()) return;

      final bounds = await windowManager.getBounds();
      if (bounds.width < 200 || bounds.height < 150) return;
      if (_lastSaved == bounds) return;
      _lastSaved = bounds;
      await _prefs.writeWindowSize(bounds.size);
      await _prefs.writeWindowPosition(bounds.topLeft);
    } catch (_) {
      // Не смогли прочитать геометрию — не беда, останется прошлая запись.
    }
  }
}
