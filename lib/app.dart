import 'package:flutter/material.dart';

import 'core/app_state.dart';
import 'core/format.dart';
import 'core/session.dart';
import 'screens/connect_screen.dart';
import 'screens/files_screen.dart';
import 'screens/local_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/transfers_screen.dart';
import 'services/prefs.dart';
import 'services/updater.dart';
import 'ui/theme.dart';
import 'ui/tokens.dart';
import 'ui/widgets/nimbus_shell.dart';
import 'ui/widgets/window_chrome.dart';

class NimbusApp extends StatelessWidget {
  const NimbusApp({
    super.key,
    required this.app,
    required this.prefs,
    required this.updater,
  });

  final AppState app;
  final Prefs prefs;
  final UpdaterService updater;

  @override
  Widget build(BuildContext context) {
    return NxApp(
      initial: prefs.readTheme(),
      onChanged: prefs.writeTheme,
      // Scaffold нужен не ради оформления, а ради Material в предках:
      // без него TextField и всплывающие меню падают. Фон рисуют экраны.
      builder: (context) => Scaffold(
        backgroundColor: Colors.transparent,
        body: _Root(app: app, prefs: prefs, updater: updater),
      ),
    );
  }
}

class _Root extends StatefulWidget {
  const _Root({required this.app, required this.prefs, required this.updater});
  final AppState app;
  final Prefs prefs;
  final UpdaterService updater;

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  late String _section = widget.prefs.readSection();

  @override
  void initState() {
    super.initState();
    widget.app.addListener(_onApp);
  }

  @override
  void dispose() {
    widget.app.removeListener(_onApp);
    super.dispose();
  }

  void _onApp() {
    if (mounted) setState(() {});
  }

  void _select(String id) {
    setState(() => _section = id);
    widget.prefs.writeSection(id);
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final session = app.session;

    if (app.stage == AppStage.connected && session != null) {
      return _Connected(
        app: app,
        session: session,
        updater: widget.updater,
        section: _section,
        onSelect: _select,
      );
    }
    if (app.stage == AppStage.disconnected) {
      return ConnectScreen(app: app);
    }
    return const _Splash();
  }
}

class _Connected extends StatelessWidget {
  const _Connected({
    required this.app,
    required this.session,
    required this.updater,
    required this.section,
    required this.onSelect,
  });

  final AppState app;
  final Session session;
  final UpdaterService updater;
  final String section;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    final active = session.transfers.activeCount;

    return NimbusShell(
      current: section,
      onSelect: onSelect,
      items: [
        const NavItem('files', 'Файлы', Icons.cloud_outlined),
        NavItem('local', 'Локальное', Icons.computer_rounded,
            badge: session.vault.fileCount > 0 ? '${session.vault.fileCount}' : null),
        NavItem('transfers', 'Передачи', Icons.swap_vert_rounded,
            badge: active > 0 ? '$active' : null),
        const NavItem('settings', 'Настройки', Icons.tune_rounded),
      ],
      titleBar: WindowChrome(
        center: Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Row(children: [
            Icon(Icons.circle, size: 7, color: NxPalette.ok),
            const SizedBox(width: 8),
            Text(
              '${session.account.baseUrl.host} · '
              '${session.account.displayName ?? session.account.loginName}',
              style: NxType.numeric.copyWith(color: p.faint, fontSize: 10.5),
            ),
          ]),
        ),
      ),
      sidebarFooter: _Footer(session: session, onOpenLocal: () => onSelect('local')),
      child: switch (section) {
        'local' => LocalScreen(session: session),
        'transfers' => TransfersScreen(session: session),
        'settings' => SettingsScreen(app: app, session: session, updater: updater),
        _ => FilesScreen(session: session),
      },
    );
  }
}

/// Два одинаковых индикатора рядом: сервер и этот компьютер. Ровно та
/// картинка, которой не хватает в официальном клиенте.
class _Footer extends StatelessWidget {
  const _Footer({required this.session, required this.onOpenLocal});
  final Session session;
  final VoidCallback onOpenLocal;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final quota = session.quota;
    final usage = session.vault.usage();

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      UsageMeter(
        title: 'На сервере',
        fraction: quota?.fraction ?? 0,
        caption: quota == null
            ? '—'
            : quota.unlimited
                ? '${formatBytes(quota.used)} · без ограничения'
                : '${formatBytes(quota.used)} из ${formatBytes(quota.total)}',
      ),
      const SizedBox(height: 14),
      UsageMeter(
        title: 'На этом компьютере',
        // Локальный кэш меряем относительно того же объёма, что и сервер:
        // так сразу видно, насколько малую часть облака мы держим у себя.
        fraction: quota == null || quota.unlimited || quota.total == 0
            ? 0
            : usage.total / quota.total,
        gradient: const LinearGradient(colors: [NxPalette.ok, Color(0xFF60A5FA)]),
        caption: usage.total == 0
            ? 'Ничего не скачано'
            : '${formatBytes(usage.total)} · закреплено ${formatBytes(usage.pinned)}',
        actionIcon: Icons.chevron_right_rounded,
        actionTooltip: 'Показать локальные копии',
        onTap: onOpenLocal,
      ),
      const SizedBox(height: 4),
      Divider(color: t.palette.stroke, height: 18),
      Text(
        'Nexus Nimbus',
        style: NxType.numeric.copyWith(color: t.palette.faint, fontSize: 10),
      ),
    ]);
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    return Container(
      color: p.bg,
      child: Column(children: [
        const WindowChrome(),
        Expanded(
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  gradient: t.accent.badge,
                  borderRadius: BorderRadius.circular(16),
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.cloud_rounded, size: 26, color: Colors.white),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: t.accent.a2),
              ),
              const SizedBox(height: 16),
              Text('Подключаемся…', style: NxType.caption.copyWith(color: p.sub)),
            ]),
          ),
        ),
      ]),
    );
  }
}
