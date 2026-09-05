import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/app_state.dart';
import 'services/credentials_store.dart';
import 'services/prefs.dart';
import 'services/updater.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  // Окно без системной рамки: заголовок рисуем сами, чтобы он попадал
  // в палитру и стекло не обрывалось на границе.
  const options = WindowOptions(
    size: Size(1180, 760),
    minimumSize: Size(880, 560),
    center: true,
    backgroundColor: Colors.transparent,
    titleBarStyle: TitleBarStyle.hidden,
    title: 'Nexus Nimbus',
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  final prefs = await Prefs.open();
  final app = AppState(CredentialsStore());
  final updater = UpdaterService(prefs);

  runApp(NimbusApp(app: app, prefs: prefs, updater: updater));

  // Восстановление сессии идёт уже после первого кадра — окно появляется
  // мгновенно, а не после ответа сервера.
  await app.restore();

  // Обновления поднимаются последними и в фоне: канал может быть недоступен,
  // и ждать его на старте нечего. Первая проверка тихая — окно WinSparkle
  // появится, только если обновление действительно есть.
  await updater.init();
  if (updater.autoCheck) {
    unawaited(Future<void>.delayed(
      const Duration(seconds: 4),
      () => updater.check(inBackground: true),
    ));
  }
}
