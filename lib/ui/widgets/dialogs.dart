import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.dart';
import 'controls.dart';
import 'glass_panel.dart';

/// Всплывающая подсказка внизу окна: подтверждение действия, ошибка,
/// предложение отправить правку. Одна на всё приложение, чтобы такие
/// сообщения выглядели одинаково откуда бы они ни пришли.
void showNxToast(
  BuildContext context,
  String message, {
  bool danger = false,
  IconData? icon,
  String? actionLabel,
  VoidCallback? onAction,
  Duration duration = const Duration(seconds: 4),
}) {
  final p = NxTheme.of(context).palette;
  final accent = NxTheme.of(context).accent;
  final mark = icon ??
      (danger ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded);

  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      width: 520,
      duration: duration,
      backgroundColor: p.solid,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NxRadius.tile),
        side: BorderSide(color: danger ? NxPalette.danger : p.stroke2),
      ),
      action: actionLabel == null || onAction == null
          ? null
          : SnackBarAction(
              label: actionLabel,
              textColor: accent.a2,
              onPressed: onAction,
            ),
      content: Row(children: [
        Icon(mark, size: 16, color: danger ? NxPalette.danger : NxPalette.ok),
        const SizedBox(width: 11),
        Expanded(
          child: Text(message,
              style: NxType.bodyText.copyWith(color: p.body, fontSize: 12.5)),
        ),
      ]),
    ));
}

/// Диалог с одним текстовым полем: новая папка, переименование.
/// Возвращает null, если отменили.
Future<String?> askText(
  BuildContext context, {
  required String title,
  required String hint,
  required String confirmLabel,
  String initial = '',

  /// Что выделить в поле сразу — для переименования это имя без расширения.
  int? selectTo,
}) async {
  final controller = TextEditingController(text: initial);
  controller.selection = TextSelection(
    baseOffset: 0,
    extentOffset: selectTo ?? initial.length,
  );

  final result = await showDialog<String>(
    context: context,
    barrierColor: const Color(0x99000000),
    builder: (ctx) {
      final t = NxTheme.of(context);
      void submit() {
        final v = controller.text.trim();
        if (v.isNotEmpty) Navigator.of(ctx).pop(v);
      }

      return NxTheme(
        data: t,
        onChanged: (_) {},
        child: Center(
          child: SizedBox(
            width: 400,
            child: GlassPanel(
              radius: NxRadius.card,
              padding: const EdgeInsets.all(22),
              shadow: true,
              color: t.palette.solid,
              child: Builder(builder: (ctx2) {
                final p = NxTheme.of(ctx2).palette;
                return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(title, style: NxType.title.copyWith(color: p.txt, fontSize: 17)),
                  const SizedBox(height: 16),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    onSubmitted: (_) => submit(),
                    style: NxType.bodyText.copyWith(color: p.body, fontSize: 13.5),
                    decoration: InputDecoration(
                      hintText: hint,
                      hintStyle: NxType.bodyText.copyWith(color: p.faint, fontSize: 13.5),
                      filled: true,
                      fillColor: p.field,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(color: p.stroke)),
                      enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(color: p.stroke)),
                      focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(color: t.accent.a2)),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    NxGhostButton(label: 'Отмена', onTap: () => Navigator.of(ctx).pop()),
                    const SizedBox(width: 10),
                    GradientButton(label: confirmLabel, onTap: submit),
                  ]),
                ]);
              }),
            ),
          ),
        ),
      );
    },
  );
  controller.dispose();
  return result;
}

/// Подтверждение необратимого действия.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Удалить',
  bool danger = true,
}) async {
  final t = NxTheme.of(context);
  final result = await showDialog<bool>(
    context: context,
    barrierColor: const Color(0x99000000),
    builder: (ctx) => NxTheme(
      data: t,
      onChanged: (_) {},
      child: Center(
        child: SizedBox(
          width: 420,
          child: GlassPanel(
            radius: NxRadius.card,
            padding: const EdgeInsets.all(22),
            shadow: true,
            color: t.palette.solid,
            child: Builder(builder: (ctx2) {
              final p = NxTheme.of(ctx2).palette;
              return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(
                    danger ? Icons.warning_amber_rounded : Icons.help_outline_rounded,
                    size: 20,
                    color: danger ? NxPalette.warn : p.sub,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(title, style: NxType.title.copyWith(color: p.txt, fontSize: 17)),
                  ),
                ]),
                const SizedBox(height: 12),
                Text(message,
                    style: NxType.bodyText.copyWith(color: p.sub, fontSize: 13, height: 1.5)),
                const SizedBox(height: 20),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  NxGhostButton(
                      label: 'Отмена', onTap: () => Navigator.of(ctx).pop(false)),
                  const SizedBox(width: 10),
                  _Danger(
                    label: confirmLabel,
                    danger: danger,
                    onTap: () => Navigator.of(ctx).pop(true),
                  ),
                ]),
              ]);
            }),
          ),
        ),
      ),
    ),
  );
  return result ?? false;
}

class _Danger extends StatelessWidget {
  const _Danger({required this.label, required this.onTap, required this.danger});
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    if (!danger) return GradientButton(label: label, onTap: onTap);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: NxPalette.danger,
            borderRadius: BorderRadius.circular(NxRadius.chip),
            boxShadow: const [
              BoxShadow(
                color: Color.fromRGBO(0, 0, 0, 0.22),
                offset: Offset(0, 6),
                blurRadius: 18,
              ),
            ],
          ),
          child: Text(label,
              style: NxType.label.copyWith(
                  color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}
