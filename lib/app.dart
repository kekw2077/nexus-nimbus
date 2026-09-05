import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/app_state.dart';
import 'core/format.dart';
import 'core/session.dart';
import 'screens/connect_screen.dart';
import 'screens/files_screen.dart';
import 'screens/local_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/trash_screen.dart';
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
        prefs: widget.prefs,
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
    required this.prefs,
    required this.section,
    required this.onSelect,
  });

  final AppState app;
  final Session session;
  final UpdaterService updater;
  final Prefs prefs;
  final String section;
  final ValueChanged<String> onSelect;

  /// Разделы переключаются с клавиатуры — те самые «Ctrl 1…5»,
  /// что подписаны справа от названий в боковой панели.
  static const _sections = ['files', 'local', 'trash', 'transfers', 'settings'];
  static const _digits = [
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
  ];

  @override
  Widget build(BuildContext context) {
    final active = session.transfers.activeCount;

    return CallbackShortcuts(
      bindings: {
        for (var i = 0; i < _sections.length; i++)
          SingleActivator(_digits[i], control: true): () => onSelect(_sections[i]),
      },
      child: NimbusShell(
        current: section,
        onSelect: onSelect,
        subtitle: '${session.account.baseUrl.host} · '
            '${session.account.displayName ?? session.account.loginName}',
        items: [
          const NavItem('files', 'Файлы', Icons.cloud_outlined, shortcut: 'Ctrl 1'),
          NavItem('local', 'Локальное', Icons.computer_rounded,
              shortcut: 'Ctrl 2',
              badge: session.vault.fileCount > 0 ? '${session.vault.fileCount}' : null),
          const NavItem('trash', 'Корзина', Icons.delete_outline_rounded,
              shortcut: 'Ctrl 3'),
          NavItem('transfers', 'Передачи', Icons.swap_vert_rounded,
              shortcut: 'Ctrl 4', badge: active > 0 ? '$active' : null),
          const NavItem('settings', 'Настройки', Icons.tune_rounded, shortcut: 'Ctrl 5'),
        ],
        titleBar: const WindowChrome(),
        sidebarFooter: _Footer(session: session, onOpenLocal: () => onSelect('local')),
        child: switch (section) {
          'local' => LocalScreen(session: session),
          'trash' => TrashScreen(session: session),
          'transfers' => TransfersScreen(session: session),
          'settings' =>
            SettingsScreen(app: app, session: session, updater: updater, prefs: prefs),
          _ => FilesScreen(session: session),
        },
      ),
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
    final quota = session.quota;
    final usage = session.vault.usage();

    return SidebarCard(children: [
      StatusDot(label: 'Подключено'),
      const SizedBox(height: 13),
      UsageMeter(
        title: 'На сервере',
        fraction: quota?.fraction ?? 0,
        caption: quota == null
            ? '—'
            : quota.unlimited
                ? '${formatBytes(quota.used)} · без ограничения'
                : '${formatBytes(quota.used)} из ${formatBytes(quota.total)}',
      ),
      const SizedBox(height: 13),
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
