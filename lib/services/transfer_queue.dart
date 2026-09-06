import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/models/remote_file.dart';
import 'storage_backend.dart';
import 'vault.dart';
import 'webdav_client.dart';

enum TransferKind { download, upload }

enum TransferState { queued, running, done, failed, cancelled }

class TransferTask {
  TransferTask({
    required this.id,
    required this.kind,
    required this.remotePath,
    required this.local,
    this.source,
    this.total = 0,
  });

  final int id;
  final TransferKind kind;
  final String remotePath;
  final File local;

  /// Для скачивания — запись с сервера: из неё берём etag для индекса.
  final RemoteFile? source;

  final CancelToken cancel = CancelToken();

  int done = 0;
  int total;
  TransferState state = TransferState.queued;
  String? error;

  DateTime? startedAt;
  DateTime? finishedAt;

  /// Окно замера скорости. Прогресс приходит на каждый чанк, а по чанку
  /// скорость считать нельзя: получится скорость сети за одну миллисекунду,
  /// и цифра на экране будет мигать вместо того, чтобы что-то значить.
  static const _window = Duration(milliseconds: 400);

  /// Замеры перестали приходить — передача встала, и прежняя цифра врёт.
  static const _stall = Duration(seconds: 3);

  double _speed = 0;
  int _sampleBytes = 0;
  DateTime? _sampleAt;

  String get name => p.basename(remotePath);

  double get fraction => total <= 0 ? 0 : (done / total).clamp(0.0, 1.0);

  bool get isActive => state == TransferState.queued || state == TransferState.running;

  /// Сколько ещё осталось передать. Для задачи с неизвестным размером — ноль.
  int get left => total <= 0 ? 0 : (total - done).clamp(0, total);

  /// Текущая скорость, байт в секунду. Ноль — либо ещё не замеряли,
  /// либо передача встала.
  int get bytesPerSecond {
    final at = _sampleAt;
    if (at == null || _speed <= 0) return 0;
    if (DateTime.now().difference(at) > _stall) return 0;
    return _speed.round();
  }

  /// Сколько осталось при нынешней скорости. Null — считать пока не из чего.
  Duration? get remaining {
    final speed = bytesPerSecond;
    if (speed <= 0 || total <= 0) return null;
    return Duration(seconds: (left / speed).ceil());
  }

  /// Средняя скорость за всю передачу — ею подписываем уже законченное.
  int get averageSpeed {
    final from = startedAt;
    final to = finishedAt;
    if (from == null || to == null) return 0;
    final ms = to.difference(from).inMilliseconds;
    return ms <= 0 ? 0 : (done * 1000 / ms).round();
  }

  /// Замер скорости. Копится экспоненциальным средним: мгновенная скорость
  /// скачет вместе с размером чанка, а цифра под курсором должна
  /// успокаиваться, а не дёргаться.
  void sample(int bytes) {
    final now = DateTime.now();
    final at = _sampleAt;
    if (at == null) {
      _sampleAt = now;
      _sampleBytes = bytes;
      return;
    }

    final ms = now.difference(at).inMilliseconds;
    if (ms < _window.inMilliseconds) return;

    final rate = (bytes - _sampleBytes) * 1000 / ms;
    _speed = _speed <= 0 ? rate : _speed * 0.7 + rate * 0.3;
    if (_speed < 0) _speed = 0;
    _sampleAt = now;
    _sampleBytes = bytes;
  }
}

/// Очередь передач с ограничением параллелизма. Три потока — компромисс:
/// больше упирается в PHP-воркеры на типичном self-hosted сервере.
class TransferQueue extends ChangeNotifier {
  TransferQueue(this._dav, this._vault);

  StorageBackend _dav;
  final Vault _vault;

  static const concurrency = 3;

  final List<TransferTask> _tasks = [];
  final Queue<TransferTask> _pending = Queue();

  /// Активная задача по пути на сервере. Нужна списку файлов: он спрашивает
  /// про каждую видимую строку на каждом кадре, и перебор здесь был бы
  /// заметен на большой папке.
  final Map<String, TransferTask> _activeByPath = {};
  int _running = 0;
  int _nextId = 1;

  /// Позвать после смены учётной записи.
  set client(StorageBackend value) => _dav = value;

  List<TransferTask> get tasks => List.unmodifiable(_tasks.reversed);

  Iterable<TransferTask> get active => _tasks.where((t) => t.isActive);

  int get activeCount => active.length;

  /// Суммарный прогресс активных задач — для полоски в шапке.
  double get overallFraction {
    final live = active.where((t) => t.total > 0).toList();
    if (live.isEmpty) return 0;
    final done = live.fold<int>(0, (s, t) => s + t.done);
    final total = live.fold<int>(0, (s, t) => s + t.total);
    return total == 0 ? 0 : done / total;
  }

  TransferTask? activeFor(String remotePath) => _activeByPath[remotePath];

  /// Общая скорость обмена с сервером: складываем только те задачи, что
  /// действительно идут. Стоящие в очереди ничего не занимают.
  int get bytesPerSecond => _tasks
      .where((t) => t.state == TransferState.running)
      .fold<int>(0, (s, t) => s + t.bytesPerSecond);

  /// Сколько всего осталось передать по всей очереди.
  int get remainingBytes => active.fold<int>(0, (s, t) => s + t.left);

  /// Сколько уже передано и сколько всего предстоит — по активным задачам,
  /// у которых известен размер. Ими подписана полоса в шапке файлов.
  int get doneBytes =>
      active.where((t) => t.total > 0).fold<int>(0, (s, t) => s + t.done);

  int get totalBytes =>
      active.where((t) => t.total > 0).fold<int>(0, (s, t) => s + t.total);

  /// Оценка на всю очередь. Ждущие своей очереди сюда тоже входят: они
  /// поедут на той же скорости, просто позже.
  Duration? get remaining {
    final speed = bytesPerSecond;
    if (speed <= 0) return null;
    final left = remainingBytes;
    if (left <= 0) return Duration.zero;
    return Duration(seconds: (left / speed).ceil());
  }

  TransferTask enqueueDownload(RemoteFile file) {
    final existing = _tasks
        .where((t) => t.isActive && t.kind == TransferKind.download && t.remotePath == file.path)
        .firstOrNull;
    if (existing != null) return existing;

    final task = TransferTask(
      id: _nextId++,
      kind: TransferKind.download,
      remotePath: file.path,
      local: _vault.localFile(file.path),
      source: file,
      total: file.size,
    );
    return _submit(task);
  }

  TransferTask enqueueUpload(File local, String remotePath) {
    final task = TransferTask(
      id: _nextId++,
      kind: TransferKind.upload,
      remotePath: remotePath,
      local: local,
      total: local.existsSync() ? local.lengthSync() : 0,
    );
    return _submit(task);
  }

  TransferTask _submit(TransferTask task) {
    _tasks.add(task);
    _pending.add(task);
    _activeByPath[task.remotePath] = task;
    _vault.markBusy(task.remotePath, true);
    notifyListeners();
    _pump();
    return task;
  }

  void cancelTask(TransferTask task) {
    task.cancel.cancel();
    if (task.state == TransferState.queued) {
      _pending.remove(task);
      _finish(task, TransferState.cancelled);
    }
    notifyListeners();
  }

  void cancelAll() {
    for (final t in _tasks.where((t) => t.isActive).toList()) {
      cancelTask(t);
    }
  }

  /// Убирает из списка всё, что уже отработало.
  void clearFinished() {
    _tasks.removeWhere((t) => !t.isActive);
    notifyListeners();
  }

  void _pump() {
    while (_running < concurrency && _pending.isNotEmpty) {
      final task = _pending.removeFirst();
      _running++;
      unawaited(_run(task));
    }
  }

  Future<void> _run(TransferTask task) async {
    task.state = TransferState.running;
    task.startedAt = DateTime.now();
    notifyListeners();

    // Прогресс тикает часто; перерисовываем не чаще, чем раз в 100 мс,
    // иначе список передач съедает кадр целиком.
    var lastTick = DateTime.now();
    void onProgress(int done, int total) {
      task.done = done;
      if (total > 0) task.total = total;
      task.sample(done);
      final now = DateTime.now();
      if (now.difference(lastTick).inMilliseconds >= 100) {
        lastTick = now;
        notifyListeners();
      }
    }

    try {
      if (task.kind == TransferKind.download) {
        await _dav.download(task.remotePath, task.local,
            onProgress: onProgress, cancel: task.cancel);
        if (task.source != null) await _vault.registerDownload(task.source!);
      } else {
        await _dav.upload(task.local, task.remotePath,
            onProgress: onProgress, cancel: task.cancel);
        // Etag после записи знает только сервер — спрашиваем его.
        String? etag;
        try {
          etag = (await _dav.stat(task.remotePath)).etag;
        } catch (_) {}
        await _vault.registerUpload(task.remotePath, etag);
      }
      task.done = task.total;
      _finish(task, TransferState.done);
    } on CancelledException {
      _finish(task, TransferState.cancelled);
    } catch (e) {
      task.error = e.toString();
      _finish(task, TransferState.failed);
    } finally {
      _running--;
      _pump();
    }
  }

  void _finish(TransferTask task, TransferState state) {
    task.state = state;
    task.finishedAt = DateTime.now();

    // По одному пути может идти вторая задача — скачивание сразу за
    // отправкой. Тогда путь остаётся занятым, а на индексе его заменяет она.
    final next = _tasks
        .where((t) => t.isActive && t.remotePath == task.remotePath)
        .firstOrNull;
    if (next == null) {
      _activeByPath.remove(task.remotePath);
      _vault.markBusy(task.remotePath, false);
    } else {
      _activeByPath[task.remotePath] = next;
    }
    notifyListeners();
  }
}
