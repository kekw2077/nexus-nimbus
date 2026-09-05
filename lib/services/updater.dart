import 'dart:async';
import 'dart:io';

import 'package:auto_updater/auto_updater.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'prefs.dart';

/// Откуда приложение берёт обновления.
enum UpdateChannel {
  /// Зашитый адрес на GitHub. Работает всегда, ничего настраивать не нужно.
  github,

  /// Свой сервер: домашняя станция или любой другой HTTP-адрес, отдающий
  /// appcast.xml и установщики рядом с ним.
  station,
}

enum UpdateStatus { idle, checking, available, upToDate, downloaded, failed }

/// Обновления через WinSparkle (пакет auto_updater).
///
/// Приходят **полные установщики**, а не патчи кода: значит, в обновление
/// могут входить и нативные изменения — новый плагин, другая версия Flutter.
/// Каждый установщик подписан закрытым DSA-ключом, а открытый зашит в exe
/// через windows/runner/Runner.rc. Подпись не сойдётся — WinSparkle просто
/// откажется ставить, поэтому подменить обновление по дороге нельзя.
class UpdaterService extends ChangeNotifier with UpdaterListener {
  UpdaterService(this._prefs);

  final Prefs _prefs;

  /// Запасной и основной канал: файл в публичном репозитории.
  /// raw.githubusercontent отдаёт его без токена — WinSparkle авторизоваться
  /// не умеет, поэтому репозиторий обязан быть публичным.
  static const githubFeedUrl =
      'https://raw.githubusercontent.com/kekw2077/nexus-nimbus/main/dist/appcast.xml';

  /// Переменная окружения перебивает всё: ей проверяют канал перед выкладкой,
  /// не трогая настройки пользователя.
  static const envOverride = 'NIMBUS_UPDATE_FEED';

  /// Раз в шесть часов. Меньше часа WinSparkle всё равно не примет.
  static const checkInterval = Duration(hours: 6);

  UpdateStatus _status = UpdateStatus.idle;
  String? _message;
  String? _availableVersion;
  String _currentVersion = '—';
  bool _ready = false;

  UpdateStatus get status => _status;
  String? get message => _message;
  String? get availableVersion => _availableVersion;
  String get currentVersion => _currentVersion;

  UpdateChannel get channel => _prefs.readUpdateChannel();
  String get stationUrl => _prefs.readUpdateServer();
  bool get autoCheck => _prefs.readAutoCheck();

  /// Адрес, по которому пойдёт проверка прямо сейчас.
  String get effectiveFeedUrl {
    final env = Platform.environment[envOverride];
    if (env != null && env.trim().isNotEmpty) return env.trim();

    if (channel == UpdateChannel.station) {
      final base = stationUrl.trim();
      if (base.isNotEmpty) {
        return base.endsWith('.xml')
            ? base
            : '${base.replaceAll(RegExp(r'/+$'), '')}/appcast.xml';
      }
      // Канал выбран, адрес не введён — молча падаем на GitHub, иначе
      // приложение осталось бы вообще без обновлений.
    }
    return githubFeedUrl;
  }

  /// Канал задан снаружи и настройками не меняется.
  bool get overriddenByEnv {
    final env = Platform.environment[envOverride];
    return env != null && env.trim().isNotEmpty;
  }

  Future<void> init() async {
    if (!Platform.isWindows) return;
    try {
      _currentVersion = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}

    autoUpdater.addListener(this);
    await _applyFeed();
    _ready = true;
    notifyListeners();
  }

  Future<void> _applyFeed() async {
    try {
      await autoUpdater.setFeedURL(effectiveFeedUrl);
      await autoUpdater.setScheduledCheckInterval(
        autoCheck ? checkInterval.inSeconds : 0,
      );
    } catch (e) {
      _status = UpdateStatus.failed;
      _message = 'Не удалось настроить канал обновлений: $e';
      notifyListeners();
    }
  }

  /// Проверка по кнопке: WinSparkle сам покажет окно с описанием версии
  /// и спросит, ставить ли. В фоне (`inBackground`) окно появляется только
  /// если обновление действительно есть.
  Future<void> check({bool inBackground = false}) async {
    if (!_ready || !Platform.isWindows) return;
    _status = UpdateStatus.checking;
    _message = null;
    notifyListeners();
    try {
      await autoUpdater.checkForUpdates(inBackground: inBackground);
    } catch (e) {
      _status = UpdateStatus.failed;
      _message = e.toString();
      notifyListeners();
    }
  }

  Future<void> setChannel(UpdateChannel value) async {
    await _prefs.writeUpdateChannel(value);
    await _applyFeed();
    notifyListeners();
  }

  Future<void> setStationUrl(String value) async {
    await _prefs.writeUpdateServer(value.trim());
    await _applyFeed();
    notifyListeners();
  }

  Future<void> setAutoCheck(bool value) async {
    await _prefs.writeAutoCheck(value);
    await _applyFeed();
    notifyListeners();
  }

  // ---------------------------------------------------- события WinSparkle

  @override
  void onUpdaterCheckingForUpdate(Appcast? appcast) {
    _status = UpdateStatus.checking;
    _message = null;
    notifyListeners();
  }

  @override
  void onUpdaterUpdateAvailable(AppcastItem? item) {
    _status = UpdateStatus.available;
    _availableVersion = item?.displayVersionString ?? item?.versionString;
    _message = 'Доступна версия ${_availableVersion ?? '—'}';
    notifyListeners();
  }

  @override
  void onUpdaterUpdateNotAvailable(UpdaterError? error) {
    _status = UpdateStatus.upToDate;
    _message = 'Установлена последняя версия';
    notifyListeners();
  }

  @override
  void onUpdaterUpdateDownloaded(AppcastItem? item) {
    _status = UpdateStatus.downloaded;
    _message = 'Обновление загружено, установка начнётся сейчас';
    notifyListeners();
  }

  @override
  void onUpdaterBeforeQuitForUpdate(AppcastItem? item) {
    _status = UpdateStatus.downloaded;
    _message = 'Закрываемся для установки обновления';
    notifyListeners();
  }

  @override
  void onUpdaterError(UpdaterError? error) {
    _status = UpdateStatus.failed;
    // Самая частая причина — канал недоступен: нет сети, приватный
    // репозиторий, станция выключена. Пишем адрес, чтобы было видно, куда
    // именно не достучались.
    _message = '${error?.message ?? 'Ошибка проверки обновлений'}\n$effectiveFeedUrl';
    notifyListeners();
  }

  @override
  void dispose() {
    autoUpdater.removeListener(this);
    super.dispose();
  }
}
