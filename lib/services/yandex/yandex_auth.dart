import 'dart:convert';

import 'package:http/http.dart' as http;

import '../webdav_client.dart' show NextcloudException;

/// Учётные данные приложения в Яндексе. Регистрируются один раз человеком
/// на oauth.yandex.ru — облако должно знать приложение, которому дают доступ.
class YandexClientId {
  const YandexClientId({required this.id, required this.secret});

  final String id;
  final String secret;

  bool get isEmpty => id.trim().isEmpty || secret.trim().isEmpty;
}

/// Вход в Яндекс по OAuth.
///
/// Понадобился он не от хорошей жизни: WebDAV Яндекс оставил платным
/// подпискам и отвечает бесплатным записям кодом 402. REST API открыт всем,
/// но ходит по токену, а не по паролю приложения.
///
/// **Почему код переписывается руками, а не ловится приёмником.** Яндекс
/// выдаёт приложению постоянный адрес возврата
/// `https://oauth.yandex.ru/verification_code` и сверяет с ним запрос. Просить
/// возврата на локальный адрес можно, только если вписать его в настройки
/// приложения, — а в консоли Яндекса это поле не всегда доступно, и попытка
/// кончается ошибкой 400 «redirect_uri не совпадает с Callback URL».
/// Поэтому идём штатным для настольных программ путём: Яндекс показывает
/// код на странице, человек переносит его в окно входа. Одно лишнее действие
/// в обмен на то, что схема работает у всех и без настроек.
///
/// Токен живёт около года — повторять это придётся нескоро.
class YandexAuth {
  YandexAuth(this.client, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final YandexClientId client;
  final http.Client _http;

  static final _authEndpoint = Uri.parse('https://oauth.yandex.ru/authorize');
  static final _tokenEndpoint = Uri.parse('https://oauth.yandex.ru/token');
  static final _infoEndpoint = Uri.parse('https://login.yandex.ru/info');

  /// Постоянный адрес возврата Яндекса: он же показывает код на экране.
  static const verificationCode = 'https://oauth.yandex.ru/verification_code';

  void close() => _http.close();

  /// Куда отправить человека за разрешением.
  Uri get authorizeUrl => _authEndpoint.replace(queryParameters: {
        'response_type': 'code',
        'client_id': client.id,
        'redirect_uri': verificationCode,
      });

  /// Меняет код со страницы Яндекса на токен.
  ///
  /// Возвращает токен и логин — по нему запись и подписана в списке.
  Future<({String token, String login})> exchange(String code) async {
    final clean = code.trim();
    if (clean.isEmpty) {
      throw NextcloudException('Код пустой — скопируйте его со страницы Яндекса');
    }

    final tokens = await _post({
      'grant_type': 'authorization_code',
      'code': clean,
      'client_id': client.id,
      'client_secret': client.secret,
    });

    final token = tokens['access_token'] as String?;
    if (token == null || token.isEmpty) {
      throw NextcloudException('Яндекс не выдал токен доступа');
    }
    return (token: token, login: await _login(token));
  }

  Future<Map<String, dynamic>> _post(Map<String, String> form) async {
    final res = await _http.post(
      _tokenEndpoint,
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: form,
    );

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw NextcloudException('Яндекс ответил непонятным телом (${res.statusCode})');
    }

    if (res.statusCode != 200) {
      final code = body['error'] ?? res.statusCode;
      final text = body['error_description'] as String?;
      throw NextcloudException(switch (code) {
        'invalid_grant' => 'Яндекс не принял код. Он одноразовый и живёт '
            'считаные минуты — получите новый.',
        'invalid_client' => 'Яндекс не узнал приложение. Проверьте '
            'идентификатор и пароль приложения.',
        _ => 'Яндекс отказал ($code)${text == null ? '' : ': $text'}',
      });
    }
    return body;
  }

  /// Логин учётной записи — им запись и подписана в списке.
  Future<String> _login(String token) async {
    try {
      final res = await _http.get(
        _infoEndpoint.replace(queryParameters: {'format': 'json'}),
        headers: {'Authorization': 'OAuth $token'},
      );
      if (res.statusCode != 200) return 'Яндекс.Диск';
      final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final login = (j['default_email'] as String?) ?? (j['login'] as String?);
      return (login == null || login.isEmpty) ? 'Яндекс.Диск' : login;
    } catch (_) {
      return 'Яндекс.Диск';
    }
  }
}
