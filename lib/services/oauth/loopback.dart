import 'dart:async';
import 'dart:io';

import '../webdav_client.dart' show NextcloudException;

/// Отмена ожидания входа: человек закрыл окно, не дождавшись браузера.
class CancelableWait {
  final _listeners = <void Function()>[];
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void whenCancelled(void Function() action) {
    if (_cancelled) {
      action();
    } else {
      _listeners.add(action);
    }
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final l in _listeners) {
      l();
    }
    _listeners.clear();
  }
}

/// Приёмник кода авторизации на локальном адресе.
///
/// Схема для настольных приложений: приложение поднимает у себя крохотный
/// сервер, отправляет человека в браузер, а облако возвращает его обратно
/// на `http://127.0.0.1:<порт>` с кодом в адресе.
///
/// Порт бывает двух родов. Google принимает любой, поэтому берётся
/// свободный. Яндекс сверяет адрес возврата с тем, что записан у
/// приложения, — там порт обязан быть тем же самым, и занятый порт
/// означает внятный отказ, а не молчание.
Future<String?> awaitAuthCode({
  required int port,
  required Future<void> Function(Uri redirect) start,
  Duration wait = const Duration(minutes: 5),
  CancelableWait? cancel,
}) async {
  final HttpServer server;
  try {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  } on SocketException {
    throw NextcloudException(
      port == 0
          ? 'Не удалось открыть приёмник для ответа браузера'
          : 'Порт $port занят другой программой. Освободите его или укажите '
              'другой — он же должен стоять в настройках приложения у облака.',
    );
  }

  final redirect = Uri.parse('http://127.0.0.1:${server.port}');
  final done = Completer<String?>();

  final subscription = server.listen((request) async {
    final code = request.uri.queryParameters['code'];
    final error = request.uri.queryParameters['error'];

    request.response
      ..statusCode = 200
      ..headers.contentType = ContentType.html
      ..write(_page(code != null));
    await request.response.close();

    if (done.isCompleted) return;
    if (error != null) {
      done.completeError(NextcloudException('Облако отказало: $error'));
    } else {
      done.complete(code);
    }
  });

  final timer = Timer(wait, () {
    if (!done.isCompleted) done.complete(null);
  });
  cancel?.whenCancelled(() {
    if (!done.isCompleted) done.complete(null);
  });

  try {
    await start(redirect);
    return await done.future;
  } finally {
    timer.cancel();
    await subscription.cancel();
    await server.close(force: true);
  }
}

/// Страница, которую видит человек после разрешения. Он смотрит на неё
/// секунду и возвращается в приложение, поэтому здесь только суть.
String _page(bool ok) => '''
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<title>Nexus Nimbus</title>
<style>
  body{margin:0;height:100vh;display:flex;align-items:center;justify-content:center;
    background:#0F1116;color:#C7CBD6;font:15px/1.6 "Segoe UI",Roboto,sans-serif;}
  div{text-align:center;max-width:30rem;padding:2rem;}
  b{color:#F2F4F8;font-size:1.2rem;display:block;margin-bottom:.5rem;}
</style></head><body><div>
<b>${ok ? 'Готово' : 'Не получилось'}</b>
${ok ? 'Доступ разрешён — вернитесь в Nexus Nimbus.' : 'Доступ не выдан. Попробуйте войти ещё раз.'}
</div></body></html>''';
