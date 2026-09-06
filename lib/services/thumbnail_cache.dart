import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'storage_backend.dart';

/// Миниатюры с сервера: сначала память, потом диск, потом сеть.
///
/// Ограничение параллелизма здесь важнее, чем в передачах файлов: при
/// прокрутке большой папки иначе улетает сотня запросов сразу и сервер
/// начинает отдавать 503.
class ThumbnailCache {
  ThumbnailCache(this._dav, this._dir);

  StorageBackend _dav;
  final Directory _dir;

  static const _memoryLimit = 400;
  static const _concurrency = 4;

  final LinkedHashMap<String, Uint8List?> _memory = LinkedHashMap();
  final Map<String, Future<Uint8List?>> _inflight = {};
  final Queue<Completer<void>> _waiting = Queue();
  int _busy = 0;

  set client(StorageBackend value) {
    _dav = value;
    _memory.clear();
  }

  /// Готовая миниатюра, если она уже в памяти. Нужна, чтобы построить кадр
  /// без асинхронных дырок при прокрутке.
  Uint8List? peek(String fileId, int size) => _memory['$fileId@$size'];

  bool knownMissing(String fileId, int size) {
    final key = '$fileId@$size';
    return _memory.containsKey(key) && _memory[key] == null;
  }

  Future<Uint8List?> get(String fileId, {int size = 256}) {
    final key = '$fileId@$size';
    if (_memory.containsKey(key)) return Future.value(_memory[key]);
    return _inflight[key] ??= _load(key, fileId, size).whenComplete(() => _inflight.remove(key));
  }

  Future<Uint8List?> _load(String key, String fileId, int size) async {
    final file = File(p.join(_dir.path, '$fileId-$size.thumb'));
    if (await file.exists()) {
      try {
        final bytes = await file.readAsBytes();
        _remember(key, bytes);
        return bytes;
      } catch (_) {}
    }

    await _acquire();
    try {
      final bytes = await _dav.preview(fileId, size: size);
      if (bytes != null) {
        await _dir.create(recursive: true);
        await file.writeAsBytes(bytes);
      }
      _remember(key, bytes);
      return bytes;
    } finally {
      _release();
    }
  }

  void _remember(String key, Uint8List? bytes) {
    _memory.remove(key);
    _memory[key] = bytes;
    while (_memory.length > _memoryLimit) {
      _memory.remove(_memory.keys.first);
    }
  }

  Future<void> _acquire() {
    if (_busy < _concurrency) {
      _busy++;
      return Future.value();
    }
    final c = Completer<void>();
    _waiting.add(c);
    return c.future;
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      _busy--;
    }
  }

  Future<int> clearDisk() async {
    _memory.clear();
    if (!await _dir.exists()) return 0;
    var n = 0;
    await for (final e in _dir.list()) {
      if (e is File) {
        await e.delete();
        n++;
      }
    }
    return n;
  }
}
