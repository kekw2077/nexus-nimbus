import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.dart';

class MenuAction {
  const MenuAction(this.label, this.icon, this.onSelected, {this.danger = false, this.enabled = true});
  final String label;
  final IconData icon;
  final VoidCallback onSelected;
  final bool danger;
  final bool enabled;
}

/// Разделитель в контекстном меню.
const menuSeparator = null;

/// Контекстное меню в палитре Nimbus. Material-овское showMenu годится:
/// нужно только перекрасить подложку и убрать материаловские отступы.
Future<void> showNimbusMenu(
  BuildContext context,
  Offset globalPosition,
  List<MenuAction?> actions,
) async {
  final t = NxTheme.of(context);
  final p = t.palette;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;

  final selected = await showMenu<MenuAction>(
    context: context,
    color: p.solid,
    surfaceTintColor: Colors.transparent,
    elevation: 14,
    shadowColor: const Color(0x99000000),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(NxRadius.tile),
      side: BorderSide(color: p.stroke2),
    ),
    position: RelativeRect.fromRect(
      globalPosition & const Size(1, 1),
      Offset.zero & overlay.size,
    ),
    items: [
      for (final a in actions)
        if (a == null)
          PopupMenuItem<MenuAction>(
            enabled: false,
            height: 9,
            padding: EdgeInsets.zero,
            child: Divider(height: 1, thickness: 1, color: p.stroke),
          )
        else
          PopupMenuItem<MenuAction>(
            value: a,
            enabled: a.enabled,
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 13),
            child: Row(children: [
              Icon(
                a.icon,
                size: 15,
                color: !a.enabled
                    ? p.faint
                    : a.danger
                        ? NxPalette.danger
                        : p.sub,
              ),
              const SizedBox(width: 11),
              Text(
                a.label,
                style: NxType.label.copyWith(
                  fontSize: 12.5,
                  color: !a.enabled
                      ? p.faint
                      : a.danger
                          ? NxPalette.danger
                          : p.body,
                ),
              ),
            ]),
          ),
    ],
  );

  selected?.onSelected();
}
