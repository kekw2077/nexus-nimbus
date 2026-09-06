import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../core/models/public_link.dart';
import '../../core/models/remote_file.dart';
import '../../core/models/trash_item.dart';
import '../storage_backend.dart';
import '../webdav_client.dart'
    show CancelToken, CancelledException, NextcloudException, NxAccount, ProgressCallback, WebDavClient;

/// Яндекс.Диск поверх REST API (`cloud-api.yandex.net`).
///
/// WebDAV у Яндекса оставлен платным подпискам и бесплатным записям
/// отвечает кодом 402, поэтому работаем по REST. Он и удобнее: адресация
/// путевая, как у нас, есть корзина и публичные ссылки.
///
/// Своя особенность здесь одна: скачивание и выгрузка идут в два шага.
/// Сначала API отдаёт одноразовый адрес, и только потом по нему течёт
/// содержимое — сам API байты не носит.
class YandexDiskClient extends StorageBackend {
  YandexDiskClient(this._account, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final NxAccount _account;
  final http.Client _http;

  @override
  NxAccount get account => _account;

  static final _api = Uri.parse('https://cloud-api.yandex.net/v1/disk');

  /// Сколько записей просим за раз. По умолчанию API отдаёт двадцать —
  /// на папке в тысячу файлов это полсотни запросов вместо пяти.
  static const _page = 200;

  /// Поля, которые нужны списку. Без ограничения API присылает вдвое больше.
  static const _fields = 'name,path,type,size,modified,md5,mime_type,'
      'preview,public_url,_embedded.items.name,_embedded.items.path,'
      '_embedded.items.type,_embedded.items.size,_embedded.items.modified,'
      '_embedded.items.md5,_embedded.items.mime_type,_embedded.items.preview,'
      '_embedded.items.public_url,_embedded.total,_embedded.offset';

  Map<String, String> get _headers => {
        // Токен лежит там же, где пароли приложений у прочих облаков.
        'Authorization': 'OAuth ${_account.appPassword}',
        'Accept': 'application/json',
      };

  @override
  void close() => _http.close();

  // ------------------------------------------------------------------ пути

  /// Путь в понятиях Диска: `disk:/папка/файл`. Корень — `disk:/`.
  static String _diskPath(String path) {
    final clean = path.replaceAll(RegExp(r'^/+|/+$'), '');
    return clean.isEmpty ? 'disk:/' : 'disk:/$clean';
  }

  /// Обратно: из `disk:/папка/файл` в путь, которым живёт приложение.
  static String _appPath(String diskPath) => diskPath
      .replaceFirst(RegExp(r'^(disk|trash):/+'), '')
      .replaceAll(RegExp(r'^/+|/+$'), '');

  // ------------------------------------------------------------ перечисление

  @override
  Future<List<RemoteFile>> list(String path) async {
    final out = <RemoteFile>[];
    var offset = 0;

    while (true) {
      final j = await _get('resources', {
        'path': _diskPath(path),
        'limit': '$_page',
        'offset': '$offset',
        'fields': _fields,
      });

      final embedded = j['_embedded'] as Map<String, dynamic>?;
      if (embedded == null) break;

      final items = (embedded['items'] as List<dynamic>? ?? const []);
      for (final raw in items) {
        out.add(_toRemote(raw as Map<String, dynamic>));
      }

      final total = (embedded['total'] as num?)?.toInt() ?? out.length;
      offset += items.length;
      if (items.isEmpty || offset >= total) break;
    }

    return out..sort(WebDavClient.byFolderThenName);
  }

  @override
  Future<RemoteFile> stat(String path) async {
    // Содержимое папки здесь не нужно — просим ноль записей.
    final j = await _get('resources', {
      'path': _diskPath(path),
      'limit': '0',
      'fields': 'name,path,type,size,modified,md5,mime_type,preview,public_url',
    });
    return _toRemote(j);
  }

  RemoteFile _toRemote(Map<String, dynamic> j) {
    final isDir = j['type'] == 'dir';
    return RemoteFile(
      path: _appPath('${j['path'] ?? ''}'),
      isDir: isDir,
      size: (j['size'] as num?)?.toInt() ?? 0,
      modified: DateTime.tryParse('${j['modified'] ?? ''}')?.toLocal(),
      // md5 меняется вместе с содержимым — ровно то, что нужно синхронизации.
      // У папок его нет, и там за признак изменения сходит время правки.
      etag: (j['md5'] as String?) ?? '${j['modified'] ?? ''}',
      // Идентификатора у Диска нет: путь и есть адрес. Кладём путь, чтобы
      // миниатюры и «открыть на сервере» знали, о чём речь.
      fileId: isDir ? null : _appPath('${j['path'] ?? ''}'),
      mimeType: j['mime_type'] as String?,
      hasPreview: j['preview'] != null,
      // Публичная ссылка приходит вместе с записью — по ней и видно,
      // что на файл кто-то может зайти со стороны.
      permissions: j['public_url'] == null ? '' : 'S',
    );
  }

  // -------------------------------------------------------------- операции

  @override
  Future<void> mkdir(String path) async {
    await _send('PUT', 'resources', {'path': _diskPath(path)});
  }

  @override
  Future<void> delete(String path) async {
    // permanently=false — в корзину Диска, откуда файл ещё можно достать.
    await _send('DELETE', 'resources', {
      'path': _diskPath(path),
      'permanently': 'false',
    });
  }

  @override
  Future<void> move(String from, String to, {bool overwrite = false}) =>
      _transfer('move', from, to, overwrite);

  @override
  Future<void> copy(String from, String to, {bool overwrite = false}) =>
      _transfer('copy', from, to, overwrite);

  Future<void> _transfer(String what, String from, String to, bool overwrite) async {
    await _send('POST', 'resources/$what', {
      'from': _diskPath(from),
      'path': _diskPath(to),
      'overwrite': '$overwrite',
    });
  }

  // -------------------------------------------------------------- передачи

  /// Одноразовый адрес, по которому течёт содержимое. Сам API байты не носит:
  /// он только говорит, куда идти.
  Future<Uri> _href(String endpoint, Map<String, String> query) async {
    final j = await _get(endpoint, query);
    final href = j['href'] as String?;
    if (href == null || href.isEmpty) {
      throw NextcloudException('Диск не сказал, откуда брать содержимое');
    }
    return Uri.parse(href);
  }

  @override
  Future<({Stream<List<int>> stream, int length})> openRead(String path) async {
    final href = await _href('resources/download', {'path': _diskPath(path)});

    // Адрес одноразовый и уже содержит подпись — заголовок авторизации
    // здесь не нужен и на некоторых узлах мешает.
    final res = await _http.send(http.Request('GET', href));
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
    final length = await source.length();
    final href = await _href('resources/upload', {
      'path': _diskPath(path),
      'overwrite': 'true',
    });

    final req = http.StreamedRequest('PUT', href)..contentLength = length;

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
    await res.stream.drain<void>();
    if (cancel?.isCancelled ?? false) throw const CancelledException();
    if (res.statusCode != 201 && res.statusCode != 202) {
      throw NextcloudException('Диск отказал при выгрузке (${res.statusCode})');
    }
  }

  // ---------------------------------------------------------------- корзина

  @override
  Future<List<TrashItem>> listTrash() async {
    final out = <TrashItem>[];
    var offset = 0;

    while (true) {
      final j = await _get('trash/resources', {
        'path': 'trash:/',
        'limit': '$_page',
        'offset': '$offset',
      });

      final embedded = j['_embedded'] as Map<String, dynamic>?;
      if (embedded == null) break;
      final items = (embedded['items'] as List<dynamic>? ?? const []);

      for (final raw in items) {
        final item = raw as Map<String, dynamic>;
        final deleted = DateTime.tryParse('${item['deleted'] ?? ''}');
        out.add(TrashItem(
          // В корзине Диска адрес — тоже путь, только в своём дереве.
          id: '${item['path'] ?? ''}',
          name: '${item['name'] ?? ''}',
          originalLocation: _appPath('${item['origin_path'] ?? ''}'),
          isDir: item['type'] == 'dir',
          size: (item['size'] as num?)?.toInt() ?? 0,
          deletedAt: deleted?.toLocal(),
          mimeType: item['mime_type'] as String?,
        ));
      }

      final total = (embedded['total'] as num?)?.toInt() ?? out.length;
      offset += items.length;
      if (items.isEmpty || offset >= total) break;
    }
    return out;
  }

  @override
  Future<void> restoreFromTrash(TrashItem item) async {
    await _send('PUT', 'trash/resources/restore', {'path': item.id});
  }

  @override
  Future<void> deleteFromTrash(TrashItem item) async {
    await _send('DELETE', 'trash/resources', {'path': item.id});
  }

  @override
  Future<void> emptyTrash() async {
    await _send('DELETE', 'trash/resources', {'path': 'trash:/'});
  }

  // -------------------------------------------------------- публичные ссылки

  @override
  Future<List<PublicLink>> listLinks(String path) async {
    final entry = await _get('resources', {
      'path': _diskPath(path),
      'limit': '0',
      'fields': 'public_url',
    });

    final url = entry['public_url'] as String?;
    if (url == null || url.isEmpty) return const [];
    // Ссылка у Диска одна на запись, и адресуется она путём.
    return [PublicLink(id: path, url: url)];
  }

  @override
  Future<PublicLink> createLink(
    String path, {
    String? password,
    DateTime? expiresAt,
    bool allowUpload = false,
  }) async {
    await _send('PUT', 'resources/publish', {'path': _diskPath(path)});

    final links = await listLinks(path);
    if (links.isEmpty) {
      throw NextcloudException('Диск не вернул публичную ссылку');
    }
    return links.first;
  }

  @override
  Future<void> deleteLink(String id) async {
    // Идентификатор ссылки у Диска — путь записи, на которую она ведёт.
    await _send('PUT', 'resources/unpublish', {'path': _diskPath(id)});
  }

  // ---------------------------------------------------------------- прочее

  @override
  Future<Uint8List?> preview(String fileId, {int size = 256}) async {
    try {
      final j = await _get('resources', {
        'path': _diskPath(fileId),
        'limit': '0',
        'fields': 'preview',
        'preview_size': '${size}x',
        'preview_crop': 'true',
      });
      final href = j['preview'] as String?;
      if (href == null || href.isEmpty) return null;

      // Миниатюру Диск отдаёт по токену, а не по подписанному адресу.
      final res = await _http.get(Uri.parse(href), headers: _headers);
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;
      return res.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Quota> quota() async {
    final j = await _get('', {});
    final used = (j['used_space'] as num?)?.toInt() ?? 0;
    final total = (j['total_space'] as num?)?.toInt() ?? 0;
    return Quota(used: used, total: total);
  }

  @override
  Future<String> verify() async {
    await quota();
    return _account.loginName;
  }

  @override
  Uri? webUrl(RemoteFile file) {
    final where = file.isDir ? file.path : p.url.dirname(file.path);
    return Uri.parse('https://disk.yandex.ru/client/disk')
        .replace(path: '/client/disk/${where == '.' ? '' : where}');
  }

  // ------------------------------------------------------------- запросы

  Uri _uri(String endpoint, Map<String, String> query) {
    final path = endpoint.isEmpty
        ? _api.pathSegments
        : [..._api.pathSegments, ...endpoint.split('/')];
    return _api.replace(
      pathSegments: path,
      queryParameters: query.isEmpty ? null : query,
    );
  }

  Future<Map<String, dynamic>> _get(String endpoint, Map<String, String> query) async {
    final res = await _http.get(_uri(endpoint, query), headers: _headers);
    return _body(res);
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String endpoint,
    Map<String, String> query,
  ) async {
    final req = http.Request(method, _uri(endpoint, query))..headers.addAll(_headers);
    final res = await http.Response.fromStream(await _http.send(req));
    final body = _body(res);

    // Перенос и удаление большой папки Диск делает в фоне и отвечает 202
    // со ссылкой на ход работы. Дожидаемся конца, иначе список файлов
    // обновится раньше, чем операция доедет.
    if (res.statusCode == 202) await _awaitOperation(body['href'] as String?);
    return body;
  }

  Future<void> _awaitOperation(String? href) async {
    if (href == null || href.isEmpty) return;
    final uri = Uri.parse(href);

    // Больше минуты такие операции у Диска не занимают; если занимают —
    // ждать дальше бессмысленно, список всё равно обновится следующим разом.
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      final res = await _http.get(uri, headers: _headers);
      final status = _body(res)['status'];
      if (status == 'success') return;
      if (status == 'failed') {
        throw NextcloudException('Диск не смог выполнить операцию');
      }
    }
  }

  Map<String, dynamic> _body(http.Response res) {
    if (res.statusCode == 401) {
      throw NextcloudException(
        'Яндекс не принял токен. Скорее всего, доступ отозван — войдите заново.',
      );
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw NextcloudException(_error(res));
    }
    if (res.bodyBytes.isEmpty) return const {};
    try {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }

  String _error(http.Response res) {
    try {
      final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final message = (j['message'] ?? j['description']) as String?;
      if (message != null && message.isNotEmpty) return 'Диск: $message';
    } catch (_) {}
    return 'Диск отказал (${res.statusCode})';
  }
}
