import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../theme.dart';
import '../tokens.dart';
import 'aurora_background.dart';
import 'controls.dart';
import 'window_chrome.dart';

class NavItem {
  const NavItem(this.id, this.label, this.icon, {this.badge, this.shortcut});
  final String id;
  final String label;
  final IconData icon;

  /// Число справа: например количество активных передач.
  final String? badge;

  /// Подсказка горячей клавиши, как в прототипе: «Ctrl 1».
  /// Показывается, только когда счётчика нет — иначе им тесно вдвоём.
  final String? shortcut;
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
    this.subtitle,
    this.sidebarFooter,
    this.titleBar,
  });

  final List<NavItem> items;
  final String current;
  final ValueChanged<String> onSelect;
  final Widget child;

  /// Вторая строка под именем в боковой панели: адрес сервера и учётная запись.
  final String? subtitle;

  final Widget? sidebarFooter;
  final Widget? titleBar;

  @override
  Widget build(BuildContext context) {
    final p = NxTheme.of(context).palette;
    return Container(
      color: p.bg,
      child: Stack(children: [
        const Positioned.fill(child: NxBackgroundLayer()),
        Positioned.fill(
          child: Row(children: [
            _Sidebar(
              items: items,
              current: current,
              onSelect: onSelect,
              subtitle: subtitle,
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
    required this.subtitle,
    required this.footer,
  });

  final List<NavItem> items;
  final String current;
  final ValueChanged<String> onSelect;
  final String? subtitle;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    return Container(
      width: 226,
      decoration: BoxDecoration(border: Border(right: BorderSide(color: p.stroke))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Имя и состояние подключения — блоком, как в прототипе. Заодно это
        // зона перетаскивания окна: рамки у него своей нет.
        DragToMoveArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            child: Row(children: [
              const NxBadge(icon: Icons.cloud_rounded, size: 34, radius: 12),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Nimbus',
                        style: NxType.label.copyWith(
                            color: p.txt, fontSize: 14.5, fontWeight: FontWeight.w700)),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NxType.section.copyWith(color: p.faint, fontSize: 9.5),
                      ),
                    ],
                  ],
                ),
              ),
            ]),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            children: [
              for (final it in items) ...[
                _NavRow(item: it, selected: it.id == current, onTap: () => onSelect(it.id)),
                const SizedBox(height: 2),
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

    // Разметка прототипа:
    //   gap:12px; padding:10px 13px; border-radius:14px;
    //   font-size:13.5px; font-weight:500;
    //   выбранный  -> background:linear-gradient(100deg,var(--accsoft),transparent);
    //                 color:var(--txt); box-shadow:inset 0 0 0 1px var(--stroke)
    //   наведённый -> background:var(--hover); color:var(--txt)
    // Рамка у выбранного именно нейтральная (--stroke), а не акцентная:
    // акцент здесь даёт только заливка, и то полупрозрачная и затухающая.
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: NxMotion.hover,
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
          decoration: BoxDecoration(
            gradient: on
                ? LinearGradient(
                    // 100deg в CSS — почти слева направо, с лёгким наклоном вниз.
                    begin: const Alignment(-1, -0.18),
                    end: const Alignment(1, 0.18),
                    colors: [p.accentSoft, p.accentSoft.withValues(alpha: 0)],
                  )
                : null,
            color: on ? null : (_hover ? p.hover : Colors.transparent),
            borderRadius: BorderRadius.circular(14),
            border: on ? Border.all(color: p.stroke) : null,
          ),
          child: Row(children: [
            Icon(widget.item.icon, size: 17, color: on || _hover ? p.txt : p.sub),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                widget.item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: NxType.label.copyWith(
                  color: on || _hover ? p.txt : p.sub,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (widget.item.badge == null && widget.item.shortcut != null)
              Text(
                widget.item.shortcut!,
                // В прототипе подсказка приглушена всегда, даже у выбранного.
                style: NxType.numeric.copyWith(color: p.faint, fontSize: 10.5),
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

/// Подложка нижнего блока панели. В прототипе это карточка состояния:
/// `padding:13px 14px;border-radius:18px;border:1px solid var(--stroke)`.
///
/// Заливка взята плотнее прототипной `var(--field)`: та почти прозрачна,
/// и пятна авроры просвечивали сквозь подписи, съедая их читаемость.
/// Здесь важнее текст, чем прозрачность.
class SidebarCard extends StatefulWidget {
  const SidebarCard({super.key, required this.children, this.onTap, this.tooltip});

  final List<Widget> children;

  /// Нажатие по всей карточке. Здесь живёт выбор учётной записи, поэтому
  /// карточка подсвечивается под курсором — иначе про нажатие не догадаться.
  final void Function(Offset globalPosition)? onTap;

  final String? tooltip;

  @override
  State<SidebarCard> createState() => _SidebarCardState();
}

class _SidebarCardState extends State<SidebarCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    final live = widget.onTap != null;

    Widget card = AnimatedContainer(
      duration: NxMotion.hover,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: p.solid.withValues(alpha: live && _hover ? 0.9 : 0.72),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: live && _hover ? t.accent.a2.withValues(alpha: 0.55) : p.stroke,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: widget.children,
      ),
    );

    if (!live) return card;

    card = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => widget.onTap!(d.globalPosition),
        child: card,
      ),
    );

    final tip = widget.tooltip;
    return tip == null ? card : Tooltip(message: tip, child: card);
  }
}

/// Строка состояния со светящейся точкой — `box-shadow:0 0 9px` того же цвета.
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.label, this.color = NxPalette.ok});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final p = NxTheme.of(context).palette;
    return Row(children: [
      Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: color, blurRadius: 9)],
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: NxType.label.copyWith(color: p.txt, fontSize: 12.5),
        ),
      ),
    ]);
  }
}
