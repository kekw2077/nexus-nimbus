/// Какое облако стоит за учётной записью.
///
/// Облака говорят на разных языках: Nextcloud и обычные серверы — WebDAV,
/// Яндекс.Диск и Google Drive — своими REST API. Поэтому облако описывается
/// не только именем, но и тем, что оно умеет: интерфейс прячет то, чего нет,
/// а не показывает кнопки, которые молча не сработают.
enum CloudProvider {
  nextcloud,
  yandex,
  google;

  String get label => switch (this) {
        CloudProvider.nextcloud => 'Nextcloud',
        CloudProvider.yandex => 'Яндекс.Диск',
        CloudProvider.google => 'Google Drive',
      };

  // ---------------------------------------------------------------- адреса

  /// Адрес, если он один на всех. Null — адрес вводит человек.
  ///
  /// У облаков с REST он в запросах не участвует и нужен только затем,
  /// чтобы отличать учётные записи друг от друга.
  Uri? get fixedServer => switch (this) {
        CloudProvider.yandex => _yandexDisk,
        CloudProvider.google => _googleDrive,
        CloudProvider.nextcloud => null,
      };

  static final _yandexDisk = Uri.parse('https://disk.yandex.ru');
  static final _googleDrive = Uri.parse('https://drive.google.com');

  /// Путь до корня файлов после базового адреса — для облаков, говорящих
  /// WebDAV. У REST-облаков свои клиенты, и корня в этом смысле у них нет.
  List<String> filesRoot(String loginName) => switch (this) {
        CloudProvider.nextcloud => ['remote.php', 'dav', 'files', loginName],
        CloudProvider.yandex || CloudProvider.google => const [],
      };

  // ------------------------------------------------------------- как входим

  /// Вход паролем приложения. У Яндекса и Google его нет: у первого WebDAV
  /// оставлен платным подпискам и бесплатным записям отвечает кодом 402,
  /// у второго пароля к Диску нет вовсе. И там, и там дорога одна —
  /// разрешение в браузере.
  bool get hasPasswordLogin => this == CloudProvider.nextcloud;

  /// Нужен ли зарегистрированный OAuth-клиент. Регистрируется один раз
  /// человеком: облако должно знать приложение, которому дают доступ.
  bool get needsOAuth => !hasPasswordLogin;

  /// Вход через браузер по Login Flow v2 — расширение Nextcloud,
  /// к OAuth отношения не имеющее.
  bool get hasBrowserLogin => this == CloudProvider.nextcloud;

  /// Где взять пароль приложения — подсказка на форме входа.
  String get passwordHint => switch (this) {
        CloudProvider.nextcloud =>
          'Настройки → Безопасность → «Устройства и сеансы» → создать пароль',
        CloudProvider.yandex || CloudProvider.google => '',
      };

  /// Что вводить в поле логина — подсказка прямо в поле.
  String get loginHint => switch (this) {
        CloudProvider.nextcloud => 'Имя пользователя',
        CloudProvider.yandex || CloudProvider.google => '',
      };

  /// Где регистрируется приложение.
  String get consoleUrl => switch (this) {
        CloudProvider.yandex => 'https://oauth.yandex.ru/client/new',
        CloudProvider.google => 'https://console.cloud.google.com/apis/credentials',
        CloudProvider.nextcloud => '',
      };

  // ------------------------------------------------------------ что умеет

  /// Корзина: удалённое можно достать обратно.
  bool get hasTrash => this != CloudProvider.google;

  /// Миниатюры с сервера.
  bool get hasPreviews => this != CloudProvider.google;

  /// Выгрузка большого файла кусками с последующей сборкой. Расширение
  /// Nextcloud; у остальных файл уходит одним потоком.
  bool get hasChunkedUpload => this == CloudProvider.nextcloud;

  bool get hasFavorites => this == CloudProvider.nextcloud;

  bool get hasVersions => this == CloudProvider.nextcloud;

  /// Публичные ссылки.
  bool get hasShares => this != CloudProvider.google;

  /// Пароль и срок жизни у публичной ссылки. Яндекс ссылку просто включает
  /// и выключает, ничего к ней не привинчивая.
  bool get hasLinkOptions => this == CloudProvider.nextcloud;

  /// Поиск по всему дереву. У Nextcloud это WebDAV SEARCH; у остальных
  /// подходящей точки нет, и остаётся фильтр по открытой папке.
  bool get hasSearch => this == CloudProvider.nextcloud;

  /// Описание папки из README.md — расширение Nextcloud (приложение Text).
  /// Даже там его может не быть: приложение отключается, и тогда свойство
  /// просто не приходит.
  bool get hasWorkspace => this == CloudProvider.nextcloud;

  /// Блокировка файла на сервере — приложение files_lock, Nextcloud 24
  /// и новее. Как и с рабочей областью, наличие проверяется по ответу:
  /// сервер без него на LOCK отвечает отказом.
  bool get hasLocks => this == CloudProvider.nextcloud;

  /// Контрольные суммы в свойствах файла: сервер считает их при заливке,
  /// а клиент сверяет скачанное.
  bool get hasChecksums => this == CloudProvider.nextcloud;

  static CloudProvider byName(String? name) {
    for (final v in CloudProvider.values) {
      if (v.name == name) return v;
    }
    return CloudProvider.nextcloud;
  }
}
