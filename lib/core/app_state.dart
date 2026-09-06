import 'dart:async';

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../services/backend_factory.dart';
import '../services/credentials_store.dart';
import '../services/google/google_auth.dart';
import '../services/yandex/yandex_auth.dart';
import '../services/prefs.dart';
import '../services/webdav_client.dart';
import 'session.dart';

enum AppStage { starting, disconnected, connecting, connected }

/// Верхний уровень: какие учётные записи сохранены, какая из них сейчас
/// открыта, идёт ли вход. Всё, что ниже, живёт внутри [Session].
///
/// Записей может быть несколько — по одной на облако или по несколько на
/// одно, — но живая сессия всегда одна: переключение закрывает прежнюю и
/// открывает новую. Так у каждой записи своё хранилище, своя синхронизация
/// и свои передачи, и ничто не смешивается.
class AppState extends ChangeNotifier {
  AppState(this._store, this._prefs);

  final CredentialsStore _store;
  final Prefs _prefs;

  AppStage _stage = AppStage.starting;
  Session? _session;
  String? _error;
  List<NxAccount> _accounts = const [];

  AppStage get stage => _stage;
  Session? get session => _session;
  String? get error => _error;

  /// Все сохранённые записи, включая ту, что открыта сейчас.
  List<NxAccount> get accounts => List.unmodifiable(_accounts);

  NxAccount? get active => _session?.account;

  bool has(NxAccount account) => _accounts.any((a) => a.id == account.id);

  /// Учётные данные приложения Google из настроек.
  GoogleClientId get googleClient {
    final saved = _prefs.readGoogleClient();
    return GoogleClientId(id: saved.id, secret: saved.secret);
  }

  Future<void> saveGoogleClient(String id, String secret) async {
    await _prefs.writeGoogleClient(id, secret);
    notifyListeners();
  }

  /// Учётные данные приложения Яндекса из настроек.
  YandexClientId get yandexClient {
    final saved = _prefs.readYandexClient();
    return YandexClientId(id: saved.id, secret: saved.secret);
  }

  Future<void> saveYandexClient(String id, String secret) async {
    await _prefs.writeYandexClient(id, secret);
    notifyListeners();
  }

  /// Попытка открыть последнюю запись при запуске.
  Future<void> restore() async {
    final all = await _store.loadAll();
    _accounts = all.accounts;

    final saved = await _store.load();
    if (saved == null) {
      _set(AppStage.disconnected);
      return;
    }
    _set(AppStage.connecting);
    try {
      await _attach(saved, verify: false);
    } catch (e) {
      _error = e.toString();
      _set(AppStage.disconnected);
    }
  }

  /// Вход по введённым данным: сначала проверяем, потом сохраняем.
  Future<void> connect(NxAccount account) async {
    _error = null;
    _set(AppStage.connecting);
    try {
      await _attach(account, verify: true);
    } catch (e) {
      _error = e.toString();
      // Сорвался вход в новую запись, а прежняя была открыта — возвращаемся
      // к ней, вместо того чтобы выбрасывать человека на экран входа.
      _set(_session == null ? AppStage.disconnected : AppStage.connected);
      rethrow;
    }
  }

  /// Открыть уже сохранённую запись.
  Future<void> switchTo(NxAccount account) async {
    if (_session?.account.id == account.id) return;
    _error = null;
    _set(AppStage.connecting);
    try {
      await _store.setActive(account.id);
      await _attach(account, verify: false);
    } catch (e) {
      _error = e.toString();
      _set(_session == null ? AppStage.disconnected : AppStage.connected);
    }
  }

  Future<void> _attach(NxAccount account, {required bool verify}) async {
    var resolved = account;
    if (verify) {
      final probe = createBackend(account, google: googleClient);
      try {
        // Перечисление корня — самая честная проверка: она же и покажет,
        // что облако вообще отвечает по этому адресу.
        await probe.list('');
        resolved = account.copyWith(displayName: await probe.verify());
      } finally {
        probe.close();
      }
      await _store.save(resolved);
      _accounts = (await _store.loadAll()).accounts;
    }

    _session?.removeListener(notifyListeners);
    _session?.dispose();

    // Папка хранилища у каждой записи своя; пустая — папка по умолчанию.
    final root = _prefs.readVaultRoot(resolved.slug);
    final session = await Session.create(
      resolved,
      createBackend(resolved, google: googleClient),
      vaultRoot: root.isEmpty ? null : Directory(root),
      autoPushEdits: _prefs.readAutoPushEdits(),
      syncEnabled: _prefs.readSyncEnabled(),
      syncEverything: _prefs.readSyncEverything(),
      syncInterval: Duration(minutes: _prefs.readSyncInterval()),
    );
    _session = session;

    // Путь запоминаем всегда, даже когда он получился сам: со следующего
    // запуска запись будет искать файлы там же, а не там, где на тот момент
    // окажется папка по умолчанию.
    if (root != session.vault.root.path) {
      await _prefs.writeVaultRoot(resolved.slug, session.vault.root.path);
    }

    session.addListener(notifyListeners);
    _set(AppStage.connected);
    unawaited(session.open(''));
  }

  /// Забыть запись. Если она была открыта — открываем следующую, а когда
  /// записей не осталось, уходим на экран входа.
  Future<void> forget(NxAccount account) async {
    final next = await _store.remove(account.id);
    _accounts = (await _store.loadAll()).accounts;

    if (_session?.account.id != account.id) {
      notifyListeners();
      return;
    }
    if (next == null) {
      await disconnect(forget: false);
      return;
    }
    await switchTo(next);
  }

  /// Закрыть сессию и уйти на экран входа. [forget] стирает все записи —
  /// это «выйти совсем», а не «переключиться».
  Future<void> disconnect({bool forget = true}) async {
    _session?.removeListener(notifyListeners);
    _session?.dispose();
    _session = null;
    if (forget) {
      await _store.clear();
      _accounts = const [];
    }
    _error = null;
    _set(AppStage.disconnected);
  }

  void _set(AppStage stage) {
    _stage = stage;
    notifyListeners();
  }
}
