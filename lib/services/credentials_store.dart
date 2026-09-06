import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'webdav_client.dart';

/// Хранение учётных записей. На Windows flutter_secure_storage кладёт запись
/// в Credential Manager — на диск в открытом виде пароль приложения не ложится.
///
/// Записей может быть несколько: по одной на облако, а при желании и по
/// несколько на одно. Активна всегда одна — та, чьи файлы сейчас на экране.
class CredentialsStore {
  static const _key = 'nexus_nimbus.accounts';

  /// Ключ прежних версий: там лежала ровно одна запись без обёртки.
  static const _legacyKey = 'nexus_nimbus.account';

  static const _storage = FlutterSecureStorage(
    wOptions: WindowsOptions(useBackwardCompatibility: false),
  );

  /// Все записи и та, что выбрана сейчас.
  Future<({List<NxAccount> accounts, String? activeId})> loadAll() async {
    final raw = await _storage.read(key: _key);
    if (raw != null && raw.isNotEmpty) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        final accounts = (j['accounts'] as List<dynamic>? ?? const [])
            .map((e) => NxAccount.fromJson(e as Map<String, dynamic>))
            .toList();
        return (accounts: accounts, activeId: j['active'] as String?);
      } catch (_) {
        // Запись из несовместимой версии — проще забыть, чем чинить.
        await _storage.delete(key: _key);
      }
    }
    return _migrateLegacy();
  }

  /// Единственная запись прежних версий переезжает в общий список.
  /// Хранилище файлов при этом остаётся на месте: его путь привязан к
  /// имени записи, а имя из тех же полей и складывается.
  Future<({List<NxAccount> accounts, String? activeId})> _migrateLegacy() async {
    final raw = await _storage.read(key: _legacyKey);
    if (raw == null || raw.isEmpty) return (accounts: <NxAccount>[], activeId: null);

    try {
      final account = NxAccount.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      await _write([account], account.id);
      await _storage.delete(key: _legacyKey);
      return (accounts: [account], activeId: account.id);
    } catch (_) {
      await _storage.delete(key: _legacyKey);
      return (accounts: <NxAccount>[], activeId: null);
    }
  }

  /// Активная запись — с неё начинается работа при запуске.
  Future<NxAccount?> load() async {
    final all = await loadAll();
    if (all.accounts.isEmpty) return null;
    for (final a in all.accounts) {
      if (a.id == all.activeId) return a;
    }
    return all.accounts.first;
  }

  /// Добавляет запись или обновляет уже сохранённую и делает её активной.
  /// Запись с тем же [NxAccount.id] заменяется: это тот же диск того же
  /// человека, просто с новым паролем или другим отображаемым именем.
  Future<void> save(NxAccount account) async {
    final all = await loadAll();
    final list = all.accounts.where((a) => a.id != account.id).toList()..add(account);
    await _write(list, account.id);
  }

  Future<void> setActive(String id) async {
    final all = await loadAll();
    if (!all.accounts.any((a) => a.id == id)) return;
    await _write(all.accounts, id);
  }

  /// Забыть одну запись. Возвращает ту, что стала активной вместо неё,
  /// или null, если записей не осталось.
  Future<NxAccount?> remove(String id) async {
    final all = await loadAll();
    final list = all.accounts.where((a) => a.id != id).toList();
    if (list.isEmpty) {
      await clear();
      return null;
    }
    final next = all.activeId == id ? list.first : list.firstWhere(
          (a) => a.id == all.activeId,
          orElse: () => list.first,
        );
    await _write(list, next.id);
    return next;
  }

  Future<void> clear() async {
    await _storage.delete(key: _key);
    await _storage.delete(key: _legacyKey);
  }

  Future<void> _write(List<NxAccount> accounts, String? activeId) => _storage.write(
        key: _key,
        value: jsonEncode({
          'accounts': accounts.map((a) => a.toJson()).toList(),
          'active': activeId,
        }),
      );
}
