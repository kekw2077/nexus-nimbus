/// Какое облако стоит за учётной записью.
///
/// Клиент разговаривает обычным WebDAV, а всё, что сверх него — корзина,
/// миниатюры, чанковая выгрузка, избранное, версии, ссылки, поиск — это
/// расширения Nextcloud. Поэтому облако описывается не только именем, но и
/// тем, что оно умеет: интерфейс прячет то, чего на этом сервере нет, а не
/// показывает кнопки, которые молча не работают.
enum CloudProvider {
  nextcloud,
  yandex,
  google;

  String get label => switch (this) {
        CloudProvider.nextcloud => 'Nextcloud',
        CloudProvider.yandex => 'Яндекс.Диск',
        CloudProvider.google => 'Google Drive',
      };

  /// Вход паролем приложения. У Google его нет: к Диску ведёт только
  /// разрешение в браузере, и только заранее зарегистрированному приложению.
  bool get hasPasswordLogin => this != CloudProvider.google;

  // ---------------------------------------------------------------- адреса

  /// Адрес сервера, если он один на всех. Null — адрес вводит человек.
  Uri? get fixedServer => switch (this) {
        CloudProvider.yandex => _yandexDav,
        CloudProvider.nextcloud || CloudProvider.google => null,
      };

  static final _yandexDav = Uri.parse('https://webdav.yandex.ru');

  /// Путь до корня файлов после базового адреса.
  ///
  /// У Nextcloud файлы лежат в `/remote.php/dav/files/{user}`, у Яндекса
  /// корень WebDAV и есть корень диска.
  /// Путь до корня файлов после базового адреса — для облаков, говорящих
  /// WebDAV. У Google Drive путей нет вовсе, там свой клиент.
  List<String> filesRoot(String loginName) => switch (this) {
        CloudProvider.nextcloud => ['remote.php', 'dav', 'files', loginName],
        CloudProvider.yandex || CloudProvider.google => const [],
      };

  // ------------------------------------------------------------ что умеет

  /// Расширения Nextcloud. У обычного WebDAV их нет — и это не поломка.
  bool get _nextcloudOnly => this == CloudProvider.nextcloud;

  /// Корзина сервера: удалённое можно достать обратно.
  bool get hasTrash => _nextcloudOnly;

  /// Миниатюры с сервера.
  bool get hasPreviews => _nextcloudOnly;

  /// Выгрузка большого файла кусками с последующей сборкой.
  bool get hasChunkedUpload => _nextcloudOnly;

  bool get hasFavorites => _nextcloudOnly;

  bool get hasVersions => _nextcloudOnly;

  /// Публичные ссылки через OCS.
  bool get hasShares => _nextcloudOnly;

  /// Поиск по дереву через WebDAV SEARCH.
  bool get hasSearch => _nextcloudOnly;

  /// Вход через браузер (Login Flow v2).
  bool get hasBrowserLogin => _nextcloudOnly;

  /// Где взять пароль приложения — подсказка на форме входа.
  String get passwordHint => switch (this) {
        CloudProvider.nextcloud =>
          'Настройки → Безопасность → «Устройства и сеансы» → создать пароль',
        CloudProvider.yandex =>
          'id.yandex.ru → Безопасность → «Пароли приложений» → «Файлы (WebDAV)»',
        CloudProvider.google => '',
      };

  static CloudProvider byName(String? name) {
    for (final v in CloudProvider.values) {
      if (v.name == name) return v;
    }
    return CloudProvider.nextcloud;
  }
}
