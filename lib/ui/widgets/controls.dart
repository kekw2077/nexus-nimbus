import 'package:flutter/material.dart';
import '../tokens.dart';
import '../theme.dart';

/// Мелкие элементы управления, встречающиеся на всех экранах.

/// Заголовок блока: 10.5–11px, жирный, разрядка, верхний регистр.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.size = 11});
  final String text;
  final double size;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: NxType.section.copyWith(color: NxTheme.of(context).palette.faint, fontSize: size),
      );
}

/// Переключатель 46×26 с белым бегунком.
class NxToggle extends StatelessWidget {
  const NxToggle({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          width: 46, height: 26,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            gradient: value ? LinearGradient(colors: [t.accent.a1, t.accent.a2]) : null,
            color: value ? null : t.palette.chip,
            borderRadius: BorderRadius.circular(NxRadius.chip),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeInOutCubic,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: 20, height: 20,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: Color(0x4D000000), offset: Offset(0, 2), blurRadius: 6)],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Сегменты в подложке — выбор одного из нескольких коротких вариантов.
class NxSegmented extends StatelessWidget {
  const NxSegmented({super.key, required this.options, required this.value, required this.onChanged, this.compact = false});
  final List<String> options;
  final String value;
  final ValueChanged<String> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: p.chip, borderRadius: BorderRadius.circular(13)),
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: 3, runSpacing: 3,
        children: [
          for (final o in options)
            GestureDetector(
              onTap: () => onChanged(o),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: AnimatedContainer(
                  duration: NxMotion.hover,
                  padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 13, vertical: 7),
                  decoration: BoxDecoration(
                    color: o == value ? p.accentSoft : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: o == value ? t.accent.a2 : Colors.transparent),
                  ),
                  child: Text(o, style: NxType.label.copyWith(fontSize: 12, color: o == value ? p.txt : p.sub)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Ползунок: дорожка 5px, градиентная заливка, белый кружок 14px.
class NxSlider extends StatelessWidget {
  const NxSlider({super.key, required this.value, required this.min, required this.max, required this.onChanged, this.step});
  final double value, min, max;
  final double? step;
  final ValueChanged<double> onChanged;

  void _emit(double dx, double width) {
    var v = min + (dx / width).clamp(0.0, 1.0) * (max - min);
    if (step != null && step! > 0) v = (v / step!).round() * step!;
    onChanged(v.clamp(min, max));
  }

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    final frac = ((value - min) / (max - min)).clamp(0.0, 1.0);

    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      return GestureDetector(
        onTapDown: (e) => _emit(e.localPosition.dx, w),
        onHorizontalDragUpdate: (e) => _emit(e.localPosition.dx, w),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: SizedBox(
            height: 20,
            child: Stack(alignment: Alignment.centerLeft, children: [
              Container(
                height: 5,
                decoration: BoxDecoration(color: p.chip, borderRadius: BorderRadius.circular(5)),
              ),
              Container(
                height: 5,
                width: w * frac,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [t.accent.a1, t.accent.a2]),
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
              Positioned(
                left: (w * frac - 7).clamp(0.0, w - 14),
                child: Container(
                  width: 14, height: 14,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: Color(0x59000000), offset: Offset(0, 2), blurRadius: 8)],
                  ),
                ),
              ),
            ]),
          ),
        ),
      );
    });
  }
}

/// Строка «подпись — значение — ползунок», как на экранах картинок и голоса.
class LabeledSlider extends StatelessWidget {
  const LabeledSlider({super.key, required this.label, required this.display,
    required this.value, required this.min, required this.max, required this.onChanged, this.step});

  final String label, display;
  final double value, min, max;
  final double? step;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = NxTheme.of(context).palette;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
        Text(label, style: NxType.bodyText.copyWith(color: p.body, fontSize: 12.5)),
        const Spacer(),
        Text(display, style: NxType.numeric.copyWith(color: p.txt, fontSize: 12.5, fontWeight: FontWeight.w700)),
      ]),
      const SizedBox(height: 9),
      NxSlider(value: value, min: min, max: max, step: step, onChanged: onChanged),
    ]);
  }
}

/// Главная кнопка. Метрики взяты из прототипа:
/// `gap:9px;padding:10px 14px;border-radius:999px;font-size:13.5px;
///  font-weight:600;box-shadow:0 6px 18px rgba(0,0,0,.22)` — заливка
/// акцентным градиентом `linear-gradient(96deg,a1,a2 48%,a3)`.
class GradientButton extends StatefulWidget {
  const GradientButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.large = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;

  /// Крупный вариант прототипа: 13×26, 14px, вес 700, тень глубже.
  final bool large;

  @override
  State<GradientButton> createState() => _GradientButtonState();
}

class _GradientButtonState extends State<GradientButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final large = widget.large;
    final enabled = widget.onTap != null;

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedOpacity(
          // В прототипе наведение гасит кнопку до .9 — больше ничего.
          duration: NxMotion.hover,
          opacity: !enabled ? 0.45 : (_hover ? 0.9 : 1),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: large ? 26 : 14,
              vertical: large ? 13 : 10,
            ),
            decoration: BoxDecoration(
              gradient: t.accent.sweep,
              borderRadius: BorderRadius.circular(NxRadius.chip),
              boxShadow: [
                BoxShadow(
                  color: Color.fromRGBO(0, 0, 0, large ? 0.28 : 0.22),
                  offset: Offset(0, large ? 12 : 6),
                  blurRadius: large ? 32 : 18,
                ),
              ],
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: large ? 17 : 16, color: Colors.white),
                const SizedBox(width: 9),
              ],
              Text(
                widget.label,
                style: NxType.label.copyWith(
                  color: Colors.white,
                  fontSize: large ? 14 : 13.5,
                  fontWeight: large ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Поле ввода в стиле EVS: подложка --field, рамка --stroke.
class NxField extends StatelessWidget {
  const NxField({super.key, required this.controller, this.hint, this.lines = 1, this.mono = false, this.obscure = false, this.radius = 16, this.fontSize = 13.5});
  final TextEditingController controller;
  final String? hint;
  final int lines;
  final bool mono;

  /// Прятать ввод точками — для паролей.
  final bool obscure;
  final double radius, fontSize;

  @override
  Widget build(BuildContext context) {
    final p = NxTheme.of(context).palette;
    return TextField(
      controller: controller,
      maxLines: obscure ? 1 : lines,
      obscureText: obscure,
      style: (mono ? NxType.numeric : NxType.bodyText).copyWith(color: p.body, fontSize: fontSize, height: 1.5),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: NxType.bodyText.copyWith(color: p.faint, fontSize: fontSize),
        filled: true,
        fillColor: p.field,
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: lines > 1 ? 14 : 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide(color: p.stroke)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide(color: p.stroke)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide(color: NxTheme.of(context).accent.a2)),
      ),
    );
  }
}

/// Второстепенная кнопка макета — стеклянная таблетка с тонкой рамкой.
///
/// CSS-источник: `padding:9px 15px;border-radius:999px;border:1px solid
/// var(--stroke);background:var(--card);font-size:12.5px;font-weight:500;
/// color:var(--body);transition:border-color .18s` — при наведении в
/// прототипе меняется именно рамка, а не заливка.
class NxGhostButton extends StatefulWidget {
  const NxGhostButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.danger = false,
    this.compact = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool danger;

  /// Плотный вариант для тесных панелей: те же цвета, меньше отступы.
  final bool compact;

  @override
  State<NxGhostButton> createState() => _NxGhostButtonState();
}

class _NxGhostButtonState extends State<NxGhostButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    final enabled = widget.onTap != null;

    final fg = !enabled
        ? p.faint
        : widget.danger
            ? NxPalette.danger
            : (_hover ? p.txt : p.body);
    final border = !enabled
        ? p.stroke
        : widget.danger && _hover
            ? NxPalette.danger.withValues(alpha: 0.55)
            : (_hover ? p.stroke2 : p.stroke);

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: NxMotion.hover,
          padding: EdgeInsets.symmetric(
            horizontal: widget.compact ? 12 : 15,
            vertical: widget.compact ? 7 : 9,
          ),
          decoration: BoxDecoration(
            color: t.card,
            borderRadius: BorderRadius.circular(NxRadius.chip),
            border: Border.all(color: border),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (widget.icon != null) ...[
              Icon(widget.icon, size: widget.compact ? 13 : 14, color: fg),
              const SizedBox(width: 8),
            ],
            Text(
              widget.label,
              style: NxType.label.copyWith(
                color: fg,
                fontSize: widget.compact ? 12 : 12.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Значок в акцентном градиенте со свечением — логотип, аватар, метка.
/// В прототипе у него `box-shadow: var(--glow)`, то самое мягкое пятно
/// вокруг, которого не хватало.
/// Полоска прогресса. Одна на всё приложение: и под строкой файла в списке,
/// и в очереди передач — чтобы «идёт передача» выглядело одинаково везде.
class NxProgressLine extends StatelessWidget {
  const NxProgressLine({super.key, required this.fraction, this.height = 4});

  final double fraction;
  final double height;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: SizedBox(
        height: height,
        child: Stack(children: [
          ColoredBox(color: t.palette.chip, child: const SizedBox.expand()),
          FractionallySizedBox(
            widthFactor: fraction.clamp(0.0, 1.0),
            child: DecoratedBox(decoration: BoxDecoration(gradient: t.accent.badge)),
          ),
        ]),
      ),
    );
  }
}

class NxBadge extends StatelessWidget {
  const NxBadge({
    super.key,
    required this.icon,
    this.size = 36,
    this.radius = 13,
    this.glow = true,
  });

  final IconData icon;
  final double size;
  final double radius;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: t.accent.badge,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: glow
            ? [BoxShadow(color: t.palette.glowColor, blurRadius: 44)]
            : null,
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: size * 0.5, color: Colors.white),
    );
  }
}
