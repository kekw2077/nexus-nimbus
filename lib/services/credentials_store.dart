import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'webdav_client.dart';

/// Хранение учётной записи. На Windows flutter_secure_storage кладёт запись
/// в Credential Manager — на диск в открытом виде пароль приложения не ложится.
class CredentialsStore {
  static const _key = 'nexus_nimbus.account';

  static const _storage = FlutterSecureStorage(
    wOptions: WindowsOptions(useBackwardCompatibility: false),
  );

  Future<NxAccount?> load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return null;
    try {
      return NxAccount.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      // Запись из несовместимой версии — проще забыть, чем чинить.
      await clear();
      return null;
    }
  }

  Future<void> save(NxAccount account) =>
      _storage.write(key: _key, value: jsonEncode(account.toJson()));

  Future<void> clear() => _storage.delete(key: _key);
}
