import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:auto_updater/auto_updater.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:xml/xml.dart';

import 'prefs.dart';
import 'win_sparkle.dart';

/// Один выпуск из канала обновлений.
class ReleaseEntry {
  const ReleaseEntry({
    required this.version,
    required this.title,
    required this.installerUrl,
    this.publishedAt,
    this.size = 0,
    this.notes = const [],
  });

  final String version;
  final String title;

  /// Что изменилось — строками, как их пишет release.ps1.
  final List<String> notes;

  /// Адрес установщика — его и открывают, когда хотят вернуться назад.
  final String installerUrl;

  final DateTime? publishedAt;
  final int size;

  /// Сравнение версий по числам, а не по строкам: иначе 0.10.0 оказалась бы
  /// старше 0.9.0.
  static int compare(String a, String b) {
    List<int> parts(String v) => v
        .split(RegExp(r'[.+-]'))
        .map((s) => int.tryParse(s) ?? 0)
        .toList();

    final x = parts(a);
    final y = parts(b);
    for (var i = 0; i < (x.length > y.length ? x.length : y.length); i++) {
      final l = i < x.length ? x[i] : 0;
      final r = i < y.length ? y[i] : 0;
      if (l != r) return l.compareTo(r);
    }
    return 0;
  }
}

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

  Timer? _schedule;

  /// Заводит своё расписание проверок. Первая — через несколько секунд после
  /// запуска: канал может быть недоступен, и держать из-за этого окно нечего.
  void startWatching() {
    _schedule?.cancel();
    if (!autoCheck || !_ready) return;

    _schedule = Timer.periodic(checkInterval, (_) => unawaited(findUpdate()));
    unawaited(Future<void>.delayed(
      const Duration(seconds: 4),
      () => autoCheck ? findUpdate() : null,
    ));
  }

  void stopWatching() {
    _schedule?.cancel();
    _schedule = null;
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
      // Своё расписание WinSparkle выключаем: сработав, оно показало бы
      // собственное окно поверх нашего. Проверять будем сами.
      await autoUpdater.setScheduledCheckInterval(0);
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

  // ------------------------------------------------------- прежние версии

  /// Все выпуски из канала, от новых к старым.
  ///
  /// Читаем канал сами, а не через WinSparkle: он умеет ровно одно —
  /// поставить самое новое. Список нужен, чтобы можно было вернуться назад,
  /// когда в свежей версии что-то сломалось.
  Future<List<ReleaseEntry>> listReleases() async {
    final uri = Uri.parse(effectiveFeedUrl);
    final res = await http.get(uri);
    if (res.statusCode != 200) {
      throw Exception('Канал обновлений не ответил (${res.statusCode}): $uri');
    }
    return parseAppcast(res.bodyBytes);
  }

  /// Разбор appcast. Отдельным методом и без обращений к сети — чтобы
  /// проверялся тестом.
  @visibleForTesting
  static List<ReleaseEntry> parseAppcast(List<int> bytes) {
    final doc = XmlDocument.parse(utf8.decode(bytes));
    final out = <ReleaseEntry>[];

    for (final item in doc.findAllElements('item')) {
      final enclosure = item.findElements('enclosure').firstOrNull;
      if (enclosure == null) continue;

      final url = enclosure.getAttribute('url')?.trim();
      if (url == null || url.isEmpty) continue;

      // Версия лежит то в самом item, то атрибутом enclosure — берём любую.
      final version = _text(item, 'version') ??
          enclosure.getAttribute('sparkle:version')?.trim() ??
          enclosure.getAttribute('version')?.trim();
      if (version == null || version.isEmpty) continue;

      out.add(ReleaseEntry(
        version: version,
        title: _text(item, 'title') ?? 'Nexus Nimbus $version',
        installerUrl: url,
        publishedAt: _rfc822(_text(item, 'pubDate')),
        size: int.tryParse(enclosure.getAttribute('length') ?? '') ?? 0,
        notes: _notes(_text(item, 'description')),
      ));
    }

    out.sort((a, b) => ReleaseEntry.compare(b.version, a.version));
    return out;
  }

  /// Список изменений из описания выпуска. Описание — это кусок HTML,
  /// и разбирать его целиком незачем: release.ps1 пишет туда строчки
  /// списка, их и достаём.
  static List<String> _notes(String? description) {
    if (description == null) return const [];
    return RegExp(r'<li>(.*?)</li>', dotAll: true)
        .allMatches(description)
        .map((m) => _plain(m.group(1) ?? ''))
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
  }

  /// Снимает разметку и возвращает символьные ссылки на место.
  ///
  /// Числовые ссылки тоже: release.ps1 их не пишет, но канал можно поправить
  /// и руками, а «Кавычки &#171;ёлочки&#187;» в окне обновления — не то,
  /// что человек хотел прочитать.
  static String _plain(String html) {
    var text = html.replaceAll(RegExp(r'<[^>]*>'), '');

    text = text.replaceAllMapped(
      RegExp(r'&#(x[0-9a-fA-F]+|\d+);'),
      (m) {
        final raw = m.group(1)!;
        final code = raw.startsWith('x') || raw.startsWith('X')
            ? int.tryParse(raw.substring(1), radix: 16)
            : int.tryParse(raw);
        return code == null ? m.group(0)! : String.fromCharCode(code);
      },
    );

    // Амперсанд последним: иначе «&amp;lt;» превратилось бы в «<».
    return text
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&')
        .trim();
  }

  /// Значение дочернего элемента без учёта пространства имён: в appcast
  /// половина полей идёт с префиксом sparkle:, половина — без.
  static String? _text(XmlElement item, String name) {
    final v = item.findElements(name, namespaceUri: '*').firstOrNull?.innerText.trim() ??
        item.findElements('sparkle:$name').firstOrNull?.innerText.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  /// Дата в appcast — RFC 822, которую DateTime.parse не берёт.
  static DateTime? _rfc822(String? raw) {
    if (raw == null) return null;
    final m = RegExp(r'(\d{1,2})\s+(\w{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})')
        .firstMatch(raw);
    if (m == null) return null;

    const months = {
      'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
      'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
    };
    final month = months[m.group(2)];
    if (month == null) return null;

    return DateTime.utc(
      int.parse(m.group(3)!),
      month,
      int.parse(m.group(1)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.parse(m.group(6)!),
    ).toLocal();
  }

  // ------------------------------------------------------- своя проверка

  ReleaseEntry? _found;

  /// Найденное обновление, которое ещё не предложили. Обнуляется, как только
  /// окно показано: второй раз про ту же версию напоминать незачем.
  ReleaseEntry? get found => _found;

  String get skippedVersion => _prefs.readSkippedVersion();

  Future<void> skip(String version) async {
    await _prefs.writeSkippedVersion(version);
    _found = null;
    notifyListeners();
  }

  Future<void> unskip() async {
    await _prefs.writeSkippedVersion('');
    notifyListeners();
  }

  void forgetFound() {
    if (_found == null) return;
    _found = null;
    notifyListeners();
  }

  /// Ищет выпуск новее установленного. Канал читаем сами, а не отдаём
  /// WinSparkle: его окно нарисовано обычными органами Windows и мимо всего
  /// оформления. Спрашивать будет наше окно, а ему остаётся скачивание
  /// и сверка подписи.
  Future<ReleaseEntry?> findUpdate({bool ignoreSkipped = false}) async {
    _status = UpdateStatus.checking;
    _message = null;
    notifyListeners();

    try {
      final releases = await listReleases();
      final skipped = _prefs.readSkippedVersion();

      for (final release in releases) {
        if (ReleaseEntry.compare(release.version, _currentVersion) <= 0) continue;
        if (!ignoreSkipped && release.version == skipped) continue;

        _found = release;
        _availableVersion = release.version;
        _status = UpdateStatus.available;
        _message = 'Доступна версия ${release.version}';
        notifyListeners();
        return release;
      }

      _found = null;
      _status = UpdateStatus.upToDate;
      _message = 'Установлена последняя версия';
      notifyListeners();
      return null;
    } catch (e) {
      _found = null;
      _status = UpdateStatus.failed;
      _message = '$e';
      notifyListeners();
      return null;
    }
  }

  /// Ставит найденное обновление. Скачивание и сверку подписи делает
  /// WinSparkle — писать это самим значило бы обойти проверку, ради которой
  /// заведён ключ.
  Future<void> install() async {
    if (!Platform.isWindows) return;
    _found = null;

    if (WinSparkle.checkAndInstall()) {
      _status = UpdateStatus.downloaded;
      _message = 'Скачиваем обновление…';
      notifyListeners();
      return;
    }

    // Обхода нет — отдаём пакету вместе с его собственным окном.
    await check();
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
    stopWatching();
    autoUpdater.removeListener(this);
    super.dispose();
  }
}
