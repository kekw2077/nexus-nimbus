import 'dart:convert';

import 'package:http/http.dart' as http;

import '../oauth/loopback.dart';
import '../webdav_client.dart' show NextcloudException;

/// Учётные данные приложения в Яндексе. Регистрируются один раз человеком
/// на oauth.yandex.ru — как и у Google, облако должно знать приложение,
/// которому человек разрешает доступ.
class YandexClientId {
  const YandexClientId({required this.id, required this.secret, this.port = 8899});

  final String id;
  final String secret;

  /// Порт, на который Яндекс вернёт браузер. В отличие от Google, Яндекс
  /// сверяет адрес возврата с записанным у приложения — значит, порт должен
  /// совпадать с тем, что указан в его настройках, и брать случайный нельзя.
  final int port;

  bool get isEmpty => id.trim().isEmpty || secret.trim().isEmpty;

  /// Адрес возврата, который надо вписать в настройках приложения.
  String get redirectUri => 'http://127.0.0.1:$port';
}

/// Вход в Яндекс по OAuth.
///
/// Понадобился он не от хорошей жизни: WebDAV Яндекс оставил платным
/// подпискам и отвечает бесплатным записям кодом 402. REST API открыт всем,
/// но ходит по токену, а не по паролю приложения.
///
/// В отличие от Google, срок здесь не поджимает: токен Яндекса живёт около
/// года, и еженедельно перевходить не приходится.
class YandexAuth {
  YandexAuth(this.client, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final YandexClientId client;
  final http.Client _http;

  static final _authEndpoint = Uri.parse('https://oauth.yandex.ru/authorize');
  static final _tokenEndpoint = Uri.parse('https://oauth.yandex.ru/token');
  static final _infoEndpoint = Uri.parse('https://login.yandex.ru/info');

  void close() => _http.close();

  /// Проводит вход целиком: поднимает приёмник, отдаёт адрес в [onUrl],
  /// ждёт возврата и меняет код на токен.
  ///
  /// Возвращает токен и логин — по нему запись и подписана в списке.
  /// Null — человек не уложился в срок или отказал.
  Future<({String token, String login})?> authorize({
    required Future<void> Function(Uri url) onUrl,
    CancelableWait? cancel,
  }) async {
    final code = await awaitAuthCode(
      port: client.port,
      cancel: cancel,
      start: (redirect) => onUrl(_authEndpoint.replace(queryParameters: {
        'response_type': 'code',
        'client_id': client.id,
        'redirect_uri': redirect.toString(),
      })),
    );
    if (code == null) return null;

    final tokens = await _exchange({
      'grant_type': 'authorization_code',
      'code': code,
      'client_id': client.id,
      'client_secret': client.secret,
    });

    final token = tokens['access_token'] as String?;
    if (token == null || token.isEmpty) {
      throw NextcloudException('Яндекс не выдал токен доступа');
    }
    return (token: token, login: await _login(token));
  }

  Future<Map<String, dynamic>> _exchange(Map<String, String> form) async {
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
      throw NextcloudException(
        code == 'invalid_grant'
            ? 'Яндекс не принял код — попробуйте войти заново.'
            : 'Яндекс отказал ($code)${text == null ? '' : ': $text'}',
      );
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
