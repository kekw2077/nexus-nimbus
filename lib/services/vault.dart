import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/models/remote_file.dart';

/// Что мы знаем о локальной копии одного файла.
class VaultEntry {
  VaultEntry({
    required this.path,
    required this.etag,
    required this.size,
    required this.localMtimeMs,
    this.pinned = false,
  });

  /// Путь на сервере относительно корня пользователя.
  final String path;

  /// Etag на момент последней синхронизации. Отличается от серверного —
  /// значит, на сервере файл переписали.
  String etag;

  int size;

  /// Время изменения локального файла сразу после скачивания. Если оно
  /// изменилось — файл правили на этой машине.
  int localMtimeMs;

  bool pinned;

  Map<String, dynamic> toJson() => {
        'etag': etag,
        'size': size,
        'mtime': localMtimeMs,
        'pinned': pinned,
      };

  static VaultEntry fromJson(String path, Map<String, dynamic> j) => VaultEntry(
        path: path,
        etag: j['etag'] as String? ?? '',
        size: (j['size'] as num?)?.toInt() ?? 0,
        localMtimeMs: (j['mtime'] as num?)?.toInt() ?? 0,
        pinned: j['pinned'] as bool? ?? false,
      );
}

/// Локальное зеркало: файлы лежат по тем же путям, что и на сервере,
/// плюс индекс, по которому вычисляется статус присутствия.
///
/// Никакой фоновой магии: сюда попадает только то, что пользователь
/// скачал явно или что закреплено.
class Vault extends ChangeNotifier {
  Vault._(this.root, this._indexFile, this._index);

  final Directory root;
  final File _indexFile;
  final Map<String, VaultEntry> _index;

  /// Пути, по которым прямо сейчас идёт передача — их статус перебивает всё.
  final Set<String> _busy = {};

  /// Пути, у которых локальный файл поменялся после скачивания.
  final Set<String> _dirty = {};

  Timer? _flush;

  static Future<Vault> open({Directory? customRoot}) async {
    final base = customRoot ?? Directory(p.join((await getApplicationSupportDirectory()).path, 'vault'));
    await base.create(recursive: true);

    final indexFile = File(p.join(base.parent.path, 'vault-index.json'));
    final index = <String, VaultEntry>{};
    if (await indexFile.exists()) {
      try {
        final raw = jsonDecode(await indexFile.readAsString()) as Map<String, dynamic>;
        raw.forEach((path, value) {
          index[path] = VaultEntry.fromJson(path, value as Map<String, dynamic>);
        });
      } catch (_) {
        // Битый индекс не повод падать: файлы на диске целы, статусы
        // просто пересоберутся при первом же обходе папок.
      }
    }
    return Vault._(base, indexFile, index);
  }

  /// Путь локальной копии для файла на сервере.
  File localFile(String remotePath) =>
      File(p.join(root.path, p.joinAll(remotePath.split('/'))));

  VaultEntry? entry(String remotePath) => _index[remotePath];

  /// Всё, что сейчас лежит на диске, — для экрана «Локальное».
  List<VaultEntry> get entries => List.unmodifiable(_index.values);

  bool isDirty(String remotePath) => _dirty.contains(remotePath);

  bool isPinned(String remotePath) => _index[remotePath]?.pinned ?? false;

  bool isBusy(String remotePath) => _busy.contains(remotePath);

  /// Синхронный расчёт статуса — вызывается на каждой строке списка,
  /// поэтому только карты в памяти, никаких обращений к диску.
  Presence presenceOf(RemoteFile file) {
    if (file.isDir) return Presence.remote;
    if (_busy.contains(file.path)) return Presence.transferring;

    final e = _index[file.path];
    if (e == null) return Presence.remote;

    final changedHere = _dirty.contains(file.path);
    final changedThere = file.etag != null && e.etag.isNotEmpty && file.etag != e.etag;

    if (changedHere && changedThere) return Presence.conflict;
    if (changedHere) return Presence.dirty;
    if (changedThere) return Presence.outdated;
    return e.pinned ? Presence.pinned : Presence.cached;
  }

  void markBusy(String remotePath, bool busy) {
    if (busy) {
      _busy.add(remotePath);
    } else {
      _busy.remove(remotePath);
    }
    notifyListeners();
  }

  /// Регистрирует свежескачанный файл.
  Future<void> registerDownload(RemoteFile file) async {
    final f = localFile(file.path);
    if (!await f.exists()) return;
    final stat = await f.stat();
    _index[file.path] = VaultEntry(
      path: file.path,
      etag: file.etag ?? '',
      size: stat.size,
      localMtimeMs: stat.modified.millisecondsSinceEpoch,
      pinned: _index[file.path]?.pinned ?? false,
    );
    _dirty.remove(file.path);
    _schedulePersist();
    notifyListeners();
  }

  /// После успешной отправки локальных правок обратно на сервер.
  Future<void> registerUpload(String remotePath, String? newEtag) async {
    final e = _index[remotePath];
    final f = localFile(remotePath);
    if (e == null || !await f.exists()) return;
    final stat = await f.stat();
    e
      ..etag = newEtag ?? e.etag
      ..size = stat.size
      ..localMtimeMs = stat.modified.millisecondsSinceEpoch;
    _dirty.remove(remotePath);
    _schedulePersist();
    notifyListeners();
  }

  Future<void> setPinned(String remotePath, bool pinned) async {
    final e = _index[remotePath];
    if (e == null) return;
    e.pinned = pinned;
    _schedulePersist();
    notifyListeners();
  }

  /// Удаляет локальную копию, файл на сервере не трогает.
  Future<void> evict(String remotePath) async {
    final f = localFile(remotePath);
    if (await f.exists()) await f.delete();
    _index.remove(remotePath);
    _dirty.remove(remotePath);
    _schedulePersist();
    notifyListeners();
  }

  /// Локальная копия переезжает вслед за файлом на сервере.
  Future<void> relocate(String from, String to) async {
    final e = _index.remove(from);
    if (e == null) return;
    final src = localFile(from);
    final dst = localFile(to);
    if (await src.exists()) {
      await dst.parent.create(recursive: true);
      await src.rename(dst.path);
    }
    _index[to] = VaultEntry(
      path: to,
      etag: e.etag,
      size: e.size,
      localMtimeMs: e.localMtimeMs,
      pinned: e.pinned,
    );
    if (_dirty.remove(from)) _dirty.add(to);
    _schedulePersist();
    notifyListeners();
  }

  /// Сколько места занято локальными копиями и сколько из этого закреплено.
  ({int total, int pinned}) usage() {
    var total = 0;
    var pinned = 0;
    for (final e in _index.values) {
      total += e.size;
      if (e.pinned) pinned += e.size;
    }
    return (total: total, pinned: pinned);
  }

  int get fileCount => _index.length;

  /// Чистка кэша: сносим всё, кроме закреплённого и несохранённых правок.
  Future<int> evictUnpinned() async {
    final victims = _index.values
        .where((e) => !e.pinned && !_dirty.contains(e.path))
        .map((e) => e.path)
        .toList();
    for (final path in victims) {
      final f = localFile(path);
      if (await f.exists()) await f.delete();
      _index.remove(path);
    }
    await _pruneEmptyDirs(root);
    await _persist();
    notifyListeners();
    return victims.length;
  }

  /// Сверка индекса с диском для одной папки: файл могли удалить снаружи
  /// или поправить в стороннем редакторе. Запускается после каждого листинга.
  Future<void> audit(Iterable<RemoteFile> files) async {
    var changed = false;
    for (final file in files) {
      if (file.isDir) continue;
      final e = _index[file.path];
      if (e == null) continue;

      final f = localFile(file.path);
      if (!await f.exists()) {
        _index.remove(file.path);
        _dirty.remove(file.path);
        changed = true;
        continue;
      }

      final stat = await f.stat();
      final touched = stat.modified.millisecondsSinceEpoch != e.localMtimeMs;
      if (touched && _dirty.add(file.path)) changed = true;
      if (!touched && _dirty.remove(file.path)) changed = true;
      if (stat.size != e.size) {
        e.size = stat.size;
        changed = true;
      }
    }
    if (changed) {
      _schedulePersist();
      notifyListeners();
    }
  }

  Future<void> _pruneEmptyDirs(Directory dir) async {
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is Directory) await _pruneEmptyDirs(entity);
    }
    if (dir.path != root.path && await dir.list().isEmpty) {
      await dir.delete();
    }
  }

  /// Индекс пишем пачкой: при массовом скачивании иначе получится
  /// по записи на каждый файл.
  void _schedulePersist() {
    _flush?.cancel();
    _flush = Timer(const Duration(milliseconds: 600), _persist);
  }

  Future<void> _persist() async {
    _flush?.cancel();
    _flush = null;
    final data = <String, dynamic>{};
    _index.forEach((path, e) => data[path] = e.toJson());
    await _indexFile.writeAsString(jsonEncode(data));
  }

  @override
  void dispose() {
    _flush?.cancel();
    unawaited(_persist());
    super.dispose();
  }
}
