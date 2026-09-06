/// Публичная ссылка на файл или папку.
///
/// Живёт на сервере, а не у нас: клиент её только создаёт, показывает и
/// убирает. Всё, что ниже, приходит из OCS Sharing API.
class PublicLink {
  const PublicLink({
    required this.id,
    required this.url,
    this.label,
    this.expiresAt,
    this.hasPassword = false,
    this.permissions = read,
  });

  /// Только смотреть и скачивать.
  static const read = 1;

  /// Смотреть, скачивать, класть своё и менять. Годится только для папки:
  /// у файла сервер такую ссылку не создаст.
  static const readWrite = 15;

  /// Идентификатор доли на сервере — им она обновляется и удаляется.
  final String id;

  /// Адрес, который отдают человеку.
  final String url;

  /// Подпись, если ссылку назвали.
  final String? label;

  /// Когда ссылка перестанет работать. Null — бессрочно.
  final DateTime? expiresAt;

  final bool hasPassword;
  final int permissions;

  bool get canUpload => permissions != read;

  bool get expired {
    final at = expiresAt;
    return at != null && at.isBefore(DateTime.now());
  }

  /// Разбор одной записи из ответа OCS. Сервер отдаёт числа то числами,
  /// то строками, поэтому всё приводим сами.
  static PublicLink fromJson(Map<String, dynamic> j) {
    final expire = (j['expiration'] as String?)?.trim();
    final password = j['share_with'];

    return PublicLink(
      id: '${j['id']}',
      url: (j['url'] as String?) ?? '',
      label: _clean(j['label'] as String?) ?? _clean(j['note'] as String?),
      expiresAt: (expire == null || expire.isEmpty) ? null : DateTime.tryParse(expire),
      // У ссылки с паролем сервер кладёт его хэш в share_with.
      hasPassword: password != null && '$password'.isNotEmpty,
      permissions: int.tryParse('${j['permissions']}') ?? read,
    );
  }

  static String? _clean(String? v) => (v == null || v.trim().isEmpty) ? null : v.trim();
}
