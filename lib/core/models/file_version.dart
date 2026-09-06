/// Одна сохранённая версия файла.
///
/// Версии живёт отдельным деревом на сервере: `…/dav/versions/{user}/versions/
/// {fileid}/{id}`. Адресуется всё по числовому [id] — это unix-время, когда
/// версия была снята, — а не по имени: имени у версии нет.
class FileVersion {
  const FileVersion({
    required this.id,
    required this.size,
    this.savedAt,
    this.label,
    this.mimeType,
  });

  /// Последний сегмент пути версии. Им же она восстанавливается.
  final String id;

  final int size;

  /// Когда версия была снята. Сервер отдаёт это и датой, и в самом [id].
  final DateTime? savedAt;

  /// Подпись, если версию назвали руками в веб-интерфейсе.
  final String? label;

  final String? mimeType;

  /// Версия, снятая с файла, который сейчас на сервере, отличается от него
  /// только временем — по нему их и различают в списке.
  DateTime? get when => savedAt ?? _fromId;

  DateTime? get _fromId {
    final seconds = int.tryParse(id);
    if (seconds == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true).toLocal();
  }
}
