import 'dart:io';
import 'dart:typed_data';

import '../core/models/file_version.dart';
import '../core/models/public_link.dart';
import '../core/models/remote_file.dart';
import '../core/models/trash_item.dart';
import 'webdav_client.dart'
    show NxAccount, NextcloudException, CancelToken, ProgressCallback;

/// Договор между приложением и облаком.
///
/// Обязательна только середина: перечислить папку, скачать, отправить,
/// создать, переименовать, удалить, спросить место. Это умеет любое
/// хранилище, и на этом держатся передачи, синхронизация и слежение
/// за правками.
///
/// Всё остальное — корзина, версии, публичные ссылки, избранное, поиск,
/// миниатюры — расширения, которых у большинства облаков нет. Здесь у них
/// одна общая заглушка: внятный отказ вместо непонятной ошибки. Что именно
/// доступно, объявляет [CloudProvider] у учётной записи, и интерфейс прячет
/// то, чего нет, ещё до вызова.
abstract class StorageBackend {
  const StorageBackend();

  NxAccount get account;

  void close();

  // ------------------------------------------------------------ обязательное

  /// Содержимое папки. Пустой путь — корень.
  Future<List<RemoteFile>> list(String path);

  /// Свойства одной записи без содержимого папки.
  Future<RemoteFile> stat(String path);

  Future<void> mkdir(String path);

  Future<void> delete(String path);

  Future<void> move(String from, String to, {bool overwrite = false});

  Future<void> copy(String from, String to, {bool overwrite = false});

  /// Скачивание прямо в файл, потоком: большие файлы в память не берём.
  Future<void> download(
    String path,
    File target, {
    ProgressCallback? onProgress,
    CancelToken? cancel,
    Uri? from,
  });

  /// Содержимое потоком, без записи на диск. Нужно перетаскиванию наружу.
  Future<({Stream<List<int>> stream, int length})> openRead(String path);

  Future<void> upload(
    File source,
    String path, {
    ProgressCallback? onProgress,
    CancelToken? cancel,
  });

  Future<Quota> quota();

  /// Проверка учётных данных: заодно достаём отображаемое имя.
  Future<String> verify();

  // ------------------------------------------------------------- расширения

  /// Байты миниатюры. null — превью для этого файла облако не отдало.
  Future<Uint8List?> preview(String fileId, {int size = 256}) async => null;

  Future<List<RemoteFile>> favorites() => _no('Избранное');

  Future<void> setFavorite(String path, bool favorite) => _no('Избранное');

  Future<List<RemoteFile>> search(String query, {int limit = 100}) =>
      _no('Поиск по дереву');

  Future<List<FileVersion>> listVersions(String fileId) => _no('Версии файлов');

  Future<void> restoreVersion(String fileId, String versionId) =>
      _no('Версии файлов');

  Future<List<TrashItem>> listTrash() => _no('Корзина сервера');

  Future<void> restoreFromTrash(TrashItem item) => _no('Корзина сервера');

  Future<void> deleteFromTrash(TrashItem item) => _no('Корзина сервера');

  Future<void> emptyTrash() => _no('Корзина сервера');

  Future<List<PublicLink>> listLinks(String path) => _no('Публичные ссылки');

  Future<PublicLink> createLink(
    String path, {
    String? password,
    DateTime? expiresAt,
    bool allowUpload = false,
  }) =>
      _no('Публичные ссылки');

  Future<void> deleteLink(String id) => _no('Публичные ссылки');

  /// Адрес записи в веб-интерфейсе облака. null — открывать нечего.
  Uri? webUrl(RemoteFile file) => null;

  Future<Never> _no(String what) => Future.error(
        NextcloudException(
          '$what — ${account.provider.label} такого не умеет.',
        ),
      );
}
