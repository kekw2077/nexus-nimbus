import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/models/remote_file.dart';
import 'transfer_queue.dart';
import 'vault.dart';
import 'storage_backend.dart';
import 'webdav_client.dart';

/// Чем сейчас занят обход.
enum SyncPhase { idle, running, failed }

/// Файл, который правили и здесь, и на сервере. Местную копию мы не
/// выбрасываем — откладываем рядом под другим именем.
class SyncConflict {
  SyncConflict({required this.remotePath, required this.backup, required this.at});

  final String remotePath;

  /// Куда легла местная версия.
  final File backup;
  final DateTime at;

  String get name => p.basename(remotePath);

  /// Имя отложенной копии — его показывают в списке расхождений.
  String get backupName => p.basename(backup.path);
}

/// Итог одного обхода — им подписывается строка состояния.
class SyncReport {
  int downloaded = 0;
  int uploaded = 0;
  int removed = 0;
  int conflicts = 0;

  /// Сколько поддеревьев обход пропустил по etag, не спрашивая сервер.
  int skipped = 0;

  int get total => downloaded + uploaded + removed + conflicts;

  bool get quiet => total == 0;
}

/// Состояние одного обхода. Живёт ровно столько, сколько идёт обход, и
/// собирает всё, что о нём нужно знать разным его фазам.
class _Sweep {
  _Sweep(this.report);

  final SyncReport report;

  /// Файлы, которые сервер показал.
  final Map<String, RemoteFile> onServer = {};

  /// Папки, которые на сервере точно есть, — по ним понятно, что создавать.
  final Set<String> serverDirs = {};

  /// Поддеревья, в которые не заходили: сервер их не менял.
  final Set<String> skippedDirs = {};

  /// Etag папок, которые можно будет запомнить, если по ним ничего не делали.
  final Map<String, String> candidates = {};

  /// Пути, по которым обход что-то предпринял.
  final Set<String> touched = {};

  void act(String path) => touched.add(path);

  /// Трогали ли что-нибудь внутри этой папки.
  bool busyUnder(String dir) {
    final prefix = '$dir/';
    for (final path in touched) {
      if (path.startsWith(prefix)) return true;
    }
    return false;
  }

  bool insideSkipped(String path) {
    for (final dir in skippedDirs) {
      if (path.startsWith('$dir/')) return true;
    }
    return false;
  }
}

/// Синхронизация в обе стороны: обходит закреплённые папки — или всё дерево,
/// если так велено, — сверяет с индексом хранилища и досылает недостающее.
///
/// Про расхождения: если файл поменялся только на одной стороне — везёт та
/// сторона. Если на обеих, местная копия откладывается под именем с пометкой
/// и скачивается серверная. Ни одна из двух версий не пропадает, а выбирать
/// между ними — дело человека, не программы.
///
/// Про цену обхода: спрашивать всё дерево на каждом круге дорого, поэтому
/// обход опирается на etag папки. Nextcloud меняет его от любой правки
/// внутри, включая вложенные, — совпал с тем, на котором мы в прошлый раз
/// сошлись, значит в поддерево можно не заходить. Etag запоминается только
/// после круга, на котором по этой папке ничего не понадобилось делать:
/// иначе недокачанное поддерево осталось бы пропущенным навсегда.
class SyncEngine extends ChangeNotifier {
  SyncEngine(
    this._dav,
    this._vault,
    this._transfers, {
    bool enabled = true,
    bool everything = false,
    Duration interval = const Duration(minutes: 5),
  }) {
    _enabled = enabled;
    _everything = everything;
    _interval = interval;
  }

  StorageBackend _dav;
  final Vault _vault;
  final TransferQueue _transfers;

  /// Что не отправляем на сервер, даже если оно лежит в синхронизируемой
  /// папке. Временные файлы редакторов, служебный мусор системы и наши же
  /// отложенные копии конфликтов.
  static final _skip = <RegExp>[
    RegExp(r'^~\$'),
    RegExp(r'^\.~lock\.'),
    RegExp(r'\.(tmp|temp|partial|crdownload)$', caseSensitive: false),
    RegExp(r'^(Thumbs\.db|desktop\.ini|\.DS_Store)$', caseSensitive: false),
    RegExp(r' \(конфликт \d{4}-\d{2}-\d{2}'),
  ];

  /// Стоит ли обходить этот файл стороной. Отдельно от [_skip], чтобы
  /// список исключений можно было проверить тестом.
  static bool isSkipped(String name) => _skip.any((re) => re.hasMatch(name));

  /// Имя для отложенной копии: рядом с исходником, с датой в скобках.
  /// Дата в имени — чтобы вторая правка не затёрла первую отложенную.
  static String conflictName(String localPath, DateTime now) {
    final dir = p.dirname(localPath);
    final ext = p.extension(localPath);
    final base = p.basenameWithoutExtension(localPath);

    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}-${two(now.minute)}-${two(now.second)}';
    return p.join(dir, '$base (конфликт $stamp)$ext');
  }

  Timer? _timer;
  late bool _enabled;
  late bool _everything;
  late Duration _interval;

  SyncPhase _phase = SyncPhase.idle;
  String? _error;
  String? _current;
  DateTime? _lastRun;
  SyncReport? _lastReport;
  final List<SyncConflict> _conflicts = [];

  SyncPhase get phase => _phase;
  String? get error => _error;

  /// Какую папку обходим прямо сейчас — для строки состояния.
  String? get current => _current;

  DateTime? get lastRun => _lastRun;
  SyncReport? get lastReport => _lastReport;
  List<SyncConflict> get conflicts => List.unmodifiable(_conflicts);

  bool get enabled => _enabled;

  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    _rearm();
    notifyListeners();
  }

  /// Синхронизировать всё дерево, а не только закреплённое.
  bool get everything => _everything;

  set everything(bool value) {
    if (_everything == value) return;
    _everything = value;
    notifyListeners();
    if (value && _enabled) unawaited(syncNow());
  }

  Duration get interval => _interval;

  set interval(Duration value) {
    if (_interval == value) return;
    _interval = value;
    _rearm();
    notifyListeners();
  }

  /// Позвать после смены учётной записи.
  set client(StorageBackend value) => _dav = value;

  /// Что обходим в этот раз. Корень перекрывает закреплённое целиком,
  /// поэтому при «всё дерево» остальное перечислять незачем.
  List<String> get targets =>
      _everything ? const [''] : (_vault.pinnedDirs.toList()..sort());

  /// Заводит расписание. Первый обход — сразу, дальше по таймеру: то, за чем
  /// следим, должно подтянуться при запуске, а не через пять минут после него.
  void start() {
    _rearm();
    if (_enabled) unawaited(syncNow());
  }

  void _rearm() {
    _timer?.cancel();
    _timer = _enabled ? Timer.periodic(_interval, (_) => unawaited(syncNow())) : null;
  }

  void forgetConflict(SyncConflict conflict) {
    _conflicts.remove(conflict);
    notifyListeners();
  }

  void forgetConflicts() {
    if (_conflicts.isEmpty) return;
    _conflicts.clear();
    notifyListeners();
  }

  /// Один обход. Возврат ничего не значит: работа уходит в очередь передач,
  /// а закончится она уже без нас.
  Future<void> syncNow() async {
    if (_phase == SyncPhase.running) return;

    final dirs = targets;
    if (dirs.isEmpty) {
      _lastRun = DateTime.now();
      _lastReport = SyncReport();
      notifyListeners();
      return;
    }

    _phase = SyncPhase.running;
    _error = null;
    final report = SyncReport();
    notifyListeners();

    try {
      for (final dir in dirs) {
        _current = dir.isEmpty ? 'всё дерево' : dir;
        notifyListeners();
        await _sweep(dir, report);
      }
      _phase = SyncPhase.idle;
    } catch (e) {
      _error = e.toString();
      _phase = SyncPhase.failed;
    } finally {
      _current = null;
      _lastRun = DateTime.now();
      _lastReport = report;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------------ обход

  Future<void> _sweep(String dir, SyncReport report) async {
    final sweep = _Sweep(report);
    await _collect(dir, sweep);

    // 1. Всё, что сервер показал.
    for (final file in sweep.onServer.values) {
      await _reconcile(file, sweep);
    }

    // 2. Всё, что записано у нас, но на сервере не встретилось.
    for (final entry in _vault.entriesUnder(dir)) {
      if (sweep.onServer.containsKey(entry.path)) continue;
      if (sweep.insideSkipped(entry.path)) {
        // В это поддерево мы не заходили, потому что сервер его не менял.
        // Файл там и лежит — но местную правку отправить всё равно надо.
        await _pushIfDirty(entry, sweep);
        continue;
      }
      await _vanished(entry, sweep);
    }

    // 3. Всё, что появилось на диске и чего сервер не знает.
    await _pushNewLocal(dir, sweep);

    // 4. Папки, по которым за этот круг ничего не понадобилось, считаем
    //    сошедшимися: в следующий раз в них можно не заходить.
    _settle(sweep);
  }

  /// Рекурсивный обход папки на сервере.
  Future<void> _collect(String dir, _Sweep sweep) async {
    sweep.serverDirs.add(dir);

    for (final entry in await _dav.list(dir)) {
      if (!entry.isDir) {
        sweep.onServer[entry.path] = entry;
        continue;
      }

      final etag = entry.etag;
      final settled = _vault.dirEtag(entry.path);
      if (etag != null && settled != null && settled == etag) {
        sweep.skippedDirs.add(entry.path);
        sweep.serverDirs.add(entry.path);
        sweep.report.skipped++;
        continue;
      }

      if (etag != null) sweep.candidates[entry.path] = etag;
      await _collect(entry.path, sweep);
    }
  }

  void _settle(_Sweep sweep) {
    sweep.candidates.forEach((dir, etag) {
      if (sweep.busyUnder(dir)) {
        _vault.forgetDirEtag(dir);
      } else {
        _vault.rememberDirEtag(dir, etag);
      }
    });
  }

  Future<void> _reconcile(RemoteFile file, _Sweep sweep) async {
    // По этому пути уже идёт передача — она и приведёт всё в порядок.
    // Но папку выше сошедшейся считать нельзя, пока она не доедет.
    if (_vault.isBusy(file.path)) {
      sweep.act(file.path);
      return;
    }

    final entry = _vault.entry(file.path);
    if (entry == null) {
      _transfers.enqueueDownload(file);
      sweep.report.downloaded++;
      sweep.act(file.path);
      return;
    }

    final changedHere = _vault.isDirty(file.path);
    final changedThere =
        file.etag != null && entry.etag.isNotEmpty && file.etag != entry.etag;

    if (changedHere && changedThere) {
      await _resolve(file, sweep);
      return;
    }
    if (changedThere) {
      _transfers.enqueueDownload(file);
      sweep.report.downloaded++;
      sweep.act(file.path);
      return;
    }
    if (changedHere) {
      final local = _vault.localFile(file.path);
      if (await local.exists()) {
        _transfers.enqueueUpload(local, file.path);
        sweep.report.uploaded++;
        sweep.act(file.path);
      }
      return;
    }

    // Ничего не менялось, но копии может не оказаться на месте: то, за чем
    // следим, держим локально целиком, поэтому возвращаем её.
    if (!await _vault.localFile(file.path).exists()) {
      _transfers.enqueueDownload(file);
      sweep.report.downloaded++;
      sweep.act(file.path);
    }
  }

  /// Правили и здесь, и там. Местную версию откладываем, серверную качаем.
  Future<void> _resolve(RemoteFile file, _Sweep sweep) async {
    sweep.act(file.path);

    final local = _vault.localFile(file.path);
    if (!await local.exists()) {
      _transfers.enqueueDownload(file);
      sweep.report.downloaded++;
      return;
    }

    final backup = File(conflictName(local.path, DateTime.now()));
    try {
      await local.rename(backup.path);
    } on FileSystemException {
      // Отложить не вышло — трогать местную копию нельзя, иначе правка
      // пропадёт. Оставляем как есть: файл так и висит в расхождении.
      return;
    }

    _conflicts.add(SyncConflict(
      remotePath: file.path,
      backup: backup,
      at: DateTime.now(),
    ));
    sweep.report.conflicts++;
    _transfers.enqueueDownload(file);
    notifyListeners();
  }

  /// Файла на сервере больше нет.
  Future<void> _vanished(VaultEntry entry, _Sweep sweep) async {
    if (_vault.isBusy(entry.path)) {
      sweep.act(entry.path);
      return;
    }

    // Здесь его правили — местная работа важнее чужого удаления,
    // возвращаем её на сервер.
    if (_vault.isDirty(entry.path)) {
      final local = _vault.localFile(entry.path);
      if (await local.exists()) {
        _transfers.enqueueUpload(local, entry.path);
        sweep.report.uploaded++;
        sweep.act(entry.path);
        return;
      }
    }

    await _vault.evict(entry.path);
    sweep.report.removed++;
    sweep.act(entry.path);
  }

  /// Местная правка в поддереве, куда обход не заходил.
  Future<void> _pushIfDirty(VaultEntry entry, _Sweep sweep) async {
    if (_vault.isBusy(entry.path) || !_vault.isDirty(entry.path)) return;

    final local = _vault.localFile(entry.path);
    if (!await local.exists()) return;
    _transfers.enqueueUpload(local, entry.path);
    sweep.report.uploaded++;
    sweep.act(entry.path);
  }

  /// Файлы, появившиеся на диске в синхронизируемой папке.
  Future<void> _pushNewLocal(String dir, _Sweep sweep) async {
    final root = Directory(dir.isEmpty ? _vault.root.path : _vault.localFile(dir).path);
    if (!await root.exists()) return;

    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;

      final name = p.basename(entity.path);
      if (isSkipped(name)) continue;

      final remote = _vault.remotePathOf(entity.path);
      if (remote == null) continue;
      if (sweep.onServer.containsKey(remote)) continue;
      // Индекс про него знает — значит, это пропавшее на сервере или
      // непройденное поддерево, и с ним уже разобрались выше.
      if (_vault.entry(remote) != null) continue;
      if (_vault.isBusy(remote)) continue;

      final cut = remote.lastIndexOf('/');
      await _ensureRemoteDir(cut < 0 ? '' : remote.substring(0, cut), sweep.serverDirs);
      _transfers.enqueueUpload(entity, remote);
      sweep.report.uploaded++;
      sweep.act(remote);
    }
  }

  /// Создаёт папку на сервере вместе с недостающими родителями.
  Future<void> _ensureRemoteDir(String dir, Set<String> known) async {
    if (dir.isEmpty || known.contains(dir)) return;

    final cut = dir.lastIndexOf('/');
    await _ensureRemoteDir(cut < 0 ? '' : dir.substring(0, cut), known);
    try {
      await _dav.mkdir(dir);
    } on NextcloudException catch (e) {
      // 405 — папка уже есть, это не ошибка.
      if (e.statusCode != 405) rethrow;
    }
    known.add(dir);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
