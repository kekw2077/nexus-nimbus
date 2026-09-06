import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.dart';

class MenuAction {
  const MenuAction(
    this.label,
    this.icon,
    this.onSelected, {
    this.danger = false,
    this.enabled = true,
    this.hint,
    this.selected = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onSelected;
  final bool danger;
  final bool enabled;

  /// Вторая строка под подписью: чем этот пункт отличается от соседей.
  final String? hint;

  /// Пункт, выбранный сейчас, — с галочкой и в цвете акцента.
  final bool selected;
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
    // Из прототипа: радиус 18, рамка stroke2, тень 0 20px 48px rgba(0,0,0,.42).
    elevation: 20,
    shadowColor: const Color(0x6B000000),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
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
            height: a.hint == null ? 34 : 48,
            padding: const EdgeInsets.symmetric(horizontal: 13),
            child: Row(children: [
              Icon(
                a.icon,
                size: 15,
                color: a.selected
                    ? t.accent.a1
                    : !a.enabled
                        ? p.faint
                        : a.danger
                            ? NxPalette.danger
                            : p.sub,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      a.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NxType.label.copyWith(
                        fontSize: 12.5,
                        color: a.selected
                            ? p.txt
                            : !a.enabled
                                ? p.faint
                                : a.danger
                                    ? NxPalette.danger
                                    : p.body,
                      ),
                    ),
                    if (a.hint != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        a.hint!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NxType.caption.copyWith(color: p.faint, fontSize: 10.5),
                      ),
                    ],
                  ],
                ),
              ),
              if (a.selected) ...[
                const SizedBox(width: 10),
                Icon(Icons.check_rounded, size: 14, color: t.accent.a1),
              ],
            ]),
          ),
    ],
  );

  selected?.onSelected();
}
