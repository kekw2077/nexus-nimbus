import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../theme.dart';
import '../tokens.dart';
import 'aurora_background.dart';
import 'dot_grid.dart';
import 'window_chrome.dart';

class NavItem {
  const NavItem(this.id, this.label, this.icon, {this.badge});
  final String id;
  final String label;
  final IconData icon;

  /// Число справа: например количество активных передач.
  final String? badge;
}

/// Оболочка окна: фон → сетка точек → боковое меню и содержимое.
/// Порядок слоёв менять нельзя — фон и сетка не перехватывают клики.
class NimbusShell extends StatelessWidget {
  const NimbusShell({
    super.key,
    required this.items,
    required this.current,
    required this.onSelect,
    required this.child,
    this.sidebarFooter,
    this.titleBar,
  });

  final List<NavItem> items;
  final String current;
  final ValueChanged<String> onSelect;
  final Widget child;
  final Widget? sidebarFooter;
  final Widget? titleBar;

  @override
  Widget build(BuildContext context) {
    final p = NxTheme.of(context).palette;
    return Container(
      color: p.bg,
      child: Stack(children: [
        const Positioned.fill(child: NxBackgroundLayer()),
        const Positioned.fill(child: DotGrid()),
        Positioned.fill(
          child: Row(children: [
            _Sidebar(
              items: items,
              current: current,
              onSelect: onSelect,
              footer: sidebarFooter,
            ),
            Expanded(
              child: Column(children: [
                titleBar ?? const WindowChrome(),
                Expanded(child: child),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.items,
    required this.current,
    required this.onSelect,
    required this.footer,
  });

  final List<NavItem> items;
  final String current;
  final ValueChanged<String> onSelect;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    return Container(
      width: 226,
      decoration: BoxDecoration(border: Border(right: BorderSide(color: p.stroke))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Логотип живёт в зоне заголовка, поэтому его тоже можно тащить.
        SizedBox(
          height: WindowChrome.height,
          child: DragToMoveArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
              child: Row(children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    gradient: t.accent.badge,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(Icons.cloud_rounded, size: 14, color: Colors.white),
                ),
                const SizedBox(width: 10),
                Text('Nimbus',
                    style: NxType.label.copyWith(
                        color: p.txt, fontSize: 14.5, fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
            children: [
              for (final it in items) ...[
                _NavRow(item: it, selected: it.id == current, onTap: () => onSelect(it.id)),
                const SizedBox(height: 3),
              ],
            ],
          ),
        ),
        if (footer != null)
          Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), child: footer!),
      ]),
    );
  }
}

class _NavRow extends StatefulWidget {
  const _NavRow({required this.item, required this.selected, required this.onTap});
  final NavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_NavRow> createState() => _NavRowState();
}

class _NavRowState extends State<_NavRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    final on = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: NxMotion.hover,
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          decoration: BoxDecoration(
            color: on ? p.accentSoft : (_hover ? p.hover : Colors.transparent),
            borderRadius: BorderRadius.circular(NxRadius.tile),
            border: Border.all(
              color: on ? t.accent.a2.withValues(alpha: 0.5) : Colors.transparent,
            ),
          ),
          child: Row(children: [
            Icon(widget.item.icon, size: 17, color: on ? p.txt : p.sub),
            const SizedBox(width: 11),
            Expanded(
              child: Text(
                widget.item.label,
                style: NxType.label.copyWith(color: on ? p.txt : p.body),
              ),
            ),
            if (widget.item.badge != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  gradient: t.accent.badge,
                  borderRadius: BorderRadius.circular(NxRadius.chip),
                ),
                child: Text(
                  widget.item.badge!,
                  style: NxType.numeric.copyWith(
                      color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

/// Полоска заполнения: сервер и локальный кэш показываем одинаково,
/// чтобы их можно было сравнить взглядом.
class UsageMeter extends StatelessWidget {
  const UsageMeter({
    super.key,
    required this.title,
    required this.caption,
    required this.fraction,
    this.gradient,
    this.onTap,
    this.actionIcon,
    this.actionTooltip,
  });

  final String title;
  final String caption;
  final double fraction;
  final Gradient? gradient;
  final VoidCallback? onTap;
  final IconData? actionIcon;
  final String? actionTooltip;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text(title, style: NxType.section.copyWith(color: p.faint))),
        if (actionIcon != null)
          Tooltip(
            message: actionTooltip ?? '',
            child: GestureDetector(
              onTap: onTap,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Icon(actionIcon, size: 14, color: p.sub),
              ),
            ),
          ),
      ]),
      const SizedBox(height: 7),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          height: 5,
          child: Stack(children: [
            ColoredBox(color: p.chip, child: const SizedBox.expand()),
            FractionallySizedBox(
              widthFactor: fraction.clamp(0.0, 1.0),
              child: DecoratedBox(
                decoration: BoxDecoration(gradient: gradient ?? t.accent.badge),
              ),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 6),
      Text(caption, style: NxType.numeric.copyWith(color: p.sub, fontSize: 10.5)),
    ]);
  }
}
