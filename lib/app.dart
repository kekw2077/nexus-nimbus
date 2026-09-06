import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/app_state.dart';
import 'core/format.dart';
import 'core/session.dart';
import 'screens/connect_screen.dart';
import 'screens/favorites_screen.dart';
import 'screens/files_screen.dart';
import 'screens/local_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/trash_screen.dart';
import 'screens/transfers_screen.dart';
import 'services/edit_watcher.dart';
import 'services/sync_engine.dart';
import 'services/prefs.dart';
import 'services/tray_service.dart';
import 'services/updater.dart';
import 'ui/theme.dart';
import 'ui/tokens.dart';
import 'ui/widgets/dialogs.dart';
import 'ui/widgets/accounts_panel.dart';
import 'ui/widgets/nimbus_shell.dart';
import 'ui/widgets/window_chrome.dart';

class NimbusApp extends StatelessWidget {
  const NimbusApp({
    super.key,
    required this.app,
    required this.prefs,
    required this.updater,
    required this.tray,
  });

  final AppState app;
  final Prefs prefs;
  final UpdaterService updater;
  final TrayService tray;

  @override
  Widget build(BuildContext context) {
    return NxApp(
      initial: prefs.readTheme(),
      onChanged: prefs.writeTheme,
      // Scaffold нужен не ради оформления, а ради Material в предках:
      // без него TextField и всплывающие меню падают. Фон рисуют экраны.
      builder: (context) => Scaffold(
        backgroundColor: Colors.transparent,
        body: _Root(app: app, prefs: prefs, updater: updater, tray: tray),
      ),
    );
  }
}

class _Root extends StatefulWidget {
  const _Root({
    required this.app,
    required this.prefs,
    required this.updater,
    required this.tray,
  });

  final AppState app;
  final Prefs prefs;
  final UpdaterService updater;
  final TrayService tray;

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
        tray: widget.tray,
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
    required this.tray,
    required this.section,
    required this.onSelect,
  });

  final AppState app;
  final Session session;
  final UpdaterService updater;
  final Prefs prefs;
  final TrayService tray;
  final String section;
  final ValueChanged<String> onSelect;

  /// Разделы переключаются с клавиатуры — те самые «Ctrl 1…6»,
  /// что подписаны справа от названий в боковой панели.
  ///
  /// Список зависит от облака: избранное и корзина — расширения Nextcloud,
  /// и у обычного WebDAV их просто нет. Показывать разделы, которые ответят
  /// отказом, хуже, чем не показывать вовсе.
  List<String> get _sections => [
        'files',
        if (session.account.provider.hasFavorites) 'favorites',
        'local',
        if (session.account.provider.hasTrash) 'trash',
        'transfers',
        'settings',
      ];

  static const _digits = [
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
  ];

  /// Подпись сочетания по месту раздела в списке.
  String _shortcut(String id) {
    final at = _sections.indexOf(id);
    return at < 0 ? '' : 'Ctrl ${at + 1}';
  }

  @override
  Widget build(BuildContext context) {
    final active = session.transfers.activeCount;
    final provider = session.account.provider;
    final sections = _sections;

    return CallbackShortcuts(
      bindings: {
        for (var i = 0; i < sections.length && i < _digits.length; i++)
          SingleActivator(_digits[i], control: true): () => onSelect(sections[i]),
      },
      child: _EditNotices(
        session: session,
        child: NimbusShell(
        current: section,
        onSelect: onSelect,
        subtitle: '${session.account.baseUrl.host} · '
            '${session.account.displayName ?? session.account.loginName}',
        items: [
          NavItem('files', 'Файлы', Icons.cloud_outlined, shortcut: _shortcut('files')),
          if (provider.hasFavorites)
            NavItem('favorites', 'Избранное', Icons.star_outline_rounded,
                shortcut: _shortcut('favorites')),
          NavItem('local', 'Локальное', Icons.computer_rounded,
              shortcut: _shortcut('local'),
              badge: session.vault.fileCount > 0 ? '${session.vault.fileCount}' : null),
          if (provider.hasTrash)
            NavItem('trash', 'Корзина', Icons.delete_outline_rounded,
                shortcut: _shortcut('trash')),
          NavItem('transfers', 'Передачи', Icons.swap_vert_rounded,
              shortcut: _shortcut('transfers'), badge: active > 0 ? '$active' : null),
          NavItem('settings', 'Настройки', Icons.tune_rounded,
              shortcut: _shortcut('settings')),
        ],
        titleBar: const WindowChrome(),
        sidebarFooter: _Footer(
          app: app,
          session: session,
          onOpenLocal: () => onSelect('local'),
        ),
        child: switch (sections.contains(section) ? section : 'files') {
          'favorites' => FavoritesScreen(
              session: session,
              onOpenFiles: (path) {
                onSelect('files');
                unawaited(session.open(path));
              },
            ),
          'local' => LocalScreen(session: session),
          'trash' => TrashScreen(session: session),
          'transfers' => TransfersScreen(session: session),
          'settings' => SettingsScreen(
              app: app,
              session: session,
              updater: updater,
              prefs: prefs,
              tray: tray,
            ),
            _ => FilesScreen(
              session: session,
              onOpenTransfers: () => onSelect('transfers'),
            ),
          },
        ),
      ),
    );
  }
}

/// Показывает предложение отправить правку, когда автоотправка выключена.
///
/// Предложение необязательное: файл и так помечен «изменён, не отправлен»,
/// и отправить его можно из меню в любой момент. Подсказка просто попадается
/// на глаза раньше, чем пользователь снова откроет ту папку.
class _EditNotices extends StatefulWidget {
  const _EditNotices({required this.session, required this.child});
  final Session session;
  final Widget child;

  @override
  State<_EditNotices> createState() => _EditNoticesState();
}

class _EditNoticesState extends State<_EditNotices> {
  /// Время последней показанной правки. Тот же файл, поправленный второй
  /// раз, получает новую отметку — и подсказку покажем снова.
  DateTime? _shown;

  EditWatcher get _edits => widget.session.edits;

  @override
  void initState() {
    super.initState();
    _edits.addListener(_onEdits);
  }

  @override
  void dispose() {
    _edits.removeListener(_onEdits);
    super.dispose();
  }

  void _onEdits() {
    if (!mounted) return;
    final latest = _edits.latest;
    if (latest == null || latest.at == _shown) return;
    _shown = latest.at;

    // Уведомление может прийти посреди кадра, а показывать подсказку в это
    // время нельзя — ждём, пока кадр дорисуется.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _offer(latest);
    });
  }

  void _offer(PendingEdit latest) {
    final more = _edits.pending.length - 1;
    final message = more > 0
        ? '«${latest.name}» и ещё $more '
            '${plural(more, 'файл', 'файла', 'файлов')} изменены на этом компьютере'
        : '«${latest.name}» изменён на этом компьютере';

    showNxToast(
      context,
      message,
      icon: Icons.edit_note_rounded,
      duration: const Duration(seconds: 8),
      actionLabel: more > 0 ? 'Отправить все' : 'Отправить',
      onAction: more > 0 ? _edits.pushAll : () => _edits.push(latest.remotePath),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Два одинаковых индикатора рядом: сервер и этот компьютер. Ровно та
/// картинка, которой не хватает в официальном клиенте.
class _Footer extends StatelessWidget {
  const _Footer({
    required this.app,
    required this.session,
    required this.onOpenLocal,
  });

  final AppState app;
  final Session session;
  final VoidCallback onOpenLocal;

  /// Учётные записи облаков. Панель всплывает над самой карточкой и
  /// держится в её ширине — на невысоком экране ноутбука она должна
  /// помещаться целиком, без прокрутки.
  void _accounts(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final at = box.localToGlobal(Offset.zero);

    showAccounts(context, app: app, anchor: at & box.size);
  }

  /// Верхняя строка карточки: обычно «Подключено к <облаку>», но пока идёт
  /// обход или пока висят расхождения — про них. Состояние синхронизации
  /// должно попадаться на глаза само, а не ждать похода в настройки.
  ({String label, Color color}) _status() {
    final sync = session.sync;
    if (sync.phase == SyncPhase.running) {
      return (label: 'Синхронизация…', color: NxPalette.warn);
    }
    if (sync.phase == SyncPhase.failed) {
      return (label: 'Синхронизация сорвалась', color: NxPalette.danger);
    }
    final open = sync.conflicts.length;
    if (open > 0) {
      return (
        label: 'Расхождений: $open',
        color: NxPalette.warn,
      );
    }
    return (
      label: 'Подключено к ${session.account.provider.label}',
      color: NxPalette.ok,
    );
  }

  @override
  Widget build(BuildContext context) {
    final quota = session.quota;
    final usage = session.vault.usage();
    final status = _status();

    return SidebarCard(
      onTap: (_) => _accounts(context),
      tooltip: 'Учётные записи и облака',
      children: [
        StatusDot(label: status.label, color: status.color),
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
      ],
    );
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
