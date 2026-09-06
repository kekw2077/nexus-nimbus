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
  Vault._(this._root, this._indexFile, this._index, this._pinnedDirs, this._dirEtags);

  Directory _root;

  /// Куда складываются скачанные файлы. Меняется из настроек — вместе
  /// с переносом уже скачанного, см. [moveRootTo].
  Directory get root => _root;

  final File _indexFile;
  final Map<String, VaultEntry> _index;

  /// Папки, которые держим локально целиком. Файлы внутри них не помечаются
  /// закреплёнными поштучно: иначе снятие закрепления с папки оставило бы
  /// после себя россыпь вечных файлов, которую уже никто не вычистит.
  final Set<String> _pinnedDirs;

  /// Etag папок на момент, когда её содержимое последний раз сошлось с
  /// сервером. Nextcloud меняет etag папки от любой правки внутри, включая
  /// вложенные, — по нему обход понимает, что в поддерево можно не ходить.
  final Map<String, String> _dirEtags;

  /// Пути, по которым прямо сейчас идёт передача — их статус перебивает всё.
  final Set<String> _busy = {};

  /// Пути, у которых локальный файл поменялся после скачивания.
  final Set<String> _dirty = {};

  Timer? _flush;

  /// Папка по умолчанию для учётной записи, когда своя не выбрана.
  ///
  /// У каждой записи своя: у разных облаков по одному и тому же пути лежат
  /// разные файлы, и общая папка на всех перемешала бы их.
  static Future<Directory> defaultRoot(String accountSlug) async => Directory(
        p.join((await getApplicationSupportDirectory()).path, 'vault', accountSlug),
      );

  static Future<Vault> open({
    required String accountSlug,
    Directory? customRoot,
  }) async {
    final support = await getApplicationSupportDirectory();

    // Индекс живёт в папке приложения, а не рядом с файлами: он описывает
    // состояние, а не содержимое, и переезд хранилища его не касается.
    final indexFile = File(p.join(support.path, 'vault-index-$accountSlug.json'));

    // Прежние версии знали одну учётную запись: индекс лежал без имени, а
    // файлы — прямо в <support>/vault. Забираем и то, и другое, иначе после
    // обновления скачанное выглядело бы пропавшим. Путь потом сохраняется в
    // настройки записи, поэтому проверка срабатывает ровно один раз.
    final legacyIndex = File(p.join(support.path, 'vault-index.json'));
    final inherited = !await indexFile.exists() && await legacyIndex.exists();
    if (inherited) await legacyIndex.rename(indexFile.path);

    final base = customRoot ??
        (inherited
            ? Directory(p.join(support.path, 'vault'))
            : await defaultRoot(accountSlug));
    await base.create(recursive: true);
    final index = <String, VaultEntry>{};
    final pinnedDirs = <String>{};
    final dirEtags = <String, String>{};
    if (await indexFile.exists()) {
      try {
        final raw = jsonDecode(await indexFile.readAsString()) as Map<String, dynamic>;

        // Индекс до закреплённых папок был просто картой «путь → запись».
        // Читаем оба вида: у нового есть метка версии.
        final files = raw['v'] == 2 ? raw['files'] as Map<String, dynamic>? : raw;
        files?.forEach((path, value) {
          index[path] = VaultEntry.fromJson(path, value as Map<String, dynamic>);
        });
        if (raw['v'] == 2) {
          for (final d in (raw['dirs'] as List<dynamic>? ?? const [])) {
            pinnedDirs.add(d as String);
          }
          (raw['diretags'] as Map<String, dynamic>?)?.forEach((path, value) {
            dirEtags[path] = value as String;
          });
        }
      } catch (_) {
        // Битый индекс не повод падать: файлы на диске целы, статусы
        // просто пересоберутся при первом же обходе папок.
      }
    }
    return Vault._(base, indexFile, index, pinnedDirs, dirEtags);
  }

  /// Путь локальной копии для файла на сервере.
  File localFile(String remotePath) =>
      File(p.join(_root.path, p.joinAll(remotePath.split('/'))));

  /// Обратное преобразование: путь на диске — в путь на сервере.
  /// Null, если файл лежит вне хранилища и нас не касается.
  String? remotePathOf(String localPath) {
    final rel = p.relative(localPath, from: _root.path);
    if (rel.isEmpty || rel == '.' || rel.startsWith('..') || p.isAbsolute(rel)) {
      return null;
    }
    return p.split(rel).join('/');
  }

  VaultEntry? entry(String remotePath) => _index[remotePath];

  /// Всё, что сейчас лежит на диске, — для экрана «Локальное».
  List<VaultEntry> get entries => List.unmodifiable(_index.values);

  bool isDirty(String remotePath) => _dirty.contains(remotePath);

  /// Закреплён ли файл — сам по себе или тем, что лежит в закреплённой папке.
  bool isPinned(String remotePath) =>
      (_index[remotePath]?.pinned ?? false) || inPinnedDir(remotePath);

  /// Папки, которые держим локально целиком.
  Set<String> get pinnedDirs => Set.unmodifiable(_pinnedDirs);

  bool isPinnedDir(String remotePath) => _pinnedDirs.contains(remotePath);

  /// Лежит ли путь внутри закреплённой папки. Закреплённых папок единицы,
  /// поэтому перебор здесь дешевле любой другой раскладки.
  bool inPinnedDir(String remotePath) {
    for (final dir in _pinnedDirs) {
      if (remotePath == dir || remotePath.startsWith('$dir/')) return true;
    }
    return false;
  }

  Future<void> setPinnedDir(String remotePath, bool pinned) async {
    final changed = pinned ? _pinnedDirs.add(remotePath) : _pinnedDirs.remove(remotePath);
    if (!changed) return;
    // Закрепили папку — поштучные флаги внутри больше не нужны: папка и так
    // всё держит, а лишние флаги пережили бы её открепление.
    if (pinned) {
      for (final e in _index.values) {
        if (e.pinned && inPinnedDir(e.path)) e.pinned = false;
      }
    }
    _schedulePersist();
    notifyListeners();
  }

  /// Etag папки на момент, когда её содержимое сошлось с сервером.
  String? dirEtag(String remotePath) => _dirEtags[remotePath];

  /// Запоминает, что папка сошлась с сервером на этом etag. Пишется только
  /// после того, как обход действительно ничего не нашёл: иначе пропущенное
  /// поддерево осталось бы пропущенным навсегда.
  void rememberDirEtag(String remotePath, String etag) {
    if (_dirEtags[remotePath] == etag) return;
    _dirEtags[remotePath] = etag;
    _schedulePersist();
  }

  /// Забыть согласие по папке — следующий обход снова в неё зайдёт.
  void forgetDirEtag(String remotePath) {
    if (_dirEtags.remove(remotePath) != null) _schedulePersist();
  }

  /// Записи индекса, лежащие внутри папки. Нужны обходу синхронизации:
  /// по ним видно, чего на сервере уже нет.
  List<VaultEntry> entriesUnder(String dir) => _index.values
      .where((e) => dir.isEmpty || e.path.startsWith('$dir/'))
      .toList(growable: false);

  bool isBusy(String remotePath) => _busy.contains(remotePath);

  /// Синхронный расчёт статуса — вызывается на каждой строке списка,
  /// поэтому только карты в памяти, никаких обращений к диску.
  Presence presenceOf(RemoteFile file) {
    // У папки состояние одно на всю: либо держим её целиком, либо она
    // просто лежит на сервере.
    if (file.isDir) return isPinnedDir(file.path) ? Presence.pinned : Presence.remote;
    if (_busy.contains(file.path)) return Presence.transferring;

    final e = _index[file.path];
    if (e == null) return Presence.remote;

    final changedHere = _dirty.contains(file.path);
    final changedThere = file.etag != null && e.etag.isNotEmpty && file.etag != e.etag;

    if (changedHere && changedThere) return Presence.conflict;
    if (changedHere) return Presence.dirty;
    if (changedThere) return Presence.outdated;
    return isPinned(file.path) ? Presence.pinned : Presence.cached;
  }

  /// Отмечает, что локальную копию правили здесь и она разошлась с сервером.
  /// Тот же вывод делает [audit] при обходе папки — но он случается только
  /// когда папку открывают, а слежение за диском замечает правку сразу.
  void markDirty(String remotePath) {
    if (!_index.containsKey(remotePath)) return;
    if (_dirty.add(remotePath)) notifyListeners();
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
    // Переименовали закреплённую папку — закрепление едет с ней, иначе
    // синхронизация продолжила бы ходить по несуществующему пути.
    if (_pinnedDirs.remove(from)) {
      _pinnedDirs.add(to);
      _schedulePersist();
    }

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
      if (isPinned(e.path)) pinned += e.size;
    }
    return (total: total, pinned: pinned);
  }

  int get fileCount => _index.length;

  /// Чистка кэша: сносим всё, кроме закреплённого и несохранённых правок.
  Future<int> evictUnpinned() async {
    final victims = _index.values
        .where((e) => !isPinned(e.path) && !_dirty.contains(e.path))
        .map((e) => e.path)
        .toList();
    for (final path in victims) {
      final f = localFile(path);
      if (await f.exists()) await f.delete();
      _index.remove(path);
    }
    await _pruneEmptyDirs(_root);
    await _persist();
    notifyListeners();
    return victims.length;
  }

  /// Переносит хранилище в другую папку вместе с уже скачанным.
  ///
  /// Файлы именно переносятся, а не бросаются на старом месте: иначе
  /// получилось бы ровно то, ради чего затевалось приложение, — копии
  /// неизвестно где. Возвращает, сколько файлов переехало.
  Future<int> moveRootTo(Directory target) async {
    if (p.equals(target.path, _root.path)) return 0;
    await target.create(recursive: true);

    final old = _root;
    var moved = 0;
    for (final entry in _index.values.toList()) {
      final from = File(p.join(old.path, p.joinAll(entry.path.split('/'))));
      if (!await from.exists()) continue;
      final to = File(p.join(target.path, p.joinAll(entry.path.split('/'))));
      await to.parent.create(recursive: true);
      if (await to.exists()) await to.delete();
      try {
        await from.rename(to.path);
      } on FileSystemException {
        // Перенос между дисками переименованием не делается — копируем.
        await from.copy(to.path);
        await from.delete();
      }
      // Время изменения после переезда другое; иначе файл сразу считался бы
      // правленым и попал бы в «изменён, не отправлен».
      entry.localMtimeMs = (await to.stat()).modified.millisecondsSinceEpoch;
      moved++;
    }

    _root = target;
    if (await old.exists()) {
      await _pruneEmptyDirs(old);
      if (await old.list().isEmpty) await old.delete();
    }
    await _persist();
    notifyListeners();
    return moved;
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

  /// Убирает пустые папки, оставшиеся после чистки или переезда.
  /// Сам [stopAt] не удаляется — он и есть корень обхода.
  Future<void> _pruneEmptyDirs(Directory dir, [Directory? stopAt]) async {
    final root = stopAt ?? dir;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is Directory) await _pruneEmptyDirs(entity, root);
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
    final files = <String, dynamic>{};
    _index.forEach((path, e) => files[path] = e.toJson());
    await _indexFile.writeAsString(jsonEncode({
      'v': 2,
      'files': files,
      'dirs': _pinnedDirs.toList()..sort(),
      'diretags': _dirEtags,
    }));
  }

  @override
  void dispose() {
    _flush?.cancel();
    unawaited(_persist());
    super.dispose();
  }
}
