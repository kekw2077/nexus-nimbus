import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/credentials_store.dart';
import '../services/webdav_client.dart';
import 'session.dart';

enum AppStage { starting, disconnected, connecting, connected }

/// Верхний уровень: есть ли сохранённая учётная запись, идёт ли вход,
/// живая сессия. Всё, что ниже, живёт внутри [Session].
class AppState extends ChangeNotifier {
  AppState(this._store);

  final CredentialsStore _store;

  AppStage _stage = AppStage.starting;
  Session? _session;
  String? _error;

  AppStage get stage => _stage;
  Session? get session => _session;
  String? get error => _error;

  /// Попытка войти сохранённым паролем приложения при запуске.
  Future<void> restore() async {
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
      _set(AppStage.disconnected);
      rethrow;
    }
  }

  Future<void> _attach(NxAccount account, {required bool verify}) async {
    var resolved = account;
    if (verify) {
      final probe = WebDavClient(account);
      try {
        // Один PROPFIND корня — самая честная проверка: он же и покажет,
        // что WebDAV вообще доступен по этому адресу.
        await probe.list('');
        resolved = account.copyWith(displayName: await probe.verify());
      } finally {
        probe.close();
      }
      await _store.save(resolved);
    }

    _session?.dispose();
    final session = await Session.create(resolved);
    _session = session;
    session.addListener(notifyListeners);
    _set(AppStage.connected);
    unawaited(session.open(''));
  }

  Future<void> disconnect({bool forget = true}) async {
    _session?.removeListener(notifyListeners);
    _session?.dispose();
    _session = null;
    if (forget) await _store.clear();
    _error = null;
    _set(AppStage.disconnected);
  }

  void _set(AppStage stage) {
    _stage = stage;
    notifyListeners();
  }
}
