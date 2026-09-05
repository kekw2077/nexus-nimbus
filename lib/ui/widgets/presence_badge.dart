import 'package:flutter/material.dart';

import '../../core/models/remote_file.dart';
import '../theme.dart';
import '../tokens.dart';

/// Внешний вид статуса присутствия. Один значок и один цвет на состояние —
/// чтобы «где лежит файл» читалось боковым зрением, без наведения мыши.
({IconData icon, Color color}) presenceLook(Presence presence, NxPalette p, NxAccent a) {
  return switch (presence) {
    Presence.remote => (icon: Icons.cloud_outlined, color: p.faint),
    Presence.transferring => (icon: Icons.sync_rounded, color: a.a1),
    Presence.cached => (icon: Icons.check_circle_outline_rounded, color: NxPalette.ok),
    Presence.pinned => (icon: Icons.push_pin_rounded, color: a.a2),
    Presence.dirty => (icon: Icons.arrow_circle_up_rounded, color: NxPalette.warn),
    Presence.outdated => (icon: Icons.history_rounded, color: NxPalette.warn),
    Presence.conflict => (icon: Icons.error_outline_rounded, color: NxPalette.danger),
  };
}

/// Значок статуса. Крутится, пока идёт передача.
class PresenceBadge extends StatefulWidget {
  const PresenceBadge({super.key, required this.presence, this.size = 15, this.showTooltip = true});

  final Presence presence;
  final double size;
  final bool showTooltip;

  @override
  State<PresenceBadge> createState() => _PresenceBadgeState();
}

class _PresenceBadgeState extends State<PresenceBadge> with SingleTickerProviderStateMixin {
  AnimationController? _spin;

  void _sync() {
    final wanted = widget.presence == Presence.transferring;
    if (wanted && _spin == null) {
      _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
        ..repeat();
    } else if (!wanted && _spin != null) {
      _spin!.dispose();
      _spin = null;
    }
  }

  @override
  void dispose() {
    _spin?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _sync();
    final t = NxTheme.of(context);
    final look = presenceLook(widget.presence, t.palette, t.accent);

    Widget icon = Icon(look.icon, size: widget.size, color: look.color);
    final spin = _spin;
    if (spin != null) {
      icon = RotationTransition(turns: spin, child: icon);
    }
    if (!widget.showTooltip) return icon;

    return Tooltip(
      message: widget.presence.label,
      waitDuration: const Duration(milliseconds: 500),
      child: icon,
    );
  }
}
