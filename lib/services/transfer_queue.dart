import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/models/remote_file.dart';
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

  String get name => p.basename(remotePath);

  double get fraction => total <= 0 ? 0 : (done / total).clamp(0.0, 1.0);

  bool get isActive => state == TransferState.queued || state == TransferState.running;
}

/// Очередь передач с ограничением параллелизма. Три потока — компромисс:
/// больше упирается в PHP-воркеры на типичном self-hosted сервере.
class TransferQueue extends ChangeNotifier {
  TransferQueue(this._dav, this._vault);

  WebDavClient _dav;
  final Vault _vault;

  static const concurrency = 3;

  final List<TransferTask> _tasks = [];
  final Queue<TransferTask> _pending = Queue();
  int _running = 0;
  int _nextId = 1;

  /// Позвать после смены учётной записи.
  set client(WebDavClient value) => _dav = value;

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
    notifyListeners();

    // Прогресс тикает часто; перерисовываем не чаще, чем раз в 100 мс,
    // иначе список передач съедает кадр целиком.
    var lastTick = DateTime.now();
    void onProgress(int done, int total) {
      task.done = done;
      if (total > 0) task.total = total;
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
    final stillBusy = _tasks.any((t) => t.isActive && t.remotePath == task.remotePath);
    if (!stillBusy) _vault.markBusy(task.remotePath, false);
    notifyListeners();
  }
}
