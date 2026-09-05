import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'webdav_client.dart';

/// Login Flow v2 — тот же механизм, которым пользуется официальный клиент.
///
/// 1. POST {server}/index.php/login/v2 → сервер отдаёт ссылку для браузера
///    и адрес для опроса.
/// 2. Пользователь входит в браузере, включая двухфакторную проверку.
/// 3. Мы опрашиваем poll-адрес: 404, пока вход не завершён; ровно один раз
///    приходит 200 с паролем приложения.
///
/// Пароль от самой учётной записи в приложение не попадает никогда.
class LoginFlow {
  LoginFlow._(this._client, this.server, this.loginUrl, this._pollEndpoint, this._token);

  final http.Client _client;
  final Uri server;

  /// Эту ссылку открываем в браузере (или во встроенном WebView).
  final Uri loginUrl;

  final Uri _pollEndpoint;
  final String _token;

  static const _pollInterval = Duration(seconds: 2);
  static const _lifetime = Duration(minutes: 20);

  /// Начинает вход. Бросает [NextcloudException], если сервер не отвечает
  /// или не поддерживает Login Flow v2.
  static Future<LoginFlow> start(Uri server, {bool allowBadCertificate = false}) async {
    final io = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..userAgent = 'Nexus Nimbus';
    if (allowBadCertificate) {
      io.badCertificateCallback = (_, host, _) => host == server.host;
    }
    final client = IOClient(io);

    final uri = server.replace(
      pathSegments: [
        ...server.pathSegments.where((s) => s.isNotEmpty),
        'index.php',
        'login',
        'v2',
      ],
    );

    http.Response res;
    try {
      // Имя клиента сервер берёт из User-Agent — оно попадёт в список
      // устройств и сеансов, чтобы сессию потом было легко отозвать.
      res = await client.post(uri, headers: {'User-Agent': 'Nexus Nimbus'});
    } on SocketException catch (e) {
      client.close();
      throw NextcloudException('Сервер недоступен: ${e.message}', uri: uri);
    } on HandshakeException {
      client.close();
      throw NextcloudException(
        'Сертификат сервера не прошёл проверку. Для самоподписанного включите '
        '«Доверять сертификату».',
        uri: uri,
      );
    }

    if (res.statusCode != 200) {
      client.close();
      throw NextcloudException(
        'Сервер не поддерживает вход через браузер (ответ ${res.statusCode}). '
        'Введите пароль приложения вручную.',
        statusCode: res.statusCode,
        uri: uri,
      );
    }

    try {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final poll = body['poll'] as Map<String, dynamic>;
      return LoginFlow._(
        client,
        server,
        Uri.parse(body['login'] as String),
        Uri.parse(poll['endpoint'] as String),
        poll['token'] as String,
      );
    } catch (_) {
      client.close();
      throw NextcloudException('Сервер вернул неожиданный ответ на запрос входа', uri: uri);
    }
  }

  /// Ждёт, пока пользователь завершит вход в браузере.
  /// Возвращает null, если истекли отведённые сервером 20 минут.
  Future<NxAccount?> awaitCredentials({
    bool allowBadCertificate = false,
    CancelToken? cancel,
  }) async {
    final deadline = DateTime.now().add(_lifetime);

    while (DateTime.now().isBefore(deadline)) {
      if (cancel?.isCancelled ?? false) return null;
      await Future<void>.delayed(_pollInterval);
      if (cancel?.isCancelled ?? false) return null;

      http.Response res;
      try {
        res = await _client.post(
          _pollEndpoint,
          headers: {
            'User-Agent': 'Nexus Nimbus',
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          body: {'token': _token},
        );
      } on SocketException {
        continue; // связь моргнула — просто пробуем ещё раз
      }

      if (res.statusCode == 404) continue; // вход ещё не завершён
      if (res.statusCode != 200) continue;

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return NxAccount(
        baseUrl: Uri.parse(body['server'] as String),
        loginName: body['loginName'] as String,
        appPassword: body['appPassword'] as String,
        allowBadCertificate: allowBadCertificate,
      );
    }
    return null;
  }

  void dispose() => _client.close();
}
