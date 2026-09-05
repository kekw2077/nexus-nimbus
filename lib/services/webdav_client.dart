import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:xml/xml.dart';

import '../core/models/remote_file.dart';

/// Ошибка обращения к серверу с человеческим текстом — её показываем в UI,
/// а не голый статус-код.
class NextcloudException implements Exception {
  NextcloudException(this.message, {this.statusCode, this.uri});
  final String message;
  final int? statusCode;
  final Uri? uri;

  @override
  String toString() => message;

  factory NextcloudException.fromStatus(int code, Uri uri) {
    final text = switch (code) {
      401 => 'Сервер не принял логин или пароль приложения',
      403 => 'Доступ запрещён: у этой учётной записи нет прав на операцию',
      404 => 'Такого файла или папки на сервере нет',
      405 => 'Объект с таким именем уже существует',
      409 => 'Родительской папки не существует',
      412 => 'Файл на сервере изменился с момента последней проверки',
      423 => 'Файл заблокирован другим клиентом',
      507 => 'На сервере закончилось место',
      _ when code >= 500 => 'Сервер ответил ошибкой $code',
      _ => 'Неожиданный ответ сервера: $code',
    };
    return NextcloudException(text, statusCode: code, uri: uri);
  }
}

/// Учётные данные подключения. appPassword — это токен из «Устройств и сеансов»
/// либо результат Login Flow v2; пароль от самой учётной записи мы не храним.
class NxAccount {
  const NxAccount({
    required this.baseUrl,
    required this.loginName,
    required this.appPassword,
    this.displayName,
    this.allowBadCertificate = false,
  });

  /// Например https://cloud.example.com — без хвостового слэша и без /index.php.
  final Uri baseUrl;
  final String loginName;
  final String appPassword;
  final String? displayName;

  /// Для self-hosted с самоподписанным сертификатом.
  final bool allowBadCertificate;

  String get authHeader =>
      'Basic ${base64Encode(utf8.encode('$loginName:$appPassword'))}';

  NxAccount copyWith({String? displayName}) => NxAccount(
        baseUrl: baseUrl,
        loginName: loginName,
        appPassword: appPassword,
        displayName: displayName ?? this.displayName,
        allowBadCertificate: allowBadCertificate,
      );

  Map<String, dynamic> toJson() => {
        'baseUrl': baseUrl.toString(),
        'loginName': loginName,
        'appPassword': appPassword,
        'displayName': displayName,
        'allowBadCertificate': allowBadCertificate,
      };

  factory NxAccount.fromJson(Map<String, dynamic> j) => NxAccount(
        baseUrl: Uri.parse(j['baseUrl'] as String),
        loginName: j['loginName'] as String,
        appPassword: j['appPassword'] as String,
        displayName: j['displayName'] as String?,
        allowBadCertificate: j['allowBadCertificate'] as bool? ?? false,
      );
}

/// Прогресс передачи: сколько байт прошло из скольких.
typedef ProgressCallback = void Function(int done, int total);

/// Тонкий клиент поверх WebDAV Nextcloud. Реализованы только те методы,
/// что реально нужны файловому менеджеру.
class WebDavClient {
  WebDavClient(this.account) : _inner = _makeClient(account);

  final NxAccount account;
  final http.Client _inner;

  static http.Client _makeClient(NxAccount a) {
    final io = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..userAgent = 'Nexus Nimbus';
    if (a.allowBadCertificate) {
      io.badCertificateCallback = (_, host, _) => host == a.baseUrl.host;
    }
    return IOClient(io);
  }

  void close() => _inner.close();

  // ---------------------------------------------------------------- адреса

  List<String> get _basePrefix =>
      account.baseUrl.pathSegments.where((s) => s.isNotEmpty).toList();

  /// Корень пользовательских файлов: /remote.php/dav/files/{user}
  List<String> get _filesRoot =>
      [..._basePrefix, 'remote.php', 'dav', 'files', account.loginName];

  /// Абсолютный URI файла по пути относительно корня пользователя.
  Uri fileUri(String path) => account.baseUrl.replace(
        pathSegments: [..._filesRoot, ..._split(path)],
      );

  Uri uploadUri(List<String> tail) => account.baseUrl.replace(
        pathSegments: [
          ..._basePrefix,
          'remote.php',
          'dav',
          'uploads',
          account.loginName,
          ...tail,
        ],
      );

  Uri ocsUri(String path, [Map<String, String>? query]) => account.baseUrl.replace(
        pathSegments: [..._basePrefix, ...path.split('/').where((s) => s.isNotEmpty)],
        queryParameters: {'format': 'json', ...?query},
      );

  /// Ссылка на миниатюру. Отдаёт картинку и для видео с PDF, если на сервере
  /// включён соответствующий провайдер превью.
  Uri previewUri(String fileId, {int size = 256, bool crop = true}) =>
      account.baseUrl.replace(
        pathSegments: [..._basePrefix, 'index.php', 'core', 'preview'],
        queryParameters: {
          'fileId': fileId,
          'x': '$size',
          'y': '$size',
          'a': crop ? '0' : '1',
          'forceIcon': '0',
          'mode': crop ? 'cover' : 'fill',
        },
      );

  static List<String> _split(String path) =>
      path.split('/').where((s) => s.isNotEmpty).toList();

  Map<String, String> get _headers => {
        'Authorization': account.authHeader,
        'OCS-APIRequest': 'true',
        'User-Agent': 'Nexus Nimbus',
      };

  // ------------------------------------------------------------- операции

  static const _propfindBody = '<?xml version="1.0" encoding="UTF-8"?>'
      '<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" '
      'xmlns:nc="http://nextcloud.org/ns"><d:prop>'
      '<d:getlastmodified/><d:getcontentlength/><d:getcontenttype/>'
      '<d:getetag/><d:resourcetype/>'
      '<oc:fileid/><oc:size/><oc:permissions/><oc:favorite/>'
      '<nc:has-preview/>'
      '</d:prop></d:propfind>';

  static const _quotaBody = '<?xml version="1.0" encoding="UTF-8"?>'
      '<d:propfind xmlns:d="DAV:"><d:prop>'
      '<d:quota-used-bytes/><d:quota-available-bytes/>'
      '</d:prop></d:propfind>';

  /// Содержимое папки. Первым в ответе идёт сама папка — её отбрасываем.
  Future<List<RemoteFile>> list(String path) async {
    final uri = fileUri(path);
    final res = await _send('PROPFIND', uri,
        headers: {'Depth': '1', 'Content-Type': 'application/xml; charset=utf-8'},
        body: utf8.encode(_propfindBody));

    if (res.statusCode != 207) throw NextcloudException.fromStatus(res.statusCode, uri);

    final self = _normalize(path);
    return _parseMultistatus(res.bodyBytes)
        .where((f) => _normalize(f.path) != self)
        .toList()
      ..sort(byFolderThenName);
  }

  /// Свойства одной записи без содержимого папки.
  Future<RemoteFile> stat(String path) async {
    final uri = fileUri(path);
    final res = await _send('PROPFIND', uri,
        headers: {'Depth': '0', 'Content-Type': 'application/xml; charset=utf-8'},
        body: utf8.encode(_propfindBody));
    if (res.statusCode != 207) throw NextcloudException.fromStatus(res.statusCode, uri);
    final all = _parseMultistatus(res.bodyBytes);
    if (all.isEmpty) throw NextcloudException('Сервер не вернул свойства «$path»');
    return all.first;
  }

  Future<void> mkdir(String path) async {
    final uri = fileUri(path);
    final res = await _send('MKCOL', uri);
    if (res.statusCode != 201) throw NextcloudException.fromStatus(res.statusCode, uri);
  }

  Future<void> delete(String path) async {
    final uri = fileUri(path);
    final res = await _send('DELETE', uri);
    if (res.statusCode != 204 && res.statusCode != 200) {
      throw NextcloudException.fromStatus(res.statusCode, uri);
    }
  }

  Future<void> move(String from, String to, {bool overwrite = false}) =>
      _transfer('MOVE', from, to, overwrite);

  Future<void> copy(String from, String to, {bool overwrite = false}) =>
      _transfer('COPY', from, to, overwrite);

  Future<void> _transfer(String method, String from, String to, bool overwrite) async {
    final uri = fileUri(from);
    final res = await _send(method, uri, headers: {
      'Destination': fileUri(to).toString(),
      'Overwrite': overwrite ? 'T' : 'F',
    });
    if (res.statusCode != 201 && res.statusCode != 204) {
      throw NextcloudException.fromStatus(res.statusCode, uri);
    }
  }

  /// Скачивание потоком прямо в файл — большие файлы не держим в памяти.
  /// Пишем в .nxpart и переименовываем в конце, чтобы недокачанный файл
  /// никогда не выглядел как готовый.
  Future<void> download(
    String path,
    File target, {
    ProgressCallback? onProgress,
    CancelToken? cancel,
  }) async {
    final uri = fileUri(path);
    final req = http.Request('GET', uri)..headers.addAll(_headers);
    final res = await _inner.send(req);
    if (res.statusCode != 200) throw NextcloudException.fromStatus(res.statusCode, uri);

    final total = res.contentLength ?? 0;
    var done = 0;
    await target.parent.create(recursive: true);
    final part = File('${target.path}.nxpart');
    final sink = part.openWrite();
    var closed = false;
    try {
      await for (final chunk in res.stream) {
        if (cancel?.isCancelled ?? false) throw const CancelledException();
        sink.add(chunk);
        done += chunk.length;
        onProgress?.call(done, total);
      }
      await sink.flush();
      await sink.close();
      closed = true;
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
    } catch (_) {
      if (!closed) {
        try {
          await sink.close();
        } catch (_) {}
      }
      if (await part.exists()) await part.delete();
      rethrow;
    }
  }

  /// Порог, после которого уходим в чанковую загрузку: обычный PUT на файле
  /// в несколько гигабайт упирается в таймауты и лимиты PHP.
  static const chunkThreshold = 20 * 1024 * 1024;
  static const chunkSize = 10 * 1024 * 1024;

  Future<void> upload(
    File source,
    String path, {
    ProgressCallback? onProgress,
    CancelToken? cancel,
  }) async {
    final length = await source.length();
    if (length >= chunkThreshold) {
      return _uploadChunked(source, path, length, onProgress, cancel);
    }

    final uri = fileUri(path);
    var done = 0;
    final req = http.StreamedRequest('PUT', uri)
      ..headers.addAll(_headers)
      ..headers['Content-Type'] = 'application/octet-stream'
      ..contentLength = length;

    unawaited(() async {
      try {
        await for (final chunk in source.openRead()) {
          if (cancel?.isCancelled ?? false) break;
          req.sink.add(chunk);
          done += chunk.length;
          onProgress?.call(done, length);
        }
      } finally {
        await req.sink.close();
      }
    }());

    final res = await http.Response.fromStream(await _inner.send(req));
    if (cancel?.isCancelled ?? false) throw const CancelledException();
    if (res.statusCode != 201 && res.statusCode != 204 && res.statusCode != 200) {
      throw NextcloudException.fromStatus(res.statusCode, uri);
    }
  }

  /// Чанковая загрузка: временная папка в /uploads, куски по 10 МБ,
  /// затем MOVE служебного .file на боевой путь — сервер склеивает сам.
  Future<void> _uploadChunked(
    File source,
    String path,
    int length,
    ProgressCallback? onProgress,
    CancelToken? cancel,
  ) async {
    final id = 'nimbus-${DateTime.now().microsecondsSinceEpoch}';
    final dir = uploadUri([id]);
    final mk = await _send('MKCOL', dir);
    if (mk.statusCode != 201) throw NextcloudException.fromStatus(mk.statusCode, dir);

    try {
      var offset = 0;
      var index = 0;
      final handle = await source.open();
      try {
        while (offset < length) {
          if (cancel?.isCancelled ?? false) throw const CancelledException();
          final take = (length - offset) < chunkSize ? length - offset : chunkSize;
          final bytes = await handle.read(take);
          final chunkUri = uploadUri([id, index.toString().padLeft(5, '0')]);
          final res = await _send('PUT', chunkUri,
              headers: {'Content-Type': 'application/octet-stream'}, body: bytes);
          if (res.statusCode != 201 && res.statusCode != 204 && res.statusCode != 200) {
            throw NextcloudException.fromStatus(res.statusCode, chunkUri);
          }
          offset += take;
          index++;
          onProgress?.call(offset, length);
        }
      } finally {
        await handle.close();
      }

      final assemble = uploadUri([id, '.file']);
      final res = await _send('MOVE', assemble, headers: {
        'Destination': fileUri(path).toString(),
        'OC-Total-Length': '$length',
        'Overwrite': 'T',
      });
      if (res.statusCode != 201 && res.statusCode != 204) {
        throw NextcloudException.fromStatus(res.statusCode, assemble);
      }
    } catch (_) {
      try {
        await _send('DELETE', dir);
      } catch (_) {}
      rethrow;
    }
  }

  /// Квота через PROPFIND корня — отдельного OCS-запроса не нужно.
  Future<Quota> quota() async {
    final uri = fileUri('');
    final res = await _send('PROPFIND', uri,
        headers: {'Depth': '0', 'Content-Type': 'application/xml; charset=utf-8'},
        body: utf8.encode(_quotaBody));
    if (res.statusCode != 207) throw NextcloudException.fromStatus(res.statusCode, uri);

    final doc = XmlDocument.parse(utf8.decode(res.bodyBytes));
    int read(String name) {
      final e = doc.findAllElements(name, namespaceUri: '*').firstOrNull;
      return int.tryParse(e?.innerText.trim() ?? '') ?? 0;
    }

    final used = read('quota-used-bytes');
    final free = read('quota-available-bytes');
    // Сервер отдаёт отрицательное значение при безлимите и на внешних хранилищах.
    return Quota(used: used, total: free < 0 ? 0 : used + free);
  }

  /// Проверка учётных данных: заодно достаём отображаемое имя.
  Future<String> verify() async {
    final uri = ocsUri('ocs/v2.php/cloud/user');
    final res = await _inner.get(uri, headers: _headers);
    if (res.statusCode == 401) throw NextcloudException.fromStatus(401, uri);
    if (res.statusCode != 200) throw NextcloudException.fromStatus(res.statusCode, uri);
    try {
      final data = (jsonDecode(res.body) as Map)['ocs']['data'] as Map;
      final name = (data['display-name'] ?? data['displayname'] ?? '') as String;
      return name.isEmpty ? account.loginName : name;
    } catch (_) {
      // OCS открыт не на всех конфигурациях; для работы достаточно WebDAV.
      return account.loginName;
    }
  }

  /// Байты миниатюры. null — превью для этого файла сервер не отдал.
  Future<Uint8List?> preview(String fileId, {int size = 256}) async {
    try {
      final res = await _inner.get(previewUri(fileId, size: size), headers: _headers);
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;
      return res.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------- механика

  Future<http.Response> _send(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    final req = http.Request(method, uri)
      ..headers.addAll(_headers)
      ..headers.addAll(headers ?? const {});
    if (body != null) req.bodyBytes = body;
    try {
      return await http.Response.fromStream(await _inner.send(req));
    } on SocketException catch (e) {
      throw NextcloudException('Сервер недоступен: ${e.message}', uri: uri);
    } on HandshakeException {
      throw NextcloudException(
        'Не удалось проверить сертификат сервера. Если он самоподписанный, '
        'включите галочку «Доверять сертификату» при подключении.',
        uri: uri,
      );
    }
  }

  /// Разбор 207 Multi-Status. Имена элементов ищем без учёта пространства
  /// имён: серверы по-разному называют префиксы (d:, D:, DAV:).
  List<RemoteFile> _parseMultistatus(Uint8List bytes) =>
      parseMultistatus(bytes, _filesRoot.length);

  /// Отдельно от клиента, чтобы разбор можно было проверить тестом
  /// без обращения к серверу.
  @visibleForTesting
  static List<RemoteFile> parseMultistatus(Uint8List bytes, int rootDepth) {
    final doc = XmlDocument.parse(utf8.decode(bytes));
    final out = <RemoteFile>[];

    for (final resp in doc.findAllElements('response', namespaceUri: '*')) {
      final href = resp.findElements('href', namespaceUri: '*').firstOrNull?.innerText;
      if (href == null) continue;

      // pathSegments уже раскодирован из процентной записи.
      final segs = Uri.parse(href).pathSegments.where((s) => s.isNotEmpty).toList();
      if (segs.length < rootDepth) continue;
      final path = segs.skip(rootDepth).join('/');

      // Берём только тот propstat, который вернул 200.
      XmlElement? props;
      for (final ps in resp.findElements('propstat', namespaceUri: '*')) {
        final status = ps.findElements('status', namespaceUri: '*').firstOrNull?.innerText ?? '';
        if (status.contains('200')) {
          props = ps.findElements('prop', namespaceUri: '*').firstOrNull;
          break;
        }
      }
      final prop = props;
      if (prop == null) continue;

      String? text(String name) {
        final v = prop.findElements(name, namespaceUri: '*').firstOrNull?.innerText.trim();
        return (v == null || v.isEmpty) ? null : v;
      }

      final rt = prop.findElements('resourcetype', namespaceUri: '*').firstOrNull;
      final isDir = rt?.findElements('collection', namespaceUri: '*').isNotEmpty ?? false;

      out.add(RemoteFile(
        path: path,
        isDir: isDir,
        size: int.tryParse(text(isDir ? 'size' : 'getcontentlength') ?? '') ??
            int.tryParse(text('size') ?? '') ??
            0,
        modified: _parseDate(text('getlastmodified')),
        etag: text('getetag')?.replaceAll('"', ''),
        fileId: text('fileid'),
        mimeType: text('getcontenttype'),
        hasPreview: text('has-preview') == 'true',
        favorite: text('favorite') == '1',
        permissions: text('permissions') ?? '',
      ));
    }
    return out;
  }

  static DateTime? _parseDate(String? raw) {
    if (raw == null) return null;
    try {
      return HttpDate.parse(raw).toLocal();
    } catch (_) {
      return DateTime.tryParse(raw)?.toLocal();
    }
  }

  static String _normalize(String path) => path.replaceAll(RegExp(r'^/+|/+$'), '');

  static int byFolderThenName(RemoteFile a, RemoteFile b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }
}

/// Отмена передачи. Кладётся в задачу очереди и дёргается из UI.
class CancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class CancelledException implements Exception {
  const CancelledException();
  @override
  String toString() => 'Передача отменена';
}
