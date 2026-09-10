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

/// Как именно вещь роздана наружу — значения `oc:share-types`. Список у
/// Nextcloud длиннее, но остальное встречается редко, и валить всё в одну
/// кучу честнее, чем притворяться, что мы знаем про каждый вид.
enum ShareKind {
  user,
  group,
  link,
  email,
  federated,
  talk,
  other;

  static ShareKind byCode(int code) => switch (code) {
        0 => ShareKind.user,
        1 || 2 || 12 => ShareKind.group,
        3 => ShareKind.link,
        4 => ShareKind.email,
        6 || 13 => ShareKind.federated,
        10 => ShareKind.talk,
        _ => ShareKind.other,
      };

  String get label => switch (this) {
        ShareKind.user => 'человеку',
        ShareKind.group => 'группе',
        ShareKind.link => 'по ссылке',
        ShareKind.email => 'по почте',
        ShareKind.federated => 'на другой сервер',
        ShareKind.talk => 'в разговор',
        ShareKind.other => 'ещё куда-то',
      };
}

/// Контрольные суммы от сервера. Nextcloud держит их одной строкой вида
/// `SHA1:0beec7b5 MD5:900150983`: считает при заливке и с тех пор хранит
/// рядом с файлом, поэтому скачанное можно сверить, ничего не спрашивая
/// дополнительно.
class Checksums {
  const Checksums(this._byType);

  /// Пусто, если сервер сумм не считал — так бывает у файлов, залитых
  /// мимо клиента, и на серверах без включённой проверки.
  factory Checksums.parse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const Checksums({});
    final out = <String, String>{};
    for (final part in raw.trim().split(RegExp(r'\s+'))) {
      final i = part.indexOf(':');
      if (i <= 0 || i == part.length - 1) continue;
      out[part.substring(0, i).toUpperCase()] = part.substring(i + 1).toLowerCase();
    }
    return Checksums(out);
  }

  final Map<String, String> _byType;

  String? get sha1 => _byType['SHA1'];
  String? get md5 => _byType['MD5'];
  bool get isEmpty => _byType.isEmpty;
  bool get isNotEmpty => _byType.isNotEmpty;

  /// Какую сумму считать у себя. SHA-1 надёжнее, но если сервер посчитал
  /// только MD5 — сверяем по нему: сверка ловит битую передачу, а не
  /// злонамеренную подмену, и для этого MD5 хватает.
  ({String type, String value})? get preferred {
    final s = sha1;
    if (s != null) return (type: 'SHA1', value: s);
    final m = md5;
    if (m != null) return (type: 'MD5', value: m);
    return null;
  }

  @override
  String toString() => _byType.entries.map((e) => '${e.key}:${e.value}').join(' ');
}

/// Блокировка файла на сервере — приложение `files_lock`, Nextcloud 24
/// и новее. В отличие от WebDAV-блокировки, эта видна всем и переживает
/// перезапуск: сервер помнит, кто именно держит файл.
class FileLock {
  const FileLock({
    required this.owner,
    this.ownerDisplayName,
    this.ownerType = 0,
    this.since,
    this.timeout,
  });

  /// Учётное имя того, кто держит файл.
  final String owner;
  final String? ownerDisplayName;

  /// 0 — человек, 1 — приложение (например, редактор), 2 — маркер.
  final int ownerType;

  final DateTime? since;

  /// Через сколько блокировка спадёт сама. Ноль или null — бессрочная.
  final Duration? timeout;

  /// Имя для показа: человеческое сервер отдаёт не всегда.
  String get who =>
      (ownerDisplayName?.trim().isNotEmpty ?? false) ? ownerDisplayName!.trim() : owner;

  bool get byApp => ownerType == 1;

  DateTime? get expiresAt {
    final start = since;
    final t = timeout;
    if (start == null || t == null || t <= Duration.zero) return null;
    return start.add(t);
  }

  bool get expired {
    final end = expiresAt;
    return end != null && end.isBefore(DateTime.now());
  }

  /// Наша ли это блокировка. Имена на сервере регистронезависимы.
  bool byMe(String? login) => login != null && owner.toLowerCase() == login.toLowerCase();
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
    this.shareTypes = const [],
    this.created,
    this.uploaded,
    this.checksums = const Checksums({}),
    this.folderCount,
    this.fileCount,
    this.lock,
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

  /// Чем эта вещь роздана наружу. Пустой список — ничем.
  final List<ShareKind> shareTypes;

  /// Когда файл создан и когда попал на сервер. Это разные даты: скачанный
  /// откуда-то файл создан год назад, а залит сегодня.
  final DateTime? created;
  final DateTime? uploaded;

  final Checksums checksums;

  /// Сколько внутри папок и файлов. Null — сервер не сказал (у файлов
  /// всегда, у папок — на серверах постарше).
  final int? folderCount;
  final int? fileCount;

  /// Кто держит файл, если его держат.
  final FileLock? lock;

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

  /// Этим поделились с нами — право S приходит от сервера.
  bool get isShared => permissions.contains('S');

  /// Мы раздали это наружу.
  bool get isSharedOut => shareTypes.isNotEmpty;

  bool get isLocked => lock != null;

  /// Знает ли сервер, сколько лежит внутри папки.
  bool get hasCounts => folderCount != null || fileCount != null;

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
        shareTypes: shareTypes,
        created: created,
        uploaded: uploaded,
        checksums: checksums,
        folderCount: folderCount,
        fileCount: fileCount,
        lock: lock,
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
