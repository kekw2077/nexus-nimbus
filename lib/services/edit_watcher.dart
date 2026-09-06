import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'transfer_queue.dart';
import 'vault.dart';

/// Замеченная правка, ещё не отправленная на сервер.
class PendingEdit {
  PendingEdit({required this.remotePath, required this.size, required this.at});

  final String remotePath;
  final int size;

  /// Когда правку заметили. По нему интерфейс понимает, что предложение
  /// новое, а не то же самое во второй раз.
  final DateTime at;

  String get name => p.basename(remotePath);
}

/// Следит за папкой хранилища и замечает, что файл правили здесь —
/// в Блокноте, в Word, в чём угодно, чем его открыли двойным кликом.
///
/// Событие файловой системы само по себе ничего не значит. Редактор пишет
/// файл частями, а Word и Excel вовсе сохраняют во временный файл и
/// переименовывают его на место исходного — за одно сохранение прилетает
/// пачка событий, и первое из них приходит на полуготовый файл. Поэтому
/// после каждого события ждём тишины [_settle] и только потом сверяемся
/// с индексом хранилища.
///
/// Слежение — удобство, а не обязанность: если система его не даёт, правки
/// всё равно найдёт [Vault.audit] при следующем открытии папки.
class EditWatcher extends ChangeNotifier {
  EditWatcher(this._vault, this._transfers, {bool autoPush = true}) {
    _autoPush = autoPush;
    _vault.addListener(_onVault);
  }

  final Vault _vault;
  final TransferQueue _transfers;

  /// Тишина после последнего события, после которой файл считается дописанным.
  static const _settle = Duration(milliseconds: 1200);

  /// Файл может быть ещё заперт редактором — пробуем позже, но не бесконечно.
  static const _retry = Duration(seconds: 2);
  static const _maxAttempts = 15;

  StreamSubscription<FileSystemEvent>? _sub;
  String? _watching;

  final Map<String, Timer> _settling = {};
  final Map<String, int> _attempts = {};
  final List<PendingEdit> _pending = [];

  late bool _autoPush;

  /// Отправлять замеченные правки сразу или только показывать их.
  bool get autoPush => _autoPush;

  set autoPush(bool value) {
    if (_autoPush == value) return;
    _autoPush = value;
    // Включили автоотправку, пока что-то ждало решения, — отправляем.
    if (value && _pending.isNotEmpty) {
      pushAll();
    } else {
      notifyListeners();
    }
  }

  /// Следим ли за папкой прямо сейчас. Ложь — система слежение не дала;
  /// правки от этого не теряются, просто находятся позже.
  bool get watching => _sub != null;

  /// Правки, замеченные при выключенной автоотправке.
  List<PendingEdit> get pending => List.unmodifiable(_pending);

  /// Последняя из них — по ней показывается предложение отправить.
  PendingEdit? get latest => _pending.isEmpty ? null : _pending.last;

  /// Запускает слежение или перевешивает его, если папка хранилища сменилась.
  void sync() {
    final root = _vault.root.path;
    if (_sub != null && root == _watching) return;

    _stopWatching();
    final dir = Directory(root);
    if (!dir.existsSync()) return;

    try {
      _sub = dir.watch(recursive: true).listen(_onEvent, onError: (_) {
        _stopWatching();
      });
      _watching = root;
    } on FileSystemException {
      // Сетевой диск или снятые права — молча живём без слежения.
      _watching = null;
    }
  }

  /// Отправить одну замеченную правку.
  void push(String remotePath) {
    _drop(remotePath);
    final file = _vault.localFile(remotePath);
    if (file.existsSync()) _transfers.enqueueUpload(file, remotePath);
    notifyListeners();
  }

  void pushAll() {
    for (final edit in _pending.toList()) {
      final file = _vault.localFile(edit.remotePath);
      if (file.existsSync()) _transfers.enqueueUpload(file, edit.remotePath);
    }
    _pending.clear();
    notifyListeners();
  }

  /// Убрать предложение, ничего не отправляя. Файл остаётся помеченным
  /// «изменён, не отправлен» — предложение просто больше не всплывает.
  void dismiss(String remotePath) {
    _drop(remotePath);
    notifyListeners();
  }

  void dismissAll() {
    if (_pending.isEmpty) return;
    _pending.clear();
    notifyListeners();
  }

  // ------------------------------------------------------------ внутреннее

  void _onEvent(FileSystemEvent event) {
    if (event.isDirectory) return;
    _touch(event.path);
    // Переименование временного файла на место исходного — как раз то,
    // чем сохраняются Word и Excel: правка приезжает в destination.
    if (event is FileSystemMoveEvent) {
      final to = event.destination;
      if (to != null) _touch(to);
    }
  }

  void _touch(String localPath) {
    final remote = _vault.remotePathOf(localPath);
    // Следим только за тем, что скачали сами: временные файлы редакторов
    // и всё принесённое в папку руками нас не касается.
    if (remote == null || _vault.entry(remote) == null) return;
    _attempts.remove(remote);
    _arm(remote, _settle);
  }

  void _arm(String remote, Duration delay) {
    _settling[remote]?.cancel();
    _settling[remote] = Timer(delay, () => unawaited(_inspect(remote)));
  }

  Future<void> _inspect(String remote) async {
    _settling.remove(remote);
    final entry = _vault.entry(remote);
    if (entry == null) return;

    // Файл трогает наша же передача — подождём, пока она закончится,
    // иначе примем собственное скачивание за чужую правку.
    if (_vault.isBusy(remote)) {
      _arm(remote, _retry);
      return;
    }

    final file = _vault.localFile(remote);
    final FileStat stat;
    try {
      stat = await file.stat();
    } catch (_) {
      return;
    }
    if (stat.type != FileSystemEntityType.file) return;

    // Совпало с индексом — значит, это следы нашей же записи, а не правка.
    if (stat.modified.millisecondsSinceEpoch == entry.localMtimeMs &&
        stat.size == entry.size) {
      return;
    }

    if (!await _readable(file)) {
      final tries = (_attempts[remote] ?? 0) + 1;
      _attempts[remote] = tries;
      if (tries <= _maxAttempts) _arm(remote, _retry);
      return;
    }
    _attempts.remove(remote);

    _vault.markDirty(remote);
    if (_autoPush) {
      _transfers.enqueueUpload(file, remote);
      return;
    }

    _drop(remote);
    _pending.add(PendingEdit(
      remotePath: remote,
      size: stat.size,
      at: DateTime.now(),
    ));
    notifyListeners();
  }

  /// Пока редактор держит файл открытым, прочитать его нельзя — отправлять
  /// такой файл значит отправить обрезок.
  Future<bool> _readable(File file) async {
    RandomAccessFile? handle;
    try {
      handle = await file.open();
      return true;
    } on FileSystemException {
      return false;
    } finally {
      await handle?.close();
    }
  }

  void _onVault() {
    // Папку хранилища могли сменить в настройках — слежение переезжает.
    sync();
    // Правку могли отправить и вручную, из меню файла: тогда предложение
    // снимается само.
    final before = _pending.length;
    _pending.removeWhere((e) => !_vault.isDirty(e.remotePath));
    if (_pending.length != before) notifyListeners();
  }

  void _drop(String remote) => _pending.removeWhere((e) => e.remotePath == remote);

  void _stopWatching() {
    unawaited(_sub?.cancel());
    _sub = null;
    _watching = null;
  }

  @override
  void dispose() {
    _vault.removeListener(_onVault);
    _stopWatching();
    for (final timer in _settling.values) {
      timer.cancel();
    }
    _settling.clear();
    super.dispose();
  }
}
