import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:crypto/crypto.dart';
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
    this.batch,
    this.total = 0,
  });

  final int id;
  final TransferKind kind;
  final String remotePath;
  final File local;

  /// Для скачивания — запись с сервера: из неё берём etag для индекса.
  final RemoteFile? source;

  /// Пачка, из которой задача взялась. Null — человек попросил именно
  /// этот файл, и показывать его надо отдельной строкой.
  final TransferBatch? batch;

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

/// Одно действие человека, породившее много передач: «залей эту папку»,
/// «скачай ту». Очередь по-прежнему состоит из отдельных задач — иначе не
/// отменить одну и не посчитать скорость, — но наверх выходит пачка
/// целиком: пятьдесят тысяч строк в списке загрузок не помогают найти
/// ничего, они только мешают увидеть остальные передачи.
class TransferBatch {
  TransferBatch({
    required this.id,
    required this.kind,
    required this.label,
    this.remoteRoot,
  });

  final int id;
  final TransferKind kind;

  /// Как назвать пачку в списке: имя папки или «12 файлов».
  final String label;

  /// Папка на сервере, если пачка — папка. У россыпи файлов её нет.
  final String? remoteRoot;

  bool get isFolder => remoteRoot != null;

  /// Пока дерево обходится, итог неизвестен: и файлов, и байтов станет
  /// больше. Это стоит говорить вслух — знаменатель растёт вместе с
  /// числителем, и процент, честно посчитанный, всё равно врёт: на
  /// полусотне тысяч файлов он висит около нуля, пока идёт обход.
  bool scanning = true;

  /// Сколько задач в пачке и что с ними стало.
  int files = 0;
  int filesDone = 0;
  int filesFailed = 0;
  int filesCancelled = 0;

  int bytesTotal = 0;

  /// Байты закрытых задач. Идущие складываем отдельно: их не больше
  /// [TransferQueue.concurrency], и такой перебор ничего не стоит,
  /// а обходить полсотни тысяч записей на каждом кадре — стоит, и много.
  int _settledBytes = 0;
  final Set<TransferTask> _live = {};

  /// Что не залилось. Держим не всё: причина у сотни неудач обычно одна,
  /// а список на сотню тысяч строк — это ровно то, от чего уходим.
  static const maxFailures = 50;
  final List<TransferTask> failures = [];

  DateTime? startedAt;
  DateTime? finishedAt;
  bool cancelled = false;

  /// Что передаётся прямо сейчас — их и показываем, когда пачку раскрыли.
  Iterable<TransferTask> get live => _live;

  @visibleForTesting
  void noteRunning(TransferTask task) => _live.add(task);

  int get bytesDone => _settledBytes + _live.fold<int>(0, (s, t) => s + t.done);

  int get filesSettled => filesDone + filesFailed + filesCancelled;
  int get filesLeft => files - filesSettled;

  /// Пачка жива, пока её обходят или пока в ней осталась работа.
  bool get isActive => scanning || filesLeft > 0;

  double get fraction =>
      bytesTotal <= 0 ? 0 : (bytesDone / bytesTotal).clamp(0.0, 1.0);

  int get bytesPerSecond => _live.fold<int>(0, (s, t) => s + t.bytesPerSecond);

  int get bytesLeft => (bytesTotal - bytesDone).clamp(0, bytesTotal);

  /// Оценка остатка. Пока идёт обход, её не даём вовсе: считать её от
  /// неполного знаменателя — значит обещать срок, который потом вырастет
  /// втрое. Лучше промолчать, чем соврать.
  Duration? get remaining {
    if (scanning) return null;
    final speed = bytesPerSecond;
    if (speed <= 0) return null;
    final left = bytesLeft;
    if (left <= 0) return Duration.zero;
    return Duration(seconds: (left / speed).ceil());
  }

  /// Чем всё кончилось. Отменённая пачка остаётся отменённой, даже если
  /// часть файлов успела уехать: важнее, что человек её остановил.
  TransferState get state {
    if (isActive) return _live.isEmpty ? TransferState.queued : TransferState.running;
    if (cancelled || filesCancelled > 0) return TransferState.cancelled;
    if (filesFailed > 0) return TransferState.failed;
    return TransferState.done;
  }

  @visibleForTesting
  void noteAdded(TransferTask task) {
    files++;
    bytesTotal += task.total;
    startedAt ??= DateTime.now();
  }

  @visibleForTesting
  void noteSettled(TransferTask task, TransferState state) {
    _live.remove(task);
    // У завершённой задачи засчитываем весь размер: последний отрезок
    // прогресса может не прийти, а файл при этом уехал целиком.
    _settledBytes += state == TransferState.done && task.total > 0 ? task.total : task.done;

    switch (state) {
      case TransferState.done:
        filesDone++;
      case TransferState.failed:
        filesFailed++;
        if (failures.length < maxFailures) failures.add(task);
      case TransferState.cancelled:
        filesCancelled++;
      case TransferState.queued || TransferState.running:
        break;
    }

    if (!isActive) finishedAt ??= DateTime.now();
  }
}

/// Очередь передач с ограничением параллелизма. Три потока — компромисс:
/// больше упирается в PHP-воркеры на типичном self-hosted сервере.
class TransferQueue extends ChangeNotifier {
  TransferQueue(this._dav, this._vault);

  StorageBackend _dav;
  final Vault _vault;

  static const concurrency = 3;

  /// Задачи, которые человек просил поимённо. Задачи из пачек сюда не
  /// попадают: их показывает пачка, а держать их все ради списка значило
  /// бы хранить полсотни тысяч объектов до конца сеанса.
  final List<TransferTask> _loose = [];

  final List<TransferBatch> _batches = [];
  final Queue<TransferTask> _pending = Queue();

  /// Идущие прямо сейчас — их не больше [concurrency]. Скорость и общий
  /// прогресс считаются по ним, а не обходом всей очереди.
  final Set<TransferTask> _live = {};

  /// Активные задачи по пути на сервере. Список, а не одна задача: за
  /// отправкой файла может идти его же скачивание, и путь освобождается
  /// только когда по нему не осталось ничего.
  final Map<String, List<TransferTask>> _byPath = {};

  int _nextId = 1;
  int _nextBatchId = 1;
  bool _disposed = false;
  Timer? _notifyTimer;

  /// Позвать после смены учётной записи.
  set client(StorageBackend value) => _dav = value;

  /// Одиночные задачи, новые сверху.
  List<TransferTask> get tasks => List.unmodifiable(_loose.reversed);

  /// Пачки, новые сверху.
  List<TransferBatch> get batches => List.unmodifiable(_batches.reversed);

  Iterable<TransferBatch> get activeBatches => _batches.where((b) => b.isActive);

  /// Активных задач всего — очередь плюс то, что идёт. Считается по
  /// длинам, а не перебором: на большой заливке это спрашивают на каждом
  /// кадре.
  int get activeCount => _live.length + _pending.length;

  bool get isBusy => activeCount > 0;

  TransferTask? activeFor(String remotePath) {
    final byPath = _byPath[remotePath];
    return (byPath == null || byPath.isEmpty) ? null : byPath.first;
  }

  /// Общая скорость обмена с сервером: складываем только то, что
  /// действительно идёт. Стоящее в очереди ничего не занимает.
  int get bytesPerSecond => _live.fold<int>(0, (s, t) => s + t.bytesPerSecond);

  // ------------------------------------------------- сводка по всей работе

  /// Всё, что сейчас в работе: живые пачки и одиночные задачи. По ним
  /// считаются проценты в шапке — законченное в них не участвует, иначе
  /// полоса дёргалась бы назад при каждой новой передаче.
  Iterable<TransferBatch> get _liveBatches => _batches.where((b) => b.isActive);
  Iterable<TransferTask> get _liveLoose => _loose.where((t) => t.isActive);

  int get doneBytes =>
      _liveBatches.fold<int>(0, (s, b) => s + b.bytesDone) +
      _liveLoose.fold<int>(0, (s, t) => s + t.done);

  int get totalBytes =>
      _liveBatches.fold<int>(0, (s, b) => s + b.bytesTotal) +
      _liveLoose.fold<int>(0, (s, t) => s + t.total);

  int get remainingBytes => (totalBytes - doneBytes).clamp(0, totalBytes);

  /// Сколько файлов уже передано и сколько всего предстоит — по тому,
  /// что сейчас в работе. Именно это спрашивают в первую очередь, когда
  /// заливают папку: проценты по байтам ничего не говорят о том, далеко
  /// ли до конца, если файлы разного размера.
  int get filesDone =>
      _liveBatches.fold<int>(0, (s, b) => s + b.filesDone) +
      _loose.where((t) => t.state == TransferState.done).length;

  int get filesTotal =>
      _liveBatches.fold<int>(0, (s, b) => s + b.files) + _liveLoose.length;

  /// Идёт ли ещё обход дерева. Пока идёт, итоговые цифры неполны, и
  /// показывать процент бессмысленно.
  bool get scanning => _liveBatches.any((b) => b.scanning);

  double get overallFraction {
    final total = totalBytes;
    return total <= 0 ? 0 : (doneBytes / total).clamp(0.0, 1.0);
  }

  /// Оценка на всю очередь. Ждущие своей очереди сюда тоже входят: они
  /// поедут на той же скорости, просто позже.
  Duration? get remaining {
    if (scanning) return null;
    final speed = bytesPerSecond;
    if (speed <= 0) return null;
    final left = remainingBytes;
    if (left <= 0) return Duration.zero;
    return Duration(seconds: (left / speed).ceil());
  }

  // ------------------------------------------------------------- постановка

  /// Открыть пачку. Дальше задачи ставятся с ней в руках, а по концу
  /// обхода надо позвать [endBatch] — до этого пачка считает себя
  /// неполной и не обещает сроков.
  TransferBatch beginBatch({
    required TransferKind kind,
    required String label,
    String? remoteRoot,
  }) {
    final batch = TransferBatch(
      id: _nextBatchId++,
      kind: kind,
      label: label,
      remoteRoot: remoteRoot,
    );
    _batches.add(batch);
    _notifySoon();
    return batch;
  }

  /// Обход кончился: больше задач в пачке не появится.
  void endBatch(TransferBatch batch) {
    batch.scanning = false;
    if (batch.files == 0) batch.finishedAt = DateTime.now();
    _notifyNow();
  }

  TransferTask enqueueDownload(RemoteFile file, {TransferBatch? batch}) {
    // По одному пути одна передача: второй запрос того же файла отдаёт
    // уже идущую задачу, а не заводит вторую.
    final existing = _byPath[file.path]
        ?.where((t) => t.isActive && t.kind == TransferKind.download)
        .firstOrNull;
    if (existing != null) return existing;

    return _submit(TransferTask(
      id: _nextId++,
      kind: TransferKind.download,
      remotePath: file.path,
      local: _vault.localFile(file.path),
      source: file,
      batch: batch,
      total: file.size,
    ));
  }

  TransferTask enqueueUpload(File local, String remotePath, {TransferBatch? batch}) {
    return _submit(TransferTask(
      id: _nextId++,
      kind: TransferKind.upload,
      remotePath: remotePath,
      local: local,
      batch: batch,
      total: local.existsSync() ? local.lengthSync() : 0,
    ));
  }

  TransferTask _submit(TransferTask task) {
    final batch = task.batch;
    if (batch == null) {
      _loose.add(task);
    } else {
      batch.noteAdded(task);
    }

    _pending.add(task);
    (_byPath[task.remotePath] ??= []).add(task);
    _vault.markBusy(task.remotePath, true);

    // Не notifyListeners: при заливке папки сюда заходят тысячами подряд,
    // и перерисовка на каждой задаче — это тот самый список загрузок,
    // улетающий вниз, пока идёт обход.
    _notifySoon();
    _pump();
    return task;
  }

  // -------------------------------------------------------------- отмена

  void cancelTask(TransferTask task) {
    task.cancel.cancel();
    if (task.state == TransferState.queued) {
      _pending.remove(task);
      _settle(task, TransferState.cancelled);
    }
    _notifyNow();
  }

  /// Отменить пачку целиком. Очередь пересобирается разом: снимать по
  /// одной значило бы искать каждую в очереди из полусотни тысяч.
  void cancelBatch(TransferBatch batch) {
    batch.cancelled = true;
    batch.scanning = false;

    final keep = Queue<TransferTask>();
    for (final task in _pending) {
      if (task.batch == batch) {
        task.cancel.cancel();
        _settle(task, TransferState.cancelled);
      } else {
        keep.add(task);
      }
    }
    _pending
      ..clear()
      ..addAll(keep);

    for (final task in _live.where((t) => t.batch == batch)) {
      task.cancel.cancel();
    }
    _notifyNow();
  }

  void cancelAll() {
    for (final batch in _batches) {
      batch.cancelled = true;
      batch.scanning = false;
    }
    for (final task in _pending) {
      task.cancel.cancel();
      _settle(task, TransferState.cancelled);
    }
    _pending.clear();
    // Идущие снимутся сами: обмен проверяет флаг между кусками.
    for (final task in _live) {
      task.cancel.cancel();
    }
    _notifyNow();
  }

  /// Убирает из списка всё, что уже отработало.
  void clearFinished() {
    _loose.removeWhere((t) => !t.isActive);
    _batches.removeWhere((b) => !b.isActive);
    _notifyNow();
  }

  bool get hasFinished =>
      _loose.any((t) => !t.isActive) || _batches.any((b) => !b.isActive);

  // ------------------------------------------------------------ исполнение

  void _pump() {
    while (_live.length < concurrency && _pending.isNotEmpty) {
      final task = _pending.removeFirst();
      // Пока задача ждала, пачку могли отменить.
      if (task.cancel.isCancelled) {
        _settle(task, TransferState.cancelled);
        continue;
      }
      _live.add(task);
      task.batch?.noteRunning(task);
      unawaited(_run(task));
    }
  }

  Future<void> _run(TransferTask task) async {
    task.state = TransferState.running;
    task.startedAt = DateTime.now();
    _notifySoon();

    // Прогресс тикает часто, и потоков три — каждый со своим тиком дал бы
    // три десятка перерисовок в секунду. Уведомление общее и сглаженное.
    void onProgress(int done, int total) {
      task.done = done;
      if (total > 0) task.total = total;
      task.sample(done);
      _notifySoon();
    }

    try {
      if (task.kind == TransferKind.download) {
        await _dav.download(task.remotePath, task.local,
            onProgress: onProgress, cancel: task.cancel);
        await _verify(task);
        if (task.source != null) await _vault.registerDownload(task.source!);
      } else {
        await _dav.upload(task.local, task.remotePath,
            onProgress: onProgress, cancel: task.cancel);
        // Etag после записи знает только сервер — спрашиваем его. Внутри
        // пачки не спрашиваем: это лишний запрос на каждый из десятков
        // тысяч файлов, а etag нужен индексу скачанного, которого при
        // заливке папки ещё нет.
        String? etag;
        if (task.batch == null) {
          try {
            etag = (await _dav.stat(task.remotePath)).etag;
          } catch (_) {}
        }
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
      _live.remove(task);
      _pump();
    }
  }

  /// Сверка скачанного с суммой, которую сервер посчитал при заливке.
  /// Длина совпасть может и у побитого файла, а сумма — нет; без сверки
  /// такая копия молча легла бы в кэш со статусом «совпадает с сервером».
  ///
  /// Сумм у сервера может и не быть: их считают при заливке, а файлы,
  /// попавшие на диск мимо клиента, остаются без них. Тогда сверять
  /// нечего — это не повод ругаться.
  Future<void> _verify(TransferTask task) async {
    final want = task.source?.checksums.preferred;
    if (want == null) return;
    if (!await task.local.exists()) return;

    final algorithm = switch (want.type) {
      'MD5' => md5,
      'SHA1' => sha1,
      _ => null,
    };
    if (algorithm == null) return;

    final got = (await algorithm.bind(task.local.openRead()).first).toString();
    if (got.toLowerCase() == want.value.toLowerCase()) return;

    // Побитую копию не оставляем: иначе обход папки примет её за годную.
    try {
      await task.local.delete();
    } catch (_) {}
    throw NextcloudException(
      'Файл дошёл повреждённым: ${want.type} не совпала с серверной. '
      'Скачанное удалено, попробуйте ещё раз.',
    );
  }

  void _finish(TransferTask task, TransferState state) {
    _settle(task, state);
    // Конец задачи — событие редкое и заметное: показываем сразу.
    _notifyNow();
  }

  /// Закрытие задачи: счётчики пачки, освобождение пути, уборка.
  void _settle(TransferTask task, TransferState state) {
    task.state = state;
    task.finishedAt = DateTime.now();
    task.batch?.noteSettled(task, state);

    // По одному пути может идти вторая задача — скачивание сразу за
    // отправкой. Путь занят, пока не закроется последняя.
    final byPath = _byPath[task.remotePath];
    if (byPath != null) {
      byPath.remove(task);
      if (byPath.isEmpty) {
        _byPath.remove(task.remotePath);
        _vault.markBusy(task.remotePath, false);
      }
    }
  }

  // ----------------------------------------------------------- уведомления

  /// Уведомление пачкой. При заливке папки задачи прибывают тысячами
  /// подряд, и перерисовка на каждой стоит дороже самой передачи.
  void _notifySoon() {
    if (_disposed || _notifyTimer != null) return;
    _notifyTimer = Timer(const Duration(milliseconds: 120), () {
      _notifyTimer = null;
      if (!_disposed) notifyListeners();
    });
  }

  void _notifyNow() {
    _notifyTimer?.cancel();
    _notifyTimer = null;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _notifyTimer?.cancel();
    _notifyTimer = null;
    super.dispose();
  }
}
