import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/app_state.dart';
import 'services/credentials_store.dart';
import 'services/prefs.dart';
import 'services/updater.dart';
import 'services/window_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  // Настройки читаются до окна: в них лежит его прошлый размер, и открыться
  // сразу нужного размера лучше, чем прыгнуть в него после появления.
  final prefs = await Prefs.open();
  final window = WindowStateKeeper(prefs);
  final restoredPosition = await window.validPosition();

  // Окно без системной рамки: заголовок рисуем сами, чтобы он попадал
  // в палитру и стекло не обрывалось на границе.
  final options = WindowOptions(
    size: window.savedSize,
    minimumSize: WindowStateKeeper.minimumSize,
    center: restoredPosition == null,
    backgroundColor: Colors.transparent,
    titleBarStyle: TitleBarStyle.hidden,
    title: 'Nexus Nimbus',
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await window.restore();
    await windowManager.show();
    await windowManager.focus();
  });
  window.attach();

  final app = AppState(CredentialsStore(), prefs);
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
