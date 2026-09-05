import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../theme.dart';
import '../tokens.dart';

/// Своя полоса заголовка: системная рамка Windows выбивается из стекла,
/// поэтому окно создаётся без неё, а перетаскивание и кнопки делаем сами.
class WindowChrome extends StatefulWidget {
  const WindowChrome({super.key, this.leading, this.center, this.trailing});

  final Widget? leading;
  final Widget? center;
  final Widget? trailing;

  static const height = 40.0;

  @override
  State<WindowChrome> createState() => _WindowChromeState();
}

class _WindowChromeState extends State<WindowChrome> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((v) {
      if (mounted) setState(() => _maximized = v);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  @override
  Widget build(BuildContext context) {
    final p = NxTheme.of(context).palette;
    return SizedBox(
      height: WindowChrome.height,
      child: Row(children: [
        if (widget.leading != null) widget.leading!,
        Expanded(
          child: DragToMoveArea(
            child: GestureDetector(
              onDoubleTap: () async =>
                  _maximized ? windowManager.unmaximize() : windowManager.maximize(),
              child: SizedBox.expand(
                child: Align(alignment: Alignment.centerLeft, child: widget.center),
              ),
            ),
          ),
        ),
        if (widget.trailing != null) widget.trailing!,
        _Button(
          icon: Icons.remove_rounded,
          tooltip: 'Свернуть',
          onTap: windowManager.minimize,
        ),
        _Button(
          icon: _maximized ? Icons.filter_none_rounded : Icons.crop_square_rounded,
          iconSize: _maximized ? 12 : 14,
          tooltip: _maximized ? 'Восстановить' : 'Развернуть',
          onTap: () => _maximized ? windowManager.unmaximize() : windowManager.maximize(),
        ),
        _Button(
          icon: Icons.close_rounded,
          tooltip: 'Закрыть',
          danger: true,
          onTap: windowManager.close,
        ),
        SizedBox(width: 0, child: ColoredBox(color: p.stroke, child: const SizedBox(height: 1))),
      ]),
    );
  }
}

class _Button extends StatefulWidget {
  const _Button({
    required this.icon,
    required this.onTap,
    required this.tooltip,
    this.danger = false,
    this.iconSize = 15,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;
  final bool danger;
  final double iconSize;

  @override
  State<_Button> createState() => _ButtonState();
}

class _ButtonState extends State<_Button> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = NxTheme.of(context).palette;
    final bg = _hover
        ? (widget.danger ? NxPalette.danger.withValues(alpha: 0.9) : p.hover)
        : Colors.transparent;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 700),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: NxMotion.hover,
            width: 46,
            height: WindowChrome.height,
            color: bg,
            child: Icon(
              widget.icon,
              size: widget.iconSize,
              color: _hover && widget.danger ? Colors.white : p.sub,
            ),
          ),
        ),
      ),
    );
  }
}
