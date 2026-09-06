import 'dart:convert';

import 'package:http/http.dart' as http;

import '../oauth/loopback.dart';
import '../webdav_client.dart' show NextcloudException;

/// Учётные данные приложения в Google. Регистрируются один раз человеком в
/// Google Cloud Console (тип «Desktop app») — из кода это сделать нельзя:
/// Google спрашивает не только «кто входит», но и «какому приложению
/// разрешают доступ», а приложение обязано быть заранее известно.
///
/// Секрет тут секретный только по названию: для настольных приложений Google
/// прямо пишет, что скрыть его невозможно, и на безопасность он не влияет —
/// доступ всё равно подтверждается человеком в браузере.
class GoogleClientId {
  const GoogleClientId({required this.id, required this.secret});

  final String id;
  final String secret;

  bool get isEmpty => id.trim().isEmpty || secret.trim().isEmpty;
}

/// Вход в Google по схеме для настольных приложений: браузер возвращает код
/// на локальный адрес, код меняется на пару токенов.
///
/// **Важно про срок жизни.** Пока приложение в Cloud Console не опубликовано
/// (состояние «Testing»), Google выдаёт токен обновления на семь дней. Через
/// неделю вход придётся повторить — это не поломка клиента, а условие Google
/// для непроверенных приложений.
class GoogleAuth {
  GoogleAuth(this.client, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final GoogleClientId client;
  final http.Client _http;

  static final _authEndpoint =
      Uri.parse('https://accounts.google.com/o/oauth2/v2/auth');
  static final _tokenEndpoint = Uri.parse('https://oauth2.googleapis.com/token');

  /// Полный доступ к Диску. Урезанный `drive.file` показывал бы только то,
  /// что создало само приложение, — для файлового клиента это бесполезно.
  static const scope = 'https://www.googleapis.com/auth/drive '
      'https://www.googleapis.com/auth/userinfo.email';

  void close() => _http.close();

  /// Проводит вход целиком: поднимает приёмник, отдаёт адрес в [onUrl],
  /// ждёт возврата и меняет код на токены.
  ///
  /// Возвращает токен обновления и почту — по ней учётная запись и
  /// называется. Null — человек не уложился в срок или отказал.
  Future<({String refreshToken, String email})?> authorize({
    required Future<void> Function(Uri url) onUrl,
    CancelableWait? cancel,
  }) async {
    // Google принимает любой порт возврата, поэтому берём свободный.
    var redirect = Uri.parse('http://127.0.0.1');
    final code = await awaitAuthCode(
      port: 0,
      cancel: cancel,
      start: (at) {
        redirect = at;
        return onUrl(_authEndpoint.replace(queryParameters: {
          'client_id': client.id,
          'redirect_uri': at.toString(),
          'response_type': 'code',
          'scope': scope,
          // offline + consent — иначе токен обновления придёт только при
          // самом первом входе, а при повторном его не будет и вход
          // отвалится молча.
          'access_type': 'offline',
          'prompt': 'consent',
        }));
      },
    );
    if (code == null) return null;

    final tokens = await _exchange({
      'code': code,
      'client_id': client.id,
      'client_secret': client.secret,
      'redirect_uri': redirect.toString(),
      'grant_type': 'authorization_code',
    });

    final refresh = tokens['refresh_token'] as String?;
    if (refresh == null || refresh.isEmpty) {
      throw NextcloudException(
        'Google не выдал токен обновления. Обычно это значит, что доступ '
        'этому приложению уже разрешён: отзовите его на странице '
        'myaccount.google.com/permissions и войдите заново.',
      );
    }

    return (
      refreshToken: refresh,
      email: await _email(tokens['access_token'] as String? ?? ''),
    );
  }

  /// Свежий токен доступа по токену обновления.
  Future<({String token, DateTime expiresAt})> refresh(String refreshToken) async {
    final tokens = await _exchange({
      'refresh_token': refreshToken,
      'client_id': client.id,
      'client_secret': client.secret,
      'grant_type': 'refresh_token',
    });

    final token = tokens['access_token'] as String?;
    if (token == null || token.isEmpty) {
      throw NextcloudException('Google не выдал токен доступа');
    }
    final seconds = (tokens['expires_in'] as num?)?.toInt() ?? 3600;
    // Минуту снимаем про запас: часы клиента и сервера расходятся, а
    // просроченный токен посреди выгрузки стоит дороже лишнего обновления.
    return (
      token: token,
      expiresAt: DateTime.now().add(Duration(seconds: seconds - 60)),
    );
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
      throw NextcloudException('Google ответил непонятным телом (${res.statusCode})');
    }

    if (res.statusCode != 200) {
      final code = body['error'] ?? res.statusCode;
      final text = body['error_description'] as String?;
      throw NextcloudException(
        code == 'invalid_grant'
            ? 'Google больше не принимает этот вход. Если приложение в Cloud '
                'Console не опубликовано, разрешение живёт семь дней — войдите заново.'
            : 'Google отказал ($code)${text == null ? '' : ': $text'}',
      );
    }
    return body;
  }

  /// Почта учётной записи — ею запись и подписана в списке.
  Future<String> _email(String accessToken) async {
    if (accessToken.isEmpty) return 'Google Drive';
    try {
      final res = await _http.get(
        Uri.parse('https://www.googleapis.com/oauth2/v3/userinfo'),
        headers: {'Authorization': 'Bearer $accessToken'},
      );
      if (res.statusCode != 200) return 'Google Drive';
      final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final email = j['email'] as String?;
      return (email == null || email.isEmpty) ? 'Google Drive' : email;
    } catch (_) {
      return 'Google Drive';
    }
  }
}
