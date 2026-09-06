import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../core/models/remote_file.dart';
import '../storage_backend.dart';
import '../webdav_client.dart'
    show
        CancelToken,
        CancelledException,
        NextcloudException,
        NxAccount,
        ProgressCallback,
        WebDavClient;
import 'google_auth.dart';

/// Google Drive поверх Drive API v3.
///
/// Главная разница с WebDAV: **у Диска нет путей**. Файл адресуется
/// идентификатором, папка — это файл с особым типом, а имена внутри папки
/// не уникальны. Всё приложение при этом путевое, поэтому клиент держит
/// перевод «путь → идентификатор» и кэш к нему: без кэша открытие вложенной
/// папки стоило бы по запросу на каждый уровень.
///
/// Вторая разница: документы, таблицы и презентации Google — **не файлы**.
/// У них нет содержимого, только запись в базе; скачать их нельзя. Такие
/// записи помечаются типом `application/vnd.google-apps.*`, показываются без
/// размера, и единственное, что с ними можно сделать, — открыть в браузере.
class GoogleDriveClient extends StorageBackend {
  GoogleDriveClient(this._account, this._auth, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final NxAccount _account;
  final GoogleAuth _auth;
  final http.Client _http;

  @override
  NxAccount get account => _account;

  static final _api = Uri.parse('https://www.googleapis.com/drive/v3/files');
  static final _upload = Uri.parse('https://www.googleapis.com/upload/drive/v3/files');

  static const _folderType = 'application/vnd.google-apps.folder';

  /// Родовой признак документов Google: содержимого у них нет.
  static const _nativePrefix = 'application/vnd.google-apps.';

  static bool isNativeDoc(String? mimeType) =>
      mimeType != null && mimeType.startsWith(_nativePrefix) && mimeType != _folderType;

  /// Поля, которые спрашиваем про каждую запись. Drive по умолчанию отдаёт
  /// только id и имя, поэтому список обязателен.
  static const _fields = 'id,name,mimeType,size,modifiedTime,md5Checksum,trashed';

  // ------------------------------------------------------------------ токен

  String? _token;
  DateTime? _tokenUntil;

  Future<String> _accessToken() async {
    final until = _tokenUntil;
    final token = _token;
    if (token != null && until != null && DateTime.now().isBefore(until)) {
      return token;
    }
    // Пароль приложения у этой записи — токен обновления: он и есть то,
    // что мы храним между запусками.
    final fresh = await _auth.refresh(_account.appPassword);
    _token = fresh.token;
    _tokenUntil = fresh.expiresAt;
    return fresh.token;
  }

  Future<Map<String, String>> _headers() async => {
        'Authorization': 'Bearer ${await _accessToken()}',
      };

  @override
  void close() {
    _http.close();
    _auth.close();
  }

  // ----------------------------------------------------- путь ↔ идентификатор

  /// Идентификаторы папок по пути. Корень известен всегда.
  final Map<String, String> _folders = {'': 'root'};

  String _norm(String path) => path.replaceAll(RegExp(r'^/+|/+$'), '');

  /// Идентификатор папки по пути. Идём сверху вниз, запоминая по дороге.
  Future<String> _folderId(String path) async {
    final target = _norm(path);
    final known = _folders[target];
    if (known != null) return known;

    var parentId = 'root';
    var walked = '';
    for (final segment in target.split('/').where((s) => s.isNotEmpty)) {
      walked = walked.isEmpty ? segment : '$walked/$segment';
      final cached = _folders[walked];
      if (cached != null) {
        parentId = cached;
        continue;
      }

      final found = await _childByName(parentId, segment, folderOnly: true);
      if (found == null) {
        throw NextcloudException('Папки «$walked» на Диске нет');
      }
      parentId = found['id'] as String;
      _folders[walked] = parentId;
    }
    return parentId;
  }

  /// Запись по полному пути — файл или папка.
  Future<Map<String, dynamic>> _entry(String path) async {
    final target = _norm(path);
    if (target.isEmpty) {
      return {'id': 'root', 'name': '', 'mimeType': _folderType};
    }

    final parent = await _folderId(p.url.dirname(target) == '.' ? '' : p.url.dirname(target));
    final found = await _childByName(parent, p.url.basename(target));
    if (found == null) throw NextcloudException('«$target» на Диске нет');
    return found;
  }

  Future<Map<String, dynamic>?> _childByName(
    String parentId,
    String name, {
    bool folderOnly = false,
  }) async {
    final q = [
      "'$parentId' in parents",
      "name = '${_escape(name)}'",
      'trashed = false',
      if (folderOnly) "mimeType = '$_folderType'",
    ].join(' and ');

    final j = await _get(_api.replace(queryParameters: {
      'q': q,
      'fields': 'files($_fields)',
      'pageSize': '2',
      'supportsAllDrives': 'true',
    }));

    final files = (j['files'] as List<dynamic>? ?? const []);
    return files.isEmpty ? null : files.first as Map<String, dynamic>;
  }

  /// Кавычка в имени рвёт запрос Drive — экранируем её и обратный слэш.
  static String _escape(String v) =>
      v.replaceAll('\\', r'\\').replaceAll("'", r"\'");

  /// Забыть путь и всё, что под ним: после переименования или удаления
  /// прежние идентификаторы указывают не туда.
  void _forget(String path) {
    final target = _norm(path);
    _folders.removeWhere((key, _) => key == target || key.startsWith('$target/'));
  }

  // ------------------------------------------------------------- перечисление

  @override
  Future<List<RemoteFile>> list(String path) async {
    final dir = _norm(path);
    final parentId = await _folderId(dir);

    final out = <RemoteFile>[];
    String? pageToken;
    do {
      final j = await _get(_api.replace(queryParameters: {
        'q': "'$parentId' in parents and trashed = false",
        'fields': 'nextPageToken,files($_fields)',
        'pageSize': '1000',
        'orderBy': 'folder,name',
        'supportsAllDrives': 'true',
        'pageToken': ?pageToken,
      }));

      for (final raw in (j['files'] as List<dynamic>? ?? const [])) {
        final entry = raw as Map<String, dynamic>;
        final file = _toRemote(entry, dir);
        out.add(file);
        // Папки запоминаем сразу: следующий заход внутрь обойдётся без поиска.
        final id = entry['id'] as String?;
        if (file.isDir && id != null) _folders[file.path] = id;
      }
      pageToken = j['nextPageToken'] as String?;
    } while (pageToken != null);

    return out..sort(WebDavClient.byFolderThenName);
  }

  @override
  Future<RemoteFile> stat(String path) async {
    final dir = _norm(path);
    final entry = await _entry(dir);
    final parent = p.url.dirname(dir);
    return _toRemote(entry, parent == '.' ? '' : parent);
  }

  RemoteFile _toRemote(Map<String, dynamic> j, String parentPath) {
    final name = (j['name'] as String?) ?? '';
    final mime = j['mimeType'] as String?;
    final isDir = mime == _folderType;
    final path = parentPath.isEmpty ? name : '$parentPath/$name';

    return RemoteFile(
      path: path,
      isDir: isDir,
      // У документов Google размера нет вовсе — сервер его не присылает.
      size: int.tryParse('${j['size'] ?? ''}') ?? 0,
      modified: DateTime.tryParse('${j['modifiedTime'] ?? ''}')?.toLocal(),
      // Контрольная сумма меняется вместе с содержимым — ровно то, для чего
      // синхронизации нужен etag. У документов Google её нет, и там за
      // признак изменения сходит время правки.
      etag: (j['md5Checksum'] as String?) ?? '${j['modifiedTime'] ?? ''}',
      fileId: j['id'] as String?,
      mimeType: mime,
      hasPreview: false,
    );
  }

  // -------------------------------------------------------------- операции

  @override
  Future<void> mkdir(String path) async {
    final dir = _norm(path);
    final parentPath = p.url.dirname(dir);
    final parentId = await _folderId(parentPath == '.' ? '' : parentPath);

    final j = await _post(_api.replace(queryParameters: {
      'fields': 'id',
      'supportsAllDrives': 'true',
    }), {
      'name': p.url.basename(dir),
      'mimeType': _folderType,
      'parents': [parentId],
    });
    _folders[dir] = j['id'] as String;
  }

  @override
  Future<void> delete(String path) async {
    final entry = await _entry(path);
    // В корзину, а не насовсем: то же, что делает DELETE у Nextcloud.
    await _patch(entry['id'] as String, {'trashed': true});
    _forget(path);
  }

  @override
  Future<void> move(String from, String to, {bool overwrite = false}) async {
    final entry = await _entry(from);
    final id = entry['id'] as String;

    final fromDir = p.url.dirname(_norm(from));
    final toDir = p.url.dirname(_norm(to));
    final sameFolder = fromDir == toDir;

    final oldParent = await _folderId(fromDir == '.' ? '' : fromDir);
    final newParent = sameFolder ? oldParent : await _folderId(toDir == '.' ? '' : toDir);

    await _patch(
      id,
      {'name': p.url.basename(_norm(to))},
      query: sameFolder
          ? null
          : {'addParents': newParent, 'removeParents': oldParent},
    );
    _forget(from);
    _forget(to);
  }

  @override
  Future<void> copy(String from, String to, {bool overwrite = false}) async {
    final entry = await _entry(from);
    if (entry['mimeType'] == _folderType) {
      // Drive не копирует папки одним вызовом, а обходить дерево здесь —
      // значит молча наделать сотню запросов. Честнее отказать.
      throw NextcloudException(
        'Google Drive не умеет копировать папку целиком одним действием. '
        'Скопируйте файлы внутри неё.',
      );
    }

    final toDir = p.url.dirname(_norm(to));
    final parentId = await _folderId(toDir == '.' ? '' : toDir);
    await _post(
      _api.replace(
        pathSegments: [..._api.pathSegments, entry['id'] as String, 'copy'],
        queryParameters: {'fields': 'id', 'supportsAllDrives': 'true'},
      ),
      {
        'name': p.url.basename(_norm(to)),
        'parents': [parentId],
      },
    );
  }

  // -------------------------------------------------------------- передачи

  @override
  Future<({Stream<List<int>> stream, int length})> openRead(String path) async {
    final entry = await _entry(path);
    if (isNativeDoc(entry['mimeType'] as String?)) {
      throw NextcloudException(_nativeExcuse(entry['name'] as String? ?? ''));
    }

    final uri = _api.replace(
      pathSegments: [..._api.pathSegments, entry['id'] as String],
      queryParameters: {'alt': 'media', 'supportsAllDrives': 'true'},
    );
    final req = http.Request('GET', uri)..headers.addAll(await _headers());
    final res = await _http.send(req);
    if (res.statusCode != 200) {
      throw NextcloudException('Диск отказал при скачивании (${res.statusCode})');
    }
    return (stream: res.stream, length: res.contentLength ?? 0);
  }

  @override
  Future<void> download(
    String path,
    File target, {
    ProgressCallback? onProgress,
    CancelToken? cancel,
    Uri? from,
  }) async {
    final source = await openRead(path);

    var done = 0;
    await target.parent.create(recursive: true);
    final part = File('${target.path}.nxpart');
    final sink = part.openWrite();
    var closed = false;
    try {
      await for (final chunk in source.stream) {
        if (cancel?.isCancelled ?? false) throw const CancelledException();
        sink.add(chunk);
        done += chunk.length;
        onProgress?.call(done, source.length);
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

  @override
  Future<void> upload(
    File source,
    String path, {
    ProgressCallback? onProgress,
    CancelToken? cancel,
  }) async {
    final target = _norm(path);
    final length = await source.length();

    // Есть ли уже такой файл: от этого зависит, создаём мы запись или
    // переписываем содержимое существующей.
    final dir = p.url.dirname(target);
    final parentId = await _folderId(dir == '.' ? '' : dir);
    final existing = await _childByName(parentId, p.url.basename(target));

    final session = await _startResumable(
      name: p.url.basename(target),
      parentId: parentId,
      existingId: existing?['id'] as String?,
      length: length,
      mimeType: existing?['mimeType'] as String?,
    );

    final req = http.StreamedRequest('PUT', session);
    req.headers['Content-Type'] = 'application/octet-stream';
    req.contentLength = length;

    var done = 0;
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

    final res = await _http.send(req);
    if (cancel?.isCancelled ?? false) throw const CancelledException();
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw NextcloudException('Диск отказал при выгрузке (${res.statusCode})');
    }
    await res.stream.drain<void>();
  }

  /// Открывает сеанс выгрузки. Drive отвечает адресом, в который дальше
  /// льётся содержимое, — так большой файл не нужно держать в памяти.
  Future<Uri> _startResumable({
    required String name,
    required String parentId,
    required String? existingId,
    required int length,
    String? mimeType,
  }) async {
    final uri = existingId == null
        ? _upload.replace(queryParameters: {
            'uploadType': 'resumable',
            'supportsAllDrives': 'true',
          })
        : _upload.replace(
            pathSegments: [..._upload.pathSegments, existingId],
            queryParameters: {
              'uploadType': 'resumable',
              'supportsAllDrives': 'true',
            },
          );

    // При обновлении имя и родителя не шлём: Drive считает это переносом.
    final metadata = existingId == null
        ? {
            'name': name,
            'parents': [parentId],
          }
        : <String, dynamic>{};

    final res = await _http.send(
      http.Request(existingId == null ? 'POST' : 'PATCH', uri)
        ..headers.addAll({
          ...await _headers(),
          'Content-Type': 'application/json; charset=utf-8',
          'X-Upload-Content-Length': '$length',
        })
        ..body = jsonEncode(metadata),
    );
    await res.stream.drain<void>();

    if (res.statusCode != 200) {
      throw NextcloudException('Диск не открыл выгрузку (${res.statusCode})');
    }
    final location = res.headers['location'];
    if (location == null) {
      throw NextcloudException('Диск не сказал, куда лить содержимое');
    }
    return Uri.parse(location);
  }

  // ---------------------------------------------------------------- прочее

  @override
  Future<Quota> quota() async {
    final j = await _get(Uri.parse(
        'https://www.googleapis.com/drive/v3/about?fields=storageQuota'));
    final q = j['storageQuota'] as Map<String, dynamic>? ?? const {};

    final used = int.tryParse('${q['usage'] ?? 0}') ?? 0;
    final limit = int.tryParse('${q['limit'] ?? ''}') ?? 0;
    // limit не пришёл — значит место не ограничено (бывает у Workspace).
    return Quota(used: used, total: limit);
  }

  @override
  Future<String> verify() async {
    // Один запрос к about заодно проверяет и токен, и доступ к Диску.
    await quota();
    return _account.loginName;
  }

  @override
  Uri? webUrl(RemoteFile file) {
    final id = file.fileId;
    if (id == null) return null;
    return Uri.parse('https://drive.google.com/open?id=$id');
  }

  /// Почему документ Google нельзя скачать. Фраза одна на все места, чтобы
  /// объяснение не расходилось.
  static String _nativeExcuse(String name) =>
      '«$name» — документ Google: содержимого у него нет, только запись в '
      'базе. Скачать его нельзя, откройте на сервере.';

  // ------------------------------------------------------------- запросы

  Future<Map<String, dynamic>> _get(Uri uri) async {
    final res = await _http.get(uri, headers: await _headers());
    return _body(res);
  }

  Future<Map<String, dynamic>> _post(Uri uri, Map<String, dynamic> body) async {
    final res = await _http.post(
      uri,
      headers: {...await _headers(), 'Content-Type': 'application/json; charset=utf-8'},
      body: jsonEncode(body),
    );
    return _body(res);
  }

  Future<Map<String, dynamic>> _patch(
    String id,
    Map<String, dynamic> body, {
    Map<String, String>? query,
  }) async {
    final uri = _api.replace(
      pathSegments: [..._api.pathSegments, id],
      queryParameters: {
        'fields': 'id',
        'supportsAllDrives': 'true',
        ...?query,
      },
    );
    final res = await _http.patch(
      uri,
      headers: {...await _headers(), 'Content-Type': 'application/json; charset=utf-8'},
      body: jsonEncode(body),
    );
    return _body(res);
  }

  Map<String, dynamic> _body(http.Response res) {
    if (res.statusCode == 401) {
      // Токен протух посреди работы — следующий запрос возьмёт свежий.
      _token = null;
      _tokenUntil = null;
      throw NextcloudException('Google не принял токен — попробуйте ещё раз');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw NextcloudException(_error(res));
    }
    if (res.bodyBytes.isEmpty) return const {};
    try {
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      return const {};
    }
  }

  String _error(http.Response res) {
    try {
      final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final message = (j['error'] as Map<String, dynamic>?)?['message'] as String?;
      if (message != null && message.isNotEmpty) return 'Диск: $message';
    } catch (_) {}
    return 'Диск отказал (${res.statusCode})';
  }
}
