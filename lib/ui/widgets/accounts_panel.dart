import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models/cloud_provider.dart';
import '../../services/webdav_client.dart';
import '../theme.dart';
import '../tokens.dart';
import 'controls.dart';
import 'dialogs.dart';
import 'glass_panel.dart';
import 'login_dialog.dart';

/// Учётные записи облаков: что подключено, что нет, куда нажать.
///
/// Панель всплывает над карточкой в боковой колонке и держится в её ширине.
/// Размер выбран так, чтобы она помещалась и на невысоком экране ноутбука.
Future<void> showAccounts(
  BuildContext context, {
  required AppState app,
  required Rect anchor,
}) {
  final t = NxTheme.of(context);
  return showDialog<void>(
    context: context,
    barrierColor: const Color(0x55000000),
    builder: (ctx) {
      final screen = MediaQuery.of(ctx).size;
      // По ширине карточки внизу слева: панель — её продолжение, а не
      // отдельное окно поверх.
      const width = 268.0;
      const gap = 8.0;

      // Держим панель у карточки, но не даём ей вылезти за края экрана.
      final left = anchor.left.clamp(gap, screen.width - width - gap);
      final bottom = (screen.height - anchor.top + gap).clamp(gap, screen.height * 0.55);

      return NxTheme(
        data: t,
        onChanged: (_) {},
        child: Stack(children: [
          Positioned(
            left: left,
            bottom: bottom,
            width: width,
            child: GlassPanel(
              radius: NxRadius.card,
              padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
              shadow: true,
              color: t.palette.solid,
              child: AccountsList(app: app, onDone: () => Navigator.of(ctx).pop()),
            ),
          ),
        ]),
      );
    },
  );
}

/// Список учётных записей. Живёт и в панели у карточки, и в настройках —
/// он один, чтобы состояние и действия нигде не разошлись.
class AccountsList extends StatelessWidget {
  const AccountsList({super.key, required this.app, this.onDone, this.compact = true});

  final AppState app;

  /// Позвать, когда действие увело человека дальше: панель пора закрыть.
  final VoidCallback? onDone;

  /// В панели заголовок короче, в настройках он и вовсе не нужен.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final saved = app.accounts;
    final activeId = app.active?.id;

    // Облака, по которым записи ещё нет, показываем следом: по ним видно,
    // что можно подключить, и туда же ведёт вход.
    final connectedProviders = saved.map((a) => a.provider).toSet();
    final rest = CloudProvider.values.where((v) => !connectedProviders.contains(v));

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (compact) ...[
          SectionLabel('Учётные записи'),
          const SizedBox(height: 9),
        ],
        for (final account in saved) ...[
          _AccountRow(
            app: app,
            account: account,
            active: account.id == activeId,
            onDone: onDone,
          ),
          const SizedBox(height: 5),
        ],
        for (final provider in rest) ...[
          _ProviderRow(app: app, provider: provider, onDone: onDone),
          const SizedBox(height: 5),
        ],
      ],
    );
  }
}

/// Уже сохранённая запись: нажатие переключает на неё.
class _AccountRow extends StatefulWidget {
  const _AccountRow({
    required this.app,
    required this.account,
    required this.active,
    required this.onDone,
  });

  final AppState app;
  final NxAccount account;
  final bool active;
  final VoidCallback? onDone;

  @override
  State<_AccountRow> createState() => _AccountRowState();
}

class _AccountRowState extends State<_AccountRow> {
  bool _hover = false;

  Future<void> _switch() async {
    if (widget.active) return;
    widget.onDone?.call();
    await widget.app.switchTo(widget.account);
  }

  Future<void> _forget() async {
    final account = widget.account;
    final ok = await confirm(
      context,
      title: 'Забыть ${account.provider.label}?',
      message: 'Пароль приложения будет стёрт, скачанные файлы останутся '
          'на диске. Войти обратно можно в любой момент.',
      confirmLabel: 'Забыть',
    );
    if (!ok) return;
    widget.onDone?.call();
    await widget.app.forget(account);
  }

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    final account = widget.account;

    return MouseRegion(
      cursor: widget.active ? MouseCursor.defer : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: _switch,
        child: AnimatedContainer(
          duration: NxMotion.hover,
          padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
          decoration: BoxDecoration(
            color: _hover && !widget.active ? p.hover : p.field,
            borderRadius: BorderRadius.circular(NxRadius.tile),
            border: Border.all(
              color: widget.active ? t.accent.a2.withValues(alpha: 0.5) : p.stroke,
            ),
          ),
          child: Row(children: [
            Icon(
              widget.active ? Icons.cloud_done_rounded : Icons.cloud_queue_rounded,
              size: 15,
              color: widget.active ? t.accent.a1 : p.sub,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(account.provider.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NxType.label.copyWith(color: p.txt, fontSize: 12)),
                const SizedBox(height: 1),
                Text(
                  '${account.baseUrl.host} · '
                  '${account.displayName ?? account.loginName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NxType.numeric.copyWith(color: p.faint, fontSize: 9.5),
                ),
              ]),
            ),
            const SizedBox(width: 4),
            if (widget.active)
              Icon(Icons.check_rounded, size: 14, color: t.accent.a1)
            else
              Icon(Icons.chevron_right_rounded, size: 14, color: p.sub),
            Tooltip(
              message: 'Забыть запись',
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: _forget,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                    child: Icon(Icons.close_rounded, size: 13, color: p.faint),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Облако, по которому записи ещё нет: нажатие открывает вход.
class _ProviderRow extends StatefulWidget {
  const _ProviderRow({required this.app, required this.provider, required this.onDone});
  final AppState app;
  final CloudProvider provider;
  final VoidCallback? onDone;

  @override
  State<_ProviderRow> createState() => _ProviderRowState();
}

class _ProviderRowState extends State<_ProviderRow> {
  bool _hover = false;

  Future<void> _login() async {
    widget.onDone?.call();
    if (!mounted) return;
    await showLogin(context, provider: widget.provider, app: widget.app);
  }

  @override
  Widget build(BuildContext context) {
    final p = NxTheme.of(context).palette;
    final provider = widget.provider;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: _login,
        child: AnimatedContainer(
          duration: NxMotion.hover,
          padding: const EdgeInsets.fromLTRB(10, 7, 8, 7),
          decoration: BoxDecoration(
            color: _hover ? p.hover : p.field,
            borderRadius: BorderRadius.circular(NxRadius.tile),
            border: Border.all(color: p.stroke),
          ),
          child: Row(children: [
            Icon(Icons.cloud_off_rounded, size: 15, color: p.faint),
            const SizedBox(width: 9),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(provider.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NxType.label.copyWith(color: p.sub, fontSize: 12)),
                const SizedBox(height: 1),
                Text(
                  'не подключено',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NxType.numeric.copyWith(color: p.faint, fontSize: 9.5),
                ),
              ]),
            ),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right_rounded, size: 14, color: p.sub),
          ]),
        ),
      ),
    );
  }
}
