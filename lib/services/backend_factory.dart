import '../core/models/cloud_provider.dart';
import 'google/drive_client.dart';
import 'google/google_auth.dart';
import 'storage_backend.dart';
import 'webdav_client.dart';

/// Собирает клиента под облако учётной записи.
///
/// Одно место на всё приложение: и рабочая сессия, и проверка при входе
/// должны получать один и тот же клиент, иначе проверка удостоверила бы
/// одно, а работало бы другое.
StorageBackend createBackend(NxAccount account, {GoogleClientId? google}) {
  switch (account.provider) {
    case CloudProvider.nextcloud:
    case CloudProvider.yandex:
      return WebDavClient(account);

    case CloudProvider.google:
      if (google == null || google.isEmpty) {
        throw NextcloudException(
          'Не заданы учётные данные приложения Google. Настройки → '
          '«Учётные записи» → Google Drive.',
        );
      }
      return GoogleDriveClient(account, GoogleAuth(google));
  }
}
