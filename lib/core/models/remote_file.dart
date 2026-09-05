import 'package:path/path.dart' as p;

/// Где сейчас находится файл. Это то, чего не хватает официальному клиенту:
/// у каждой строки списка есть один недвусмысленный статус.
enum Presence {
  /// Только на сервере. На диске ничего нет.
  remote,

  /// Прямо сейчас качается или заливается.
  transferring,

  /// Лежит в кэше и совпадает с сервером. Можно вычистить в любой момент.
  cached,

  /// Закреплён: держим локально всегда, автоочистка не трогает.
  pinned,

  /// Локальная копия изменена и ещё не отправлена на сервер.
  dirty,

  /// Локальная копия есть, но на сервере файл с тех пор изменился.
  outdated,

  /// И локально, и на сервере изменилось после последней синхронизации.
  conflict,
}

extension PresenceInfo on Presence {
  String get label => switch (this) {
        Presence.remote => 'Только на сервере',
        Presence.transferring => 'Передаётся',
        Presence.cached => 'Есть локально',
        Presence.pinned => 'Закреплён локально',
        Presence.dirty => 'Изменён, не отправлен',
        Presence.outdated => 'Локальная копия устарела',
        Presence.conflict => 'Конфликт версий',
      };

  /// Есть ли у файла копия на диске. От этого зависит, показывать ли
  /// «Открыть» без скачивания и учитывать ли файл в занятом месте.
  bool get isLocal => this != Presence.remote;
}

/// Запись из PROPFIND. Поля etag/fileId/size хранятся даже там, где сейчас
/// не нужны — на них будет опираться двусторонняя синхронизация.
class RemoteFile {
  const RemoteFile({
    required this.path,
    required this.isDir,
    this.size = 0,
    this.modified,
    this.etag,
    this.fileId,
    this.mimeType,
    this.hasPreview = false,
    this.favorite = false,
    this.permissions = '',
  });

  /// Путь относительно корня пользователя, без ведущего и хвостового слэша.
  /// Корень — пустая строка.
  final String path;
  final bool isDir;

  /// Для файлов — getcontentlength, для папок — oc:size (рекурсивный размер).
  final int size;
  final DateTime? modified;
  final String? etag;
  final String? fileId;
  final String? mimeType;
  final bool hasPreview;
  final bool favorite;

  /// Строка вида "RGDNVCK". D — можно удалить, NV — переименовать/переместить,
  /// W — писать, CK — создавать внутри.
  final String permissions;

  String get name => path.isEmpty ? 'Все файлы' : p.basename(path);
  String get parent {
    if (path.isEmpty) return '';
    final i = path.lastIndexOf('/');
    return i < 0 ? '' : path.substring(0, i);
  }

  String get extension => isDir ? '' : p.extension(path).replaceFirst('.', '').toLowerCase();

  bool get canDelete => permissions.contains('D');
  bool get canRename => permissions.contains('N') || permissions.contains('V');
  bool get canWrite => permissions.contains('W');
  bool get isShared => permissions.contains('S');

  RemoteFile copyWith({String? path}) => RemoteFile(
        path: path ?? this.path,
        isDir: isDir,
        size: size,
        modified: modified,
        etag: etag,
        fileId: fileId,
        mimeType: mimeType,
        hasPreview: hasPreview,
        favorite: favorite,
        permissions: permissions,
      );

  @override
  bool operator ==(Object other) => other is RemoteFile && other.path == path && other.etag == etag;

  @override
  int get hashCode => Object.hash(path, etag);
}

/// Квота пользователя. -3 в used/available означает «не ограничено».
class Quota {
  const Quota({required this.used, required this.total});
  final int used;
  final int total;

  bool get unlimited => total <= 0;
  double get fraction => unlimited ? 0 : (used / total).clamp(0.0, 1.0);
}
