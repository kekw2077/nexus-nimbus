import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/theme.dart';
import '../ui/tokens.dart';
import 'updater.dart';

/// Оформление между запусками. Ничего секретного здесь нет — обычный
/// shared_preferences, в отличие от пароля приложения.
class Prefs {
  Prefs(this._p);
  final SharedPreferences _p;

  static Future<Prefs> open() async => Prefs(await SharedPreferences.getInstance());

  static const _theme = 'ui.theme';
  static const _accent = 'ui.accent';
  static const _glass = 'ui.glass';
  static const _background = 'ui.background';
  static const _anim = 'ui.anim';
  static const _section = 'ui.section';
  static const _updateChannel = 'update.channel';
  static const _updateServer = 'update.server';
  static const _updateAuto = 'update.auto';
  static const _vaultRoot = 'vault.root';
  static const _autoPush = 'edit.autopush';
  static const _syncEnabled = 'sync.enabled';
  static const _syncInterval = 'sync.interval';
  static const _syncEverything = 'sync.everything';
  static const _tray = 'tray.enabled';
  static const _closeToTray = 'tray.onclose';
  static const _hotkey = 'hotkey.enabled';
  static const _googleId = 'google.clientId';
  static const _googleSecret = 'google.clientSecret';
  static const _yandexId = 'yandex.clientId';
  static const _yandexSecret = 'yandex.clientSecret';
  static const _winW = 'window.width';
  static const _winH = 'window.height';
  static const _winX = 'window.x';
  static const _winY = 'window.y';
  static const _winMax = 'window.maximized';

  NxThemeData readTheme() => NxThemeData(
        brightness: _p.getString(_theme) == 'light' ? Brightness.light : Brightness.dark,
        accent: NxAccent.all.firstWhere(
          (a) => a.id == _p.getString(_accent),
          orElse: () => NxAccent.aurora,
        ),
        glass: _enum(NxGlass.values, _p.getString(_glass), NxGlass.glass),
        background: _enum(NxBackground.values, _p.getString(_background), NxBackground.aurora),
        anim: _enum(NxAnim.values, _p.getString(_anim), NxAnim.breathe),
      );

  Future<void> writeTheme(NxThemeData t) async {
    await _p.setString(_theme, t.brightness == Brightness.light ? 'light' : 'dark');
    await _p.setString(_accent, t.accent.id);
    await _p.setString(_glass, t.glass.name);
    await _p.setString(_background, t.background.name);
    await _p.setString(_anim, t.anim.name);
  }

  String readSection() => _p.getString(_section) ?? 'files';

  Future<void> writeSection(String id) => _p.setString(_section, id);

  // ---------------------------------------------------------- обновления

  UpdateChannel readUpdateChannel() =>
      _enum(UpdateChannel.values, _p.getString(_updateChannel), UpdateChannel.github);

  Future<void> writeUpdateChannel(UpdateChannel c) =>
      _p.setString(_updateChannel, c.name);

  /// Базовый адрес своего сервера обновлений. Пусто — канал GitHub.
  String readUpdateServer() => _p.getString(_updateServer) ?? '';

  Future<void> writeUpdateServer(String url) => _p.setString(_updateServer, url);

  bool readAutoCheck() => _p.getBool(_updateAuto) ?? true;

  Future<void> writeAutoCheck(bool value) => _p.setBool(_updateAuto, value);

  // ------------------------------------------------------------ хранилище

  /// Куда складывать скачанные файлы этой учётной записи.
  /// Пусто — папка ещё не выбиралась.
  ///
  /// Папка своя у каждой записи: у разных облаков по одному и тому же пути
  /// лежат разные файлы. Прежняя общая настройка достаётся первой записи,
  /// иначе после обновления её файлы оказались бы не там, где их ищут.
  String readVaultRoot(String accountSlug) =>
      _p.getString('$_vaultRoot.$accountSlug') ?? _p.getString(_vaultRoot) ?? '';

  Future<void> writeVaultRoot(String accountSlug, String path) =>
      _p.setString('$_vaultRoot.$accountSlug', path);

  /// Отправлять ли правки открытого файла сразу, как только он сохранён.
  /// По умолчанию да — ради этого «правка на месте» и затевалась; выключенный
  /// режим вместо отправки показывает предложение.
  bool readAutoPushEdits() => _p.getBool(_autoPush) ?? true;

  Future<void> writeAutoPushEdits(bool value) => _p.setBool(_autoPush, value);

  // ------------------------------------------------------- синхронизация

  bool readSyncEnabled() => _p.getBool(_syncEnabled) ?? true;

  Future<void> writeSyncEnabled(bool value) => _p.setBool(_syncEnabled, value);

  /// Как часто обходить закреплённые папки, в минутах.
  int readSyncInterval() => _p.getInt(_syncInterval) ?? 5;

  Future<void> writeSyncInterval(int minutes) => _p.setInt(_syncInterval, minutes);

  /// Синхронизировать всё дерево, а не только закреплённые папки.
  /// По умолчанию нет: это может утянуть на диск всё облако целиком.
  bool readSyncEverything() => _p.getBool(_syncEverything) ?? false;

  Future<void> writeSyncEverything(bool value) => _p.setBool(_syncEverything, value);

  // ----------------------------------------------- трей и горячая клавиша

  /// Всё по умолчанию выключено: программа, самовольно занявшая трей,
  /// автозапуск и системное сочетание клавиш, — дурной тон.
  bool readTrayEnabled() => _p.getBool(_tray) ?? false;

  Future<void> writeTrayEnabled(bool value) => _p.setBool(_tray, value);

  bool readCloseToTray() => _p.getBool(_closeToTray) ?? false;

  Future<void> writeCloseToTray(bool value) => _p.setBool(_closeToTray, value);

  bool readHotkeyEnabled() => _p.getBool(_hotkey) ?? false;

  Future<void> writeHotkeyEnabled(bool value) => _p.setBool(_hotkey, value);

  // ------------------------------------------------------- клиент Google

  /// Учётные данные приложения в Google. Регистрируются один раз человеком
  /// в Cloud Console: из кода это сделать нельзя. Секрет здесь секретный
  /// только по названию — для настольных приложений Google прямо пишет,
  /// что скрыть его невозможно, доступ всё равно подтверждается в браузере.
  ({String id, String secret}) readGoogleClient() => (
        id: _p.getString(_googleId) ?? '',
        secret: _p.getString(_googleSecret) ?? '',
      );

  Future<void> writeGoogleClient(String id, String secret) async {
    await _p.setString(_googleId, id.trim());
    await _p.setString(_googleSecret, secret.trim());
  }

  /// Учётные данные приложения в Яндексе.
  ({String id, String secret}) readYandexClient() => (
        id: _p.getString(_yandexId) ?? '',
        secret: _p.getString(_yandexSecret) ?? '',
      );

  Future<void> writeYandexClient(String id, String secret) async {
    await _p.setString(_yandexId, id.trim());
    await _p.setString(_yandexSecret, secret.trim());
  }

  // ----------------------------------------------------------------- окно

  Size? readWindowSize() {
    final w = _p.getDouble(_winW);
    final h = _p.getDouble(_winH);
    return (w == null || h == null) ? null : Size(w, h);
  }

  Future<void> writeWindowSize(Size size) async {
    await _p.setDouble(_winW, size.width);
    await _p.setDouble(_winH, size.height);
  }

  Offset? readWindowPosition() {
    final x = _p.getDouble(_winX);
    final y = _p.getDouble(_winY);
    return (x == null || y == null) ? null : Offset(x, y);
  }

  Future<void> writeWindowPosition(Offset at) async {
    await _p.setDouble(_winX, at.dx);
    await _p.setDouble(_winY, at.dy);
  }

  bool readWindowMaximized() => _p.getBool(_winMax) ?? false;

  Future<void> writeWindowMaximized(bool value) => _p.setBool(_winMax, value);

  static T _enum<T extends Enum>(List<T> values, String? name, T fallback) {
    for (final v in values) {
      if (v.name == name) return v;
    }
    return fallback;
  }
}
