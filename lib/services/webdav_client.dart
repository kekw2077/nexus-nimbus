import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:xml/xml.dart';

import '../core/models/cloud_provider.dart';
import '../core/models/file_version.dart';
import '../core/models/public_link.dart';
import '../core/models/remote_file.dart';
import '../core/models/trash_item.dart';
import 'storage_backend.dart';

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
    this.provider = CloudProvider.nextcloud,
  });

  /// Например https://cloud.example.com — без хвостового слэша и без /index.php.
  final Uri baseUrl;
  final String loginName;
  final String appPassword;
  final String? displayName;

  /// Для self-hosted с самоподписанным сертификатом.
  final bool allowBadCertificate;

  /// Какое облако за этой записью. Пока всегда Nextcloud — поле заведено
  /// ради переключателя учётных записей, который должен называть облако
  /// по имени, а не считать его единственным.
  final CloudProvider provider;

  String get authHeader =>
      'Basic ${base64Encode(utf8.encode('$loginName:$appPassword'))}';

  /// Устойчивое имя записи: по нему разводятся хранилища и настройки.
  /// Пароль сюда не входит — смена пароля не должна выглядеть как новая
  /// учётная запись с пустым хранилищем.
  String get id => '${provider.name}@${baseUrl.host}#$loginName';

  /// То же имя, но пригодное для имени файла или папки.
  String get slug => id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  NxAccount copyWith({String? displayName, CloudProvider? provider}) => NxAccount(
        baseUrl: baseUrl,
        loginName: loginName,
        appPassword: appPassword,
        displayName: displayName ?? this.displayName,
        allowBadCertificate: allowBadCertificate,
        provider: provider ?? this.provider,
      );

  Map<String, dynamic> toJson() => {
        'baseUrl': baseUrl.toString(),
        'loginName': loginName,
        'appPassword': appPassword,
        'displayName': displayName,
        'allowBadCertificate': allowBadCertificate,
        'provider': provider.name,
      };

  factory NxAccount.fromJson(Map<String, dynamic> j) => NxAccount(
        baseUrl: Uri.parse(j['baseUrl'] as String),
        loginName: j['loginName'] as String,
        appPassword: j['appPassword'] as String,
        displayName: j['displayName'] as String?,
        allowBadCertificate: j['allowBadCertificate'] as bool? ?? false,
        provider: CloudProvider.byName(j['provider'] as String?),
      );
}

/// Прогресс передачи: сколько байт прошло из скольких.
typedef ProgressCallback = void Function(int done, int total);

/// Тонкий клиент поверх WebDAV Nextcloud. Реализованы только те методы,
/// что реально нужны файловому менеджеру.
class WebDavClient extends StorageBackend {
  WebDavClient(this.account) : _inner = _makeClient(account);

  @override
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

  @override
  void close() => _inner.close();

  // ---------------------------------------------------------------- адреса

  List<String> get _basePrefix =>
      account.baseUrl.pathSegments.where((s) => s.isNotEmpty).toList();

  /// Корень пользовательских файлов. У Nextcloud это
  /// `/remote.php/dav/files/{user}`, у обычного WebDAV — сам корень адреса.
  List<String> get _filesRoot =>
      [..._basePrefix, ...account.provider.filesRoot(account.loginName)];

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

  /// Корень DAV целиком: /remote.php/dav. Обычные операции идут глубже,
  /// в files/{user}, но SEARCH адресуется именно сюда.
  Uri get davRootUri => account.baseUrl.replace(
        pathSegments: [..._basePrefix, 'remote.php', 'dav'],
      );

  /// Дерево версий: /remote.php/dav/versions/{user}/…
  Uri versionsUri(List<String> tail) => account.baseUrl.replace(
        pathSegments: [
          ..._basePrefix,
          'remote.php',
          'dav',
          'versions',
          account.loginName,
          ...tail,
        ],
      );

  /// Корзина сервера: /remote.php/dav/trashbin/{user}/…
  /// Внутри две «папки»: trash со всем удалённым и виртуальная restore,
  /// перемещение в которую возвращает файл на исходное место.
  Uri trashUri(List<String> tail) => account.baseUrl.replace(
        pathSegments: [
          ..._basePrefix,
          'remote.php',
          'dav',
          'trashbin',
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

  /// Свойства, которые спрашиваем про каждую запись. Один список на
  /// PROPFIND и на REPORT — разбор у них общий, значит и запрос должен
  /// приносить одно и то же.
  static const _props = '<d:prop>'
      '<d:getlastmodified/><d:getcontentlength/><d:getcontenttype/>'
      '<d:getetag/><d:resourcetype/>'
      '<oc:fileid/><oc:size/><oc:permissions/><oc:favorite/>'
      '<nc:has-preview/>'
      '</d:prop>';

  static const _ns = 'xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" '
      'xmlns:nc="http://nextcloud.org/ns"';

  static const _propfindBody =
      '<?xml version="1.0" encoding="UTF-8"?><d:propfind $_ns>$_props</d:propfind>';

  static const _quotaBody = '<?xml version="1.0" encoding="UTF-8"?>'
      '<d:propfind xmlns:d="DAV:"><d:prop>'
      '<d:quota-used-bytes/><d:quota-available-bytes/>'
      '</d:prop></d:propfind>';

  /// Содержимое папки. Первым в ответе идёт сама папка — её отбрасываем.
  @override
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
  @override
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

  @override
  Future<void> mkdir(String path) async {
    final uri = fileUri(path);
    final res = await _send('MKCOL', uri);
    if (res.statusCode != 201) throw NextcloudException.fromStatus(res.statusCode, uri);
  }

  /// Пометить или снять пометку «избранное». Свойство серверное: клиент
  /// его только переключает, а хранит и раздаёт Nextcloud.
  @override
  Future<void> setFavorite(String path, bool favorite) async {
    _require(account.provider.hasFavorites, 'Избранное');
    final uri = fileUri(path);
    final body = '<?xml version="1.0" encoding="UTF-8"?>'
        '<d:propertyupdate $_ns><d:set><d:prop>'
        '<oc:favorite>${favorite ? 1 : 0}</oc:favorite>'
        '</d:prop></d:set></d:propertyupdate>';

    final res = await _send('PROPPATCH', uri,
        headers: {'Content-Type': 'application/xml; charset=utf-8'},
        body: utf8.encode(body));
    if (res.statusCode != 207 && res.statusCode != 200) {
      throw NextcloudException.fromStatus(res.statusCode, uri);
    }
  }

  /// Всё избранное по всему серверу, а не по текущей папке. Обычный PROPFIND
  /// такого не умеет — у Nextcloud для этого REPORT с правилами отбора.
  @override
  Future<List<RemoteFile>> favorites() async {
    _require(account.provider.hasFavorites, 'Избранное');
    final uri = fileUri('');
    final body = '<?xml version="1.0" encoding="UTF-8"?>'
        '<oc:filter-files $_ns>$_props'
        '<oc:filter-rules><oc:favorite>1</oc:favorite></oc:filter-rules>'
        '</oc:filter-files>';

    final res = await _send('REPORT', uri,
        headers: {'Content-Type': 'application/xml; charset=utf-8'},
        body: utf8.encode(body));
    if (res.statusCode != 207) throw NextcloudException.fromStatus(res.statusCode, uri);

    final self = _normalize('');
    return _parseMultistatus(res.bodyBytes)
        .where((f) => _normalize(f.path) != self)
        .toList()
      ..sort(byFolderThenName);
  }

  /// Поиск по имени во всём дереве пользователя. Это WebDAV SEARCH из
  /// RFC 5323: Nextcloud поддерживает его с 18-й версии, но на старых
  /// сборках и урезанных конфигурациях его может не быть — тогда сервер
  /// отвечает отказом, и звать его бессмысленно.
  @override
  Future<List<RemoteFile>> search(String query, {int limit = 100}) async {
    _require(account.provider.hasSearch, 'Поиск по дереву');
    final needle = query.trim();
    if (needle.isEmpty) return const [];

    final uri = davRootUri;
    // Проценты вокруг — это подстановочные знаки LIKE: ищем вхождение,
    // а не совпадение целиком.
    final like = _xmlEscape('%$needle%');
    final scope = '/files/${Uri.encodeComponent(account.loginName)}/';

    final body = '<?xml version="1.0" encoding="UTF-8"?>'
        '<d:searchrequest $_ns><d:basicsearch>'
        '<d:select>$_props</d:select>'
        '<d:from><d:scope>'
        '<d:href>${_xmlEscape(scope)}</d:href><d:depth>infinity</d:depth>'
        '</d:scope></d:from>'
        '<d:where><d:like>'
        '<d:prop><d:displayname/></d:prop><d:literal>$like</d:literal>'
        '</d:like></d:where>'
        '<d:orderby/>'
        '<d:limit><d:nresults>$limit</d:nresults></d:limit>'
        '</d:basicsearch></d:searchrequest>';

    final res = await _send('SEARCH', uri,
        headers: {'Content-Type': 'text/xml; charset=utf-8'},
        body: utf8.encode(body));

    if (res.statusCode == 400 || res.statusCode == 405 || res.statusCode == 501) {
      throw NextcloudException(
        'Этот сервер не умеет поиск по дереву (WebDAV SEARCH). '
        'Искать можно в текущей папке — полем над списком.',
        statusCode: res.statusCode,
        uri: uri,
      );
    }
    if (res.statusCode != 207) throw NextcloudException.fromStatus(res.statusCode, uri);

    final self = _normalize('');
    return _parseMultistatus(res.bodyBytes)
        .where((f) => _normalize(f.path) != self)
        .toList()
      ..sort(byFolderThenName);
  }

  /// Экранирование для тела запроса: имя файла может содержать & или <.
  static String _xmlEscape(String v) => v
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  @override
  Future<void> delete(String path) async {
    final uri = fileUri(path);
    final res = await _send('DELETE', uri);
    if (res.statusCode != 204 && res.statusCode != 200) {
      throw NextcloudException.fromStatus(res.statusCode, uri);
    }
  }

  @override
  Future<void> move(String from, String to, {bool overwrite = false}) =>
      _transfer('MOVE', from, to, overwrite);

  @override
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

  /// Содержимое файла потоком, без записи на диск.
  ///
  /// Нужно перетаскиванию наружу: Проводник просит содержимое в момент
  /// броска и сам решает, куда его положить, — файла у нас на этот момент
  /// может и не быть.
  @override
  Future<({Stream<List<int>> stream, int length})> openRead(String path) async {
    final uri = fileUri(path);
    final req = http.Request('GET', uri)..headers.addAll(_headers);
    final res = await _inner.send(req);
    if (res.statusCode != 200) {
      throw NextcloudException.fromStatus(res.statusCode, uri);
    }
    return (stream: res.stream, length: res.contentLength ?? 0);
  }

  /// Скачивание потоком прямо в файл — большие файлы не держим в памяти.
  /// Пишем в .nxpart и переименовываем в конце, чтобы недокачанный файл
  /// никогда не выглядел как готовый.
  @override
  Future<void> download(
    String path,
    File target, {
    ProgressCallback? onProgress,
    CancelToken? cancel,

    /// Откуда качать, если это не обычный файл по [path]: так забирается
    /// отдельная версия из дерева версий.
    Uri? from,
  }) async {
    final uri = from ?? fileUri(path);
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

  @override
  Future<void> upload(
    File source,
    String path, {
    ProgressCallback? onProgress,
    CancelToken? cancel,
  }) async {
    final length = await source.length();
    if (length >= chunkThreshold && account.provider.hasChunkedUpload) {
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

  // -------------------------------------------------------------- корзина

  static const _trashBody = '<?xml version="1.0" encoding="UTF-8"?>'
      '<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" '
      'xmlns:nc="http://nextcloud.org/ns"><d:prop>'
      '<d:getcontentlength/><d:getcontenttype/><d:resourcetype/>'
      '<oc:size/><oc:fileid/>'
      '<nc:trashbin-filename/><nc:trashbin-original-location/>'
      '<nc:trashbin-deletion-time/>'
      '</d:prop></d:propfind>';

  /// Всё, что лежит в корзине. Список плоский: подпапки удалённой папки
  /// внутрь корзины отдельными записями не попадают.
  // -------------------------------------------------------------- версии

  static const _versionProps = '<?xml version="1.0" encoding="UTF-8"?>'
      '<d:propfind $_ns><d:prop>'
      '<d:getcontentlength/><d:getlastmodified/><d:getcontenttype/>'
      '<nc:version-label/>'
      '</d:prop></d:propfind>';

  /// Версии одного файла. Адресуются по fileid, а не по пути: переименование
  /// файла историю не рвёт, а путь — рвёт.
  @override
  Future<List<FileVersion>> listVersions(String fileId) async {
    _require(account.provider.hasVersions, 'Версии файлов');
    final uri = versionsUri(['versions', fileId]);
    final res = await _send('PROPFIND', uri,
        headers: {'Depth': '1', 'Content-Type': 'application/xml; charset=utf-8'},
        body: utf8.encode(_versionProps));

    if (res.statusCode != 207) throw NextcloudException.fromStatus(res.statusCode, uri);

    // До самой версии путь длиннее корня на два сегмента: versions/{fileid}.
    // На этой же глубине лежит и сама папка версий — её надо отбросить,
    // поэтому сравнение в разборе строгое.
    return parseVersions(res.bodyBytes, _versionsRoot.length + 2)
      ..sort((a, b) => (b.when ?? DateTime(0)).compareTo(a.when ?? DateTime(0)));
  }

  /// Вернуть файлу состояние выбранной версии. Нынешнее содержимое при этом
  /// само становится очередной версией — сервер ничего не теряет.
  @override
  Future<void> restoreVersion(String fileId, String versionId) async {
    final uri = versionsUri(['versions', fileId, versionId]);
    final res = await _send('MOVE', uri, headers: {
      'Destination': versionsUri(['restore', 'target']).toString(),
    });
    if (res.statusCode != 201 && res.statusCode != 204) {
      throw NextcloudException.fromStatus(res.statusCode, uri);
    }
  }

  /// Скачать конкретную версию, ничего не восстанавливая, — чтобы можно
  /// было сперва посмотреть, а потом решать.
  Future<void> downloadVersion(
    String fileId,
    String versionId,
    File target, {
    ProgressCallback? onProgress,
    CancelToken? cancel,
  }) =>
      download('',
          target,
          onProgress: onProgress,
          cancel: cancel,
          from: versionsUri(['versions', fileId, versionId]));

  List<String> get _versionsRoot =>
      [..._basePrefix, 'remote.php', 'dav', 'versions', account.loginName];

  /// Разбор списка версий. Отдельно от [parseMultistatus]: у версии нет ни
  /// имени, ни пути — только числовой идентификатор в последнем сегменте.
  @visibleForTesting
  static List<FileVersion> parseVersions(Uint8List bytes, int rootDepth) {
    final doc = XmlDocument.parse(utf8.decode(bytes));
    final out = <FileVersion>[];

    for (final resp in doc.findAllElements('response', namespaceUri: '*')) {
      final href = resp.findElements('href', namespaceUri: '*').firstOrNull?.innerText;
      if (href == null) continue;

      final segs = Uri.parse(href).pathSegments.where((s) => s.isNotEmpty).toList();
      // Сама папка версий идёт первой записью — своего сегмента у неё нет.
      if (segs.length <= rootDepth) continue;
      final id = segs.last;

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

      out.add(FileVersion(
        id: id,
        size: int.tryParse(text('getcontentlength') ?? '') ?? 0,
        savedAt: _parseDate(text('getlastmodified')),
        label: text('version-label'),
        mimeType: text('getcontenttype'),
      ));
    }
    return out;
  }

  @override
  Future<List<TrashItem>> listTrash() async {
    _require(account.provider.hasTrash, 'Корзина сервера');
    final uri = trashUri(['trash']);
    final res = await _send('PROPFIND', uri,
        headers: {'Depth': '1', 'Content-Type': 'application/xml; charset=utf-8'},
        body: utf8.encode(_trashBody));

    // Корзина может быть выключена на сервере — это не ошибка клиента.
    if (res.statusCode == 404) {
      throw NextcloudException('Корзина на сервере недоступна: приложение '
          '«Deleted files» выключено');
    }
    if (res.statusCode != 207) throw NextcloudException.fromStatus(res.statusCode, uri);

    final items = parseTrash(res.bodyBytes, _trashRoot.length + 1);
    items.sort((a, b) =>
        (b.deletedAt ?? DateTime(0)).compareTo(a.deletedAt ?? DateTime(0)));
    return items;
  }

  /// Возврат файла на исходное место. Сервер сам знает, куда: путь хранится
  /// в свойстве записи, а restore — виртуальная папка, а не настоящая.
  @override
  Future<void> restoreFromTrash(TrashItem item) async {
    final uri = trashUri(['trash', item.id]);
    final res = await _send('MOVE', uri, headers: {
      'Destination': trashUri(['restore', item.id]).toString(),
      'Overwrite': 'F',
    });
    if (res.statusCode != 201 && res.statusCode != 204) {
      throw NextcloudException.fromStatus(res.statusCode, uri);
    }
  }

  /// Удаление насовсем: после него файла нет нигде.
  @override
  Future<void> deleteFromTrash(TrashItem item) async {
    final uri = trashUri(['trash', item.id]);
    final res = await _send('DELETE', uri);
    if (res.statusCode != 204 && res.statusCode != 200) {
      throw NextcloudException.fromStatus(res.statusCode, uri);
    }
  }

  /// Очистить корзину целиком.
  @override
  Future<void> emptyTrash() async {
    final uri = trashUri(['trash']);
    final res = await _send('DELETE', uri);
    if (res.statusCode != 204 && res.statusCode != 200) {
      throw NextcloudException.fromStatus(res.statusCode, uri);
    }
  }

  List<String> get _trashRoot =>
      [..._basePrefix, 'remote.php', 'dav', 'trashbin', account.loginName];

  /// Разбор ответа корзины. Отдельно от [parseMultistatus]: свойства другие,
  /// а показывать надо не служебное имя вида «отчёт.pdf.d1757...», а настоящее.
  @visibleForTesting
  static List<TrashItem> parseTrash(Uint8List bytes, int rootDepth) {
    final doc = XmlDocument.parse(utf8.decode(bytes));
    final out = <TrashItem>[];

    for (final resp in doc.findAllElements('response', namespaceUri: '*')) {
      final href = resp.findElements('href', namespaceUri: '*').firstOrNull?.innerText;
      if (href == null) continue;

      final segs = Uri.parse(href).pathSegments.where((s) => s.isNotEmpty).toList();
      // Сама папка trash идёт первой записью — у неё нет своего сегмента.
      if (segs.length <= rootDepth) continue;
      final id = segs.last;

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

      final original = text('trashbin-original-location') ?? '';
      final deleted = int.tryParse(text('trashbin-deletion-time') ?? '');

      out.add(TrashItem(
        id: id,
        // Если сервер не отдал настоящее имя, отрезаем служебный хвост .d<время>
        // сами — иначе в списке будет «отчёт.pdf.d1757068800».
        name: text('trashbin-filename') ?? id.replaceFirst(RegExp(r'\.d\d+$'), ''),
        originalLocation: original.replaceAll(RegExp(r'^/+'), ''),
        isDir: isDir,
        size: int.tryParse(text(isDir ? 'size' : 'getcontentlength') ?? '') ??
            int.tryParse(text('size') ?? '') ??
            0,
        deletedAt: deleted == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(deleted * 1000, isUtc: true).toLocal(),
        fileId: text('fileid'),
        mimeType: text('getcontenttype'),
      ));
    }
    return out;
  }

  /// Квота через PROPFIND корня — отдельного OCS-запроса не нужно.
  @override
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

  // ------------------------------------------------------ публичные ссылки

  static const _sharesPath = 'ocs/v2.php/apps/files_sharing/api/v1/shares';

  /// Тип доли «публичная ссылка» в OCS. Остальные типы (человеку, группе,
  /// в федерацию) клиент пока не делает.
  static const _linkShare = 3;

  /// Публичные ссылки на один файл или папку. Пути в OCS — от корня
  /// пользователя и обязательно с ведущей косой чертой.
  @override
  Future<List<PublicLink>> listLinks(String path) async {
    _require(account.provider.hasShares, 'Публичные ссылки');
    final uri = ocsUri(_sharesPath, {'path': '/$path', 'reshares': 'false'});
    final data = await _ocsData(uri, 'GET');
    if (data is! List) return const [];

    return data
        .cast<Map<String, dynamic>>()
        .where((j) => int.tryParse('${j['share_type']}') == _linkShare)
        .map(PublicLink.fromJson)
        .toList();
  }

  /// Создаёт публичную ссылку. Пароль и срок необязательны — без них ссылка
  /// открыта всем, у кого она есть, и бессрочна.
  @override
  Future<PublicLink> createLink(
    String path, {
    String? password,
    DateTime? expiresAt,
    bool allowUpload = false,
  }) async {
    final form = <String, String>{
      'path': '/$path',
      'shareType': '$_linkShare',
      'permissions': '${allowUpload ? PublicLink.readWrite : PublicLink.read}',
      if (password != null && password.isNotEmpty) 'password': password,
      if (expiresAt != null) 'expireDate': _ocsDate(expiresAt),
    };

    final data = await _ocsData(ocsUri(_sharesPath), 'POST', form: form);
    if (data is! Map<String, dynamic>) {
      throw NextcloudException('Сервер не вернул созданную ссылку');
    }
    return PublicLink.fromJson(data);
  }

  /// Меняет уже созданную ссылку. Пустой пароль снимает защиту, пустой
  /// срок — снимает ограничение по времени.
  Future<void> updateLink(
    String id, {
    String? password,
    DateTime? expiresAt,
    bool? allowUpload,
    bool clearExpiry = false,
  }) async {
    final form = <String, String>{
      'password': ?password,
      if (clearExpiry) 'expireDate': '',
      if (expiresAt != null) 'expireDate': _ocsDate(expiresAt),
      if (allowUpload != null)
        'permissions': '${allowUpload ? PublicLink.readWrite : PublicLink.read}',
    };
    if (form.isEmpty) return;
    await _ocsData(ocsUri('$_sharesPath/$id'), 'PUT', form: form);
  }

  @override
  Future<void> deleteLink(String id) async {
    await _ocsData(ocsUri('$_sharesPath/$id'), 'DELETE');
  }

  /// OCS хочет дату вида ГГГГ-ММ-ДД и понимает её по своему часовому поясу.
  static String _ocsDate(DateTime when) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${when.year}-${two(when.month)}-${two(when.day)}';
  }

  /// Общая часть всех вызовов OCS: разобрать конверт и вытащить из него
  /// либо данные, либо внятную ошибку. Свой статус OCS кладёт внутрь тела,
  /// а снаружи может стоять бодрое 200 — поэтому смотрим и туда, и туда.
  Future<dynamic> _ocsData(Uri uri, String method, {Map<String, String>? form}) async {
    final req = http.Request(method, uri)..headers.addAll(_headers);
    if (form != null) {
      req.headers['Content-Type'] = 'application/x-www-form-urlencoded; charset=utf-8';
      req.bodyFields = form;
    }

    final http.Response res;
    try {
      res = await http.Response.fromStream(await _inner.send(req));
    } on SocketException catch (e) {
      throw NextcloudException('Сервер недоступен: ${e.message}', uri: uri);
    }

    if (res.statusCode == 401 || res.statusCode == 403) {
      throw NextcloudException.fromStatus(res.statusCode, uri);
    }

    final Map<String, dynamic> body;
    try {
      body = (jsonDecode(utf8.decode(res.bodyBytes)) as Map)['ocs'] as Map<String, dynamic>;
    } catch (_) {
      throw NextcloudException(
        res.statusCode == 404
            ? 'Общий доступ на сервере выключен или недоступен этой записи'
            : 'Сервер ответил не по правилам OCS',
        uri: uri,
      );
    }

    final meta = body['meta'] as Map<String, dynamic>? ?? const {};
    final code = int.tryParse('${meta['statuscode']}') ?? 0;
    // 100 — старое «хорошо», 200 — новое; оба означают успех.
    if (code != 100 && code != 200) {
      final message = (meta['message'] as String?)?.trim();
      throw NextcloudException(
        message == null || message.isEmpty ? 'Сервер отказал (код $code)' : message,
        statusCode: code,
        uri: uri,
      );
    }
    return body['data'];
  }

  /// Отказ там, где облако такого не умеет. Лучше внятная фраза, чем
  /// невнятный ответ сервера на запрос, которого он не ждал.
  void _require(bool available, String what) {
    if (available) return;
    throw NextcloudException(
      '$what — расширение Nextcloud. ${account.provider.label} такого не умеет.',
    );
  }

  /// Проверка учётных данных: заодно достаём отображаемое имя.
  @override
  Future<String> verify() async {
    // Отображаемое имя отдаёт OCS, а он есть только у Nextcloud. У прочих
    // за имя сходит логин — это честнее, чем показывать пустоту.
    if (!account.provider.hasShares) return account.loginName;

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
  @override
  Future<Uint8List?> preview(String fileId, {int size = 256}) async {
    if (!account.provider.hasPreviews) return null;
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
