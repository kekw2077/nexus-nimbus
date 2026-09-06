import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/edit_watcher.dart';
import '../services/google/drive_client.dart';
import '../services/storage_backend.dart';
import '../services/sync_engine.dart';
import '../services/thumbnail_cache.dart';
import '../services/transfer_queue.dart';
import '../services/vault.dart';
import '../services/webdav_client.dart';
import 'models/remote_file.dart';

enum ViewMode { list, grid }

enum SortField { name, size, modified, kind }

/// Всё состояние подключённого клиента: где мы находимся, что видим,
/// что выделено, что качается. Один объект на приложение.
class Session extends ChangeNotifier {
  Session._(
    this.dav,
    this.vault,
    this.transfers,
    this.thumbs,
    this.edits,
    this.sync,
  );

  final StorageBackend dav;
  final Vault vault;
  final TransferQueue transfers;
  final ThumbnailCache thumbs;
  final EditWatcher edits;
  final SyncEngine sync;

  static Future<Session> create(
    NxAccount account,
    StorageBackend dav, {
    Directory? vaultRoot,
    bool autoPushEdits = true,
    bool syncEnabled = true,
    bool syncEverything = false,
    Duration syncInterval = const Duration(minutes: 5),
  }) async {
    final vault = await Vault.open(
      accountSlug: account.slug,
      customRoot: vaultRoot,
    );
    final support = await getApplicationSupportDirectory();
    final thumbs = ThumbnailCache(dav, Directory(p.join(support.path, 'thumbnails')));
    final transfers = TransferQueue(dav, vault);
    final session = Session._(
      dav,
      vault,
      transfers,
      thumbs,
      EditWatcher(vault, transfers, autoPush: autoPushEdits),
      SyncEngine(
        dav,
        vault,
        transfers,
        enabled: syncEnabled,
        everything: syncEverything,
        interval: syncInterval,
      ),
    );
    vault.addListener(session.notifyListeners);
    session.transfers.addListener(session._onTransfers);
    session.edits.addListener(session.notifyListeners);
    session.sync.addListener(session.notifyListeners);
    session.edits.sync();
    session.sync.start();
    return session;
  }

  NxAccount get account => dav.account;

  // ------------------------------------------------------------ навигация

  String _path = '';
  String get path => _path;

  final List<String> _history = [''];
  int _historyIndex = 0;

  bool get canGoBack => _historyIndex > 0;
  bool get canGoForward => _historyIndex < _history.length - 1;
  bool get canGoUp => _path.isNotEmpty;

  /// Хлебные крошки: пары «подпись → путь», начиная с корня.
  List<({String label, String path})> get breadcrumbs {
    final out = <({String label, String path})>[(label: 'Все файлы', path: '')];
    var acc = '';
    for (final seg in _path.split('/').where((s) => s.isNotEmpty)) {
      acc = acc.isEmpty ? seg : '$acc/$seg';
      out.add((label: seg, path: acc));
    }
    return out;
  }

  // ------------------------------------------------------------ состояние

  List<RemoteFile> _entries = const [];
  bool _loading = false;
  String? _error;
  Quota? _quota;

  final Set<String> _selection = {};
  String _filter = '';
  ViewMode _view = ViewMode.list;
  SortField _sort = SortField.name;
  bool _ascending = true;
  final bool _foldersFirst = true;

  bool get loading => _loading;
  String? get error => _error;
  Quota? get quota => _quota;
  Set<String> get selection => _selection;
  String get filter => _filter;
  ViewMode get view => _view;
  SortField get sort => _sort;
  bool get ascending => _ascending;

  /// Содержимое текущей папки после фильтра и сортировки.
  List<RemoteFile> get visible {
    final needle = _filter.trim().toLowerCase();
    final list = needle.isEmpty
        ? [..._entries]
        : _entries.where((f) => f.name.toLowerCase().contains(needle)).toList();

    int cmp(RemoteFile a, RemoteFile b) {
      final r = switch (_sort) {
        SortField.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        SortField.size => a.size.compareTo(b.size),
        SortField.modified => (a.modified ?? DateTime(0)).compareTo(b.modified ?? DateTime(0)),
        SortField.kind => a.extension.compareTo(b.extension),
      };
      return _ascending ? r : -r;
    }

    list.sort((a, b) {
      if (_foldersFirst && a.isDir != b.isDir) return a.isDir ? -1 : 1;
      final r = cmp(a, b);
      return r != 0 ? r : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  List<RemoteFile> get selectedFiles =>
      _entries.where((f) => _selection.contains(f.path)).toList();

  int get selectedSize => selectedFiles.fold(0, (s, f) => s + f.size);

  // ------------------------------------------------------------- действия

  Future<void> open(String target, {bool record = true}) async {
    _path = _normalize(target);
    if (record) {
      // Уход в сторону обрезает всю ветку «вперёд» — как в браузере.
      if (_historyIndex < _history.length - 1) {
        _history.removeRange(_historyIndex + 1, _history.length);
      }
      if (_history.isEmpty || _history.last != _path) {
        _history.add(_path);
        _historyIndex = _history.length - 1;
      }
    }
    _selection.clear();
    _filter = '';
    await refresh();
  }

  Future<void> goBack() async {
    if (!canGoBack) return;
    _historyIndex--;
    await open(_history[_historyIndex], record: false);
  }

  Future<void> goForward() async {
    if (!canGoForward) return;
    _historyIndex++;
    await open(_history[_historyIndex], record: false);
  }

  Future<void> goUp() async {
    if (!canGoUp) return;
    final i = _path.lastIndexOf('/');
    await open(i < 0 ? '' : _path.substring(0, i));
  }

  Future<void> refresh() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final list = await dav.list(_path);
      _entries = list;
      _error = null;
      // Сверка с диском идёт следом и не задерживает отрисовку списка.
      unawaited(vault.audit(list));
    } catch (e) {
      _entries = const [];
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
    unawaited(refreshQuota());
  }

  // ----------------------------------------------------------- избранное

  List<RemoteFile> _favorites = const [];
  bool _favoritesLoading = false;
  String? _favoritesError;

  List<RemoteFile> get favorites => _favorites;
  bool get favoritesLoading => _favoritesLoading;
  String? get favoritesError => _favoritesError;

  /// Избранное лежит на сервере и приходит отдельным запросом. Держать его
  /// постоянно свежим незачем — спрашиваем, когда его собираются смотреть.
  Future<void> refreshFavorites() async {
    _favoritesLoading = true;
    _favoritesError = null;
    notifyListeners();
    try {
      _favorites = await dav.favorites();
    } catch (e) {
      _favorites = const [];
      _favoritesError = e.toString();
    } finally {
      _favoritesLoading = false;
      notifyListeners();
    }
  }

  Future<void> setFavorite(Iterable<RemoteFile> files, bool favorite) async {
    for (final f in files) {
      await dav.setFavorite(f.path, favorite);
    }
    // Пометка живёт в свойствах записи, поэтому текущую папку перечитываем:
    // иначе звёздочка в списке осталась бы прежней.
    await refresh();
    unawaited(refreshFavorites());
  }

  Future<void> refreshQuota() async {
    try {
      _quota = await dav.quota();
      notifyListeners();
    } catch (_) {
      // Квота — украшение, из-за неё ничего ломать не будем.
    }
  }

  // ----------------------------------------------------------- выделение

  void select(String path, {bool add = false, bool toggle = false}) {
    if (toggle) {
      _selection.contains(path) ? _selection.remove(path) : _selection.add(path);
    } else if (add) {
      _selection.add(path);
    } else {
      _selection
        ..clear()
        ..add(path);
    }
    notifyListeners();
  }

  /// Выделение диапазоном (Shift) считается по видимому порядку.
  void selectRange(String anchor, String target) {
    final list = visible.map((f) => f.path).toList();
    final a = list.indexOf(anchor);
    final b = list.indexOf(target);
    if (a < 0 || b < 0) return;
    _selection.addAll(list.sublist(a < b ? a : b, (a < b ? b : a) + 1));
    notifyListeners();
  }

  void selectAll() {
    _selection
      ..clear()
      ..addAll(visible.map((f) => f.path));
    notifyListeners();
  }

  void clearSelection() {
    if (_selection.isEmpty) return;
    _selection.clear();
    notifyListeners();
  }

  // ------------------------------------------------------------- вид

  void setFilter(String value) {
    _filter = value;
    notifyListeners();
  }

  void setView(ViewMode value) {
    _view = value;
    notifyListeners();
  }

  void setSort(SortField field) {
    if (_sort == field) {
      _ascending = !_ascending;
    } else {
      _sort = field;
      _ascending = true;
    }
    notifyListeners();
  }

  // ------------------------------------------------- файловые операции

  Future<void> createFolder(String name) async {
    final target = _join(_path, name.trim());
    await dav.mkdir(target);
    await refresh();
  }

  Future<void> rename(RemoteFile file, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed == file.name) return;
    final target = _join(file.parent, trimmed);
    await dav.move(file.path, target);
    await vault.relocate(file.path, target);
    await refresh();
  }

  /// Удаление в корзину сервера — DELETE в Nextcloud не стирает насовсем.
  Future<void> deleteSelected() async {
    final victims = selectedFiles;
    for (final f in victims) {
      await dav.delete(f.path);
      await vault.evict(f.path);
    }
    _selection.clear();
    await refresh();
  }

  /// Перемещение перетаскиванием: пути [paths] уезжают внутрь [targetDir].
  Future<void> moveInto(List<String> paths, String targetDir) async {
    for (final from in paths) {
      final name = p.basename(from);
      final to = _join(targetDir, name);
      if (from == to || targetDir.startsWith('$from/')) continue;
      await dav.move(from, to);
      await vault.relocate(from, to);
    }
    _selection.clear();
    await refresh();
  }

  Future<void> copyInto(List<String> paths, String targetDir) async {
    for (final from in paths) {
      final to = _join(targetDir, p.basename(from));
      if (from == to) continue;
      await dav.copy(from, to);
    }
    await refresh();
  }

  // ----------------------------------------------------------- передачи

  /// Кладёт локальные файлы в текущую папку. Папки раскрываются рекурсивно.
  Future<void> uploadPaths(Iterable<String> localPaths, {String? into}) async {
    final target = into ?? _path;
    for (final raw in localPaths) {
      final type = FileSystemEntity.typeSync(raw);
      if (type == FileSystemEntityType.directory) {
        await _uploadDirectory(Directory(raw), _join(target, p.basename(raw)));
      } else if (type == FileSystemEntityType.file) {
        transfers.enqueueUpload(File(raw), _join(target, p.basename(raw)));
      }
    }
    notifyListeners();
  }

  Future<void> _uploadDirectory(Directory dir, String remoteDir) async {
    try {
      await dav.mkdir(remoteDir);
    } on NextcloudException catch (e) {
      // 405 — папка уже есть, это не ошибка.
      if (e.statusCode != 405) rethrow;
    }
    await for (final entity in dir.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (entity is Directory) {
        await _uploadDirectory(entity, _join(remoteDir, name));
      } else if (entity is File) {
        transfers.enqueueUpload(entity, _join(remoteDir, name));
      }
    }
  }

  /// Скачивание в локальное зеркало. Папки обходятся рекурсивно.
  Future<void> download(Iterable<RemoteFile> files, {bool pin = false}) async {
    for (final f in files) {
      if (f.isDir) {
        final children = await dav.list(f.path);
        await download(children, pin: pin);
      } else {
        final task = transfers.enqueueDownload(f);
        if (pin) {
          unawaited(_pinWhenDone(task, f.path));
        }
      }
    }
    notifyListeners();
  }

  Future<void> _pinWhenDone(TransferTask task, String path) async {
    while (task.isActive) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (task.state == TransferState.done) await vault.setPinned(path, true);
  }

  /// Закрепить файлы и папки. Папка не скачивается тут же целиком: она
  /// попадает под обход синхронизации, а он и притащит содержимое — заодно
  /// будет держать его в согласии с сервером дальше.
  Future<void> setPinned(Iterable<RemoteFile> files, bool pinned) async {
    var touchedDir = false;
    for (final f in files) {
      if (f.isDir) {
        await vault.setPinnedDir(f.path, pinned);
        touchedDir = true;
      } else if (pinned && vault.entry(f.path) == null) {
        await download([f], pin: true);
      } else {
        await vault.setPinned(f.path, pinned);
      }
    }
    if (touchedDir && pinned) unawaited(sync.syncNow());
    notifyListeners();
  }

  /// Освободить место. С папки снимается закрепление, и всё скачанное
  /// внутри неё уходит с диска: держать её дальше незачем.
  Future<void> evict(Iterable<RemoteFile> files) async {
    for (final f in files) {
      if (f.isDir) {
        await vault.setPinnedDir(f.path, false);
        for (final e in vault.entriesUnder(f.path)) {
          await vault.evict(e.path);
        }
      } else {
        await vault.evict(f.path);
      }
    }
    notifyListeners();
  }

  /// Отправить локальные правки обратно на сервер.
  Future<void> pushLocalChanges(RemoteFile file) async {
    final local = vault.localFile(file.path);
    if (!await local.exists()) return;
    transfers.enqueueUpload(local, file.path);
    notifyListeners();
  }

  // ------------------------------------------------------- открытие файлов

  /// Двойной клик по файлу: если копии нет — качаем, потом отдаём системе.
  Future<void> openFile(RemoteFile file) async {
    // Документ Google — не файл: содержимого у него нет, только запись в
    // базе. Скачивать нечего, поэтому открываем сразу в браузере.
    if (isWebOnly(file)) {
      await openInBrowser(file);
      return;
    }

    final local = vault.localFile(file.path);
    final presence = vault.presenceOf(file);

    if (presence == Presence.remote || presence == Presence.outdated) {
      final task = transfers.enqueueDownload(file);
      while (task.isActive) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      if (task.state != TransferState.done) {
        throw NextcloudException(task.error ?? 'Не удалось скачать файл');
      }
    }
    if (!await local.exists()) {
      throw NextcloudException('Локальной копии не оказалось на месте');
    }
    await launchUrl(Uri.file(local.path));
  }

  /// Показать локальную копию в Проводнике.
  Future<void> revealInExplorer(RemoteFile file) async {
    final local = vault.localFile(file.path);
    if (!await local.exists()) return;
    await Process.start('explorer', ['/select,', local.path]);
  }

  /// Открыть файл на сервере в браузере — там доступны версии и комментарии.
  /// Запись, которую можно только открыть в вебе: у неё нет содержимого,
  /// и скачивание, отправка и синхронизация к ней неприменимы.
  bool isWebOnly(RemoteFile file) =>
      !file.isDir && GoogleDriveClient.isNativeDoc(file.mimeType);

  Future<void> openInBrowser(RemoteFile file) async {
    // У облака может быть свой адрес записи в вебе — спрашиваем сначала его.
    final own = dav.webUrl(file);
    if (own != null) {
      await launchUrl(own, mode: LaunchMode.externalApplication);
      return;
    }

    final id = file.fileId;
    final uri = id == null
        ? account.baseUrl.replace(pathSegments: [
            ...account.baseUrl.pathSegments.where((s) => s.isNotEmpty),
            'index.php',
            'apps',
            'files',
          ], queryParameters: {'dir': '/${file.parent}'})
        : account.baseUrl.replace(pathSegments: [
            ...account.baseUrl.pathSegments.where((s) => s.isNotEmpty),
            'index.php',
            'f',
            id,
          ]);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  // ------------------------------------------------------------ служебное

  void _onTransfers() {
    // Когда очередь пустеет, содержимое папки могло измениться.
    if (transfers.activeCount == 0) unawaited(refreshQuota());
    notifyListeners();
  }

  static String _normalize(String path) => path.replaceAll(RegExp(r'^/+|/+$'), '');

  static String _join(String dir, String name) =>
      dir.isEmpty ? name : '$dir/$name';

  @override
  void dispose() {
    vault.removeListener(notifyListeners);
    transfers.removeListener(_onTransfers);
    edits.removeListener(notifyListeners);
    sync.removeListener(notifyListeners);
    transfers.cancelAll();
    sync.dispose();
    edits.dispose();
    vault.dispose();
    dav.close();
    super.dispose();
  }
}
