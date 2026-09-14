import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';

import 'prefs.dart';
import 'update_signature.dart';

/// Один выпуск из канала обновлений.
class ReleaseEntry {
  const ReleaseEntry({
    required this.version,
    required this.title,
    required this.installerUrl,
    this.publishedAt,
    this.size = 0,
    this.notes = const [],
    this.sha256,
    this.signature,
    this.installerArguments = const [],
  });

  final String version;
  final String title;

  /// Что изменилось — строками, как их пишет release.ps1.
  final List<String> notes;

  /// Адрес установщика — его и открывают, когда хотят вернуться назад.
  final String installerUrl;

  final DateTime? publishedAt;
  final int size;

  /// `nimbus:sha256` — быстрая сверка, что скачалось то, что выложено.
  final String? sha256;

  /// `sparkle:dsaSignature` — подпись закрытым ключом проекта. Без неё
  /// установщик не запустится: это единственное, что отличает наш файл
  /// от подсунутого по дороге.
  final String? signature;

  /// `sparkle:installerArguments` — ключи тихой установки. Без них человек
  /// получил бы полный мастер вместо перезапуска.
  final List<String> installerArguments;

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

enum UpdateStatus {
  idle,
  checking,
  available,
  upToDate,
  downloading,
  verifying,
  installing,
  failed,
}

/// Обновления: свой канал, своя загрузка, своя проверка подписи.
///
/// Приходят **полные установщики**, а не патчи кода: значит, в обновление
/// могут входить и нативные изменения — новый плагин, другая версия Flutter.
/// Каждый установщик подписан закрытым DSA-ключом, открытый зашит в
/// [UpdateSignature]. Подпись не сойдётся — файл не запустится, поэтому
/// подменить обновление по дороге нельзя.
///
/// Раньше скачивание и проверку делал WinSparkle (пакет auto_updater), и у
/// него были свои окна мимо оформления, своё расписание, которое нельзя было
/// выключить, и своё понимание версий, в котором «0.3.3+6» старше «0.3.3».
/// Теперь всё это здесь, а на экране — одно окно, наше.
class UpdaterService extends ChangeNotifier {
  UpdaterService(this._prefs);

  final Prefs _prefs;

  /// Запасной и основной канал: файл в публичном репозитории.
  /// raw.githubusercontent отдаёт его без токена, и канал читается без
  /// авторизации — поэтому репозиторий обязан быть публичным.
  static const githubFeedUrl =
      'https://raw.githubusercontent.com/kekw2077/nexus-nimbus/main/dist/appcast.xml';

  /// Переменная окружения перебивает всё: ей проверяют канал перед выкладкой,
  /// не трогая настройки пользователя.
  static const envOverride = 'NIMBUS_UPDATE_FEED';

  /// Раз в шесть часов.
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
    _ready = true;
    notifyListeners();

    // Установщики одноразовые: что осталось с прошлого раза, то не нужно.
    unawaited(_sweepDownloads());
  }

  // ------------------------------------------------------- прежние версии

  /// Все выпуски из канала, от новых к старым. Список нужен и для
  /// проверки, и чтобы можно было вернуться назад, когда в свежей версии
  /// что-то сломалось.
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
        sha256: _attr(enclosure, 'sha256'),
        signature: _attr(enclosure, 'dsaSignature'),
        installerArguments: (_attr(enclosure, 'installerArguments') ?? '')
            .split(RegExp(r'\s+'))
            .where((a) => a.isNotEmpty)
            .toList(growable: false),
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

  /// Атрибут enclosure без учёта префикса: `sparkle:dsaSignature`,
  /// `nimbus:sha256` — префиксы разные, а смысл у каждого один.
  static String? _attr(XmlElement el, String name) {
    for (final a in el.attributes) {
      if (a.name.local == name) {
        final v = a.value.trim();
        return v.isEmpty ? null : v;
      }
    }
    return null;
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

  /// Ищет выпуск новее установленного. Пока идёт установка, не лезем:
  /// иначе проверка по расписанию сбила бы ход скачивания.
  Future<ReleaseEntry?> findUpdate({bool ignoreSkipped = false}) async {
    if (busy) return _found;
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

  // ------------------------------------------------------- установка

  /// Чем закончить, когда установщик запущен. Задаёт main.dart: выход
  /// через трей снимает перехват закрытия и убирает значок, а самому
  /// сервису об этом знать незачем.
  Future<void> Function()? onQuit;

  int _received = 0;
  int _total = 0;
  http.Client? _client;
  bool _cancelled = false;

  /// Скачано и всего, байтами. Всего — ноль, пока сервер не сказал.
  int get received => _received;
  int get total => _total;

  /// Доля скачанного, если размер известен.
  double? get progress => _total > 0 ? (_received / _total).clamp(0.0, 1.0) : null;

  /// Идёт скачивание, проверка или запуск установщика.
  bool get busy =>
      _status == UpdateStatus.downloading ||
      _status == UpdateStatus.verifying ||
      _status == UpdateStatus.installing;

  /// Скачивает установщик, сверяет длину, sha256 и подпись, запускает его
  /// тихо и закрывает программу. Установщик сам поднимет новую версию
  /// (`/RELAUNCH=1`, см. dist/installer.iss).
  ///
  /// Файл пишем сами, а не через браузер или системный загрузчик — поэтому
  /// на нём нет отметки «получен из интернета», и SmartScreen молчит.
  Future<void> install(ReleaseEntry release) async {
    if (!Platform.isWindows || busy) return;
    if (release.signature == null) {
      _fail('В записи канала нет подписи — такой установщик не запускаем.');
      return;
    }

    _found = null;
    _cancelled = false;
    _received = 0;
    _total = release.size;
    _status = UpdateStatus.downloading;
    _message = 'Скачиваем ${release.version}…';
    notifyListeners();

    File? file;
    try {
      final dir = await _downloadDir();
      file = File(p.join(dir.path, _fileName(release)));

      final digests = await _download(release, file);
      if (_cancelled) return;

      _status = UpdateStatus.verifying;
      _message = 'Проверяем подпись…';
      notifyListeners();

      final why = _verify(release, digests, await file.length());
      if (why != null) throw _UpdateException(why);

      _status = UpdateStatus.installing;
      _message = 'Ставим ${release.version}, программа закроется…';
      notifyListeners();

      await Process.start(
        file.path,
        release.installerArguments.isEmpty
            ? const ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', '/RELAUNCH=1']
            : release.installerArguments,
        mode: ProcessStartMode.detached,
      );
      // Файл не удаляем: его сейчас читает установщик. Уберёт следующий
      // запуск, см. _sweepDownloads.
      file = null;

      // Уйти надо быстро и наверняка. Установщик через полсекунды после
      // старта ищет, кто держит его файлы, и застрявшую копию закрывает
      // силой — восемь секунд ожидания; а если старая копия ещё жива, когда
      // он поднимает новую, та по правилу единственности отдаст ей фокус
      // и выйдет — «после обновления программа не открылась». Поэтому
      // аккуратный выход через трей — с таймаутом, и в любом случае exit.
      final quit = onQuit;
      if (quit != null) {
        try {
          await quit().timeout(const Duration(seconds: 2));
        } catch (_) {}
      }
      exit(0);
    } on _UpdateException catch (e) {
      _fail(e.message);
    } catch (e) {
      if (_cancelled) return;
      _fail('Не удалось скачать обновление: $e');
    } finally {
      _client?.close();
      _client = null;
      if (file != null) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
  }

  /// Останавливает скачивание. Предложение остаётся в силе — окно можно
  /// открыть снова из настроек.
  void cancelInstall() {
    if (_status != UpdateStatus.downloading) return;
    _cancelled = true;
    _client?.close();
    _status = UpdateStatus.idle;
    _message = null;
    notifyListeners();
  }

  void _fail(String message) {
    _status = UpdateStatus.failed;
    _message = message;
    notifyListeners();
  }

  /// Потоком в файл, попутно считая оба хеша — второго прохода по 13 МБ
  /// не нужно. Прогресс сообщаем не чаще нескольких раз в секунду: каждая
  /// порция — перерисовка окна.
  Future<_Digests> _download(ReleaseEntry release, File file) async {
    final client = _client = http.Client();
    final response =
        await client.send(http.Request('GET', Uri.parse(release.installerUrl)));
    if (response.statusCode != 200) {
      throw _UpdateException(
          'Сервер не отдал установщик (${response.statusCode}): ${release.installerUrl}');
    }
    if (_total <= 0) _total = response.contentLength ?? 0;

    final sha1Out = _DigestSink();
    final sha256Out = _DigestSink();
    final sha1In = sha1.startChunkedConversion(sha1Out);
    final sha256In = sha256.startChunkedConversion(sha256Out);

    final sink = file.openWrite();
    var lastTick = DateTime.now();
    try {
      await for (final chunk in response.stream) {
        if (_cancelled) break;
        sink.add(chunk);
        sha1In.add(chunk);
        sha256In.add(chunk);
        _received += chunk.length;

        final now = DateTime.now();
        if (now.difference(lastTick).inMilliseconds >= 150) {
          lastTick = now;
          notifyListeners();
        }
      }
    } finally {
      await sink.close();
    }
    sha1In.close();
    sha256In.close();
    notifyListeners();
    return _Digests(sha1Out.value!, sha256Out.value!);
  }

  /// Почему файлу нельзя верить; `null` — всё сошлось.
  static String? _verify(ReleaseEntry release, _Digests d, int length) {
    if (release.size > 0 && length != release.size) {
      return 'Установщик скачался не целиком: $length байт вместо ${release.size}.';
    }
    if (release.sha256 != null &&
        d.sha256.toString().toLowerCase() != release.sha256!.toLowerCase()) {
      return 'Контрольная сумма установщика не сошлась с каналом.';
    }
    if (!UpdateSignature.verify(fileSha1: d.sha1, signatureBase64: release.signature!)) {
      return 'Подпись установщика не сошлась — файл не тот, что выпускали.';
    }
    return null;
  }

  static String _fileName(ReleaseEntry release) {
    final fromUrl = Uri.tryParse(release.installerUrl)?.pathSegments.lastOrNull;
    return (fromUrl != null && fromUrl.toLowerCase().endsWith('.exe'))
        ? fromUrl
        : 'NexusNimbus-Setup-${release.version}.exe';
  }

  /// Своя папка в данных приложения, а не временная: установщик должен
  /// дожить до запуска, а системный temp иногда чистят на ходу.
  static Future<Directory> _downloadDir() async {
    final dir =
        Directory(p.join((await getApplicationSupportDirectory()).path, 'updates'));
    await dir.create(recursive: true);
    return dir;
  }

  Future<void> _sweepDownloads() async {
    try {
      final dir = await _downloadDir();
      await for (final f in dir.list()) {
        if (f is File && f.path.toLowerCase().endsWith('.exe')) {
          try {
            await f.delete();
          } catch (_) {
            // Ещё занят установщиком — уберётся в следующий раз.
          }
        }
      }
    } catch (_) {}
  }

  Future<void> setChannel(UpdateChannel value) async {
    await _prefs.writeUpdateChannel(value);
    notifyListeners();
  }

  Future<void> setStationUrl(String value) async {
    await _prefs.writeUpdateServer(value.trim());
    notifyListeners();
  }

  Future<void> setAutoCheck(bool value) async {
    await _prefs.writeAutoCheck(value);
    notifyListeners();
  }

  @override
  void dispose() {
    stopWatching();
    _client?.close();
    super.dispose();
  }
}

class _UpdateException implements Exception {
  const _UpdateException(this.message);
  final String message;
}

class _Digests {
  const _Digests(this.sha1, this.sha256);
  final Digest sha1;
  final Digest sha256;
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
