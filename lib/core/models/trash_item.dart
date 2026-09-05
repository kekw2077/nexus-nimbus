import 'package:path/path.dart' as p;

/// Запись в корзине сервера.
///
/// Имя внутри корзины — служебное (`<имя>.d<время удаления>`), поэтому
/// показывать надо `nc:trashbin-filename`, а обращаться к серверу — по [id].
class TrashItem {
  const TrashItem({
    required this.id,
    required this.name,
    required this.originalLocation,
    required this.isDir,
    this.size = 0,
    this.deletedAt,
    this.fileId,
    this.mimeType,
  });

  /// Последний сегмент пути внутри корзины: им адресуются восстановление
  /// и окончательное удаление.
  final String id;

  /// Настоящее имя, каким файл был до удаления.
  final String name;

  /// Путь, откуда файл удалили, относительно корня пользователя.
  /// Пустая строка — корень.
  final String originalLocation;

  final bool isDir;
  final int size;
  final DateTime? deletedAt;
  final String? fileId;
  final String? mimeType;

  String get extension => isDir ? '' : p.extension(name).replaceFirst('.', '').toLowerCase();

  /// Папка, в которую файл вернётся при восстановлении.
  String get restoreFolder {
    final i = originalLocation.lastIndexOf('/');
    return i < 0 ? '' : originalLocation.substring(0, i);
  }
}
