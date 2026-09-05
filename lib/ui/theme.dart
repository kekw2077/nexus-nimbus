import 'package:flutter/material.dart';
import 'tokens.dart';

/// Живые настройки оформления: тема, акцент, матовость, фон, сетка точек.
/// Прототип держит их в состоянии верхнего компонента — здесь то же самое
/// через InheritedWidget, чтобы любой экран мог прочитать NxTheme.of(context).

enum NxBackground { aurora, shader, off }
enum NxDotMode { push, glow, off }
enum NxAnim { breathe, flow, pulse, off }

@immutable
class NxThemeData {
  const NxThemeData({
    this.brightness = Brightness.dark,
    this.accent = NxAccent.google,
    this.glass = NxGlass.glass,
    this.background = NxBackground.aurora,
    this.dots = NxDotMode.push,
    this.anim = NxAnim.breathe,
  });

  final Brightness brightness;
  final NxAccent accent;
  final NxGlass glass;
  final NxBackground background;
  final NxDotMode dots;
  final NxAnim anim;

  NxPalette get palette => brightness == Brightness.dark ? NxPalette.dark : NxPalette.light;
  Color get card => glass.card(brightness);
  double get blur => glass.blur;

  NxThemeData copyWith({Brightness? brightness, NxAccent? accent, NxGlass? glass,
      NxBackground? background, NxDotMode? dots, NxAnim? anim}) =>
      NxThemeData(
        brightness: brightness ?? this.brightness,
        accent: accent ?? this.accent,
        glass: glass ?? this.glass,
        background: background ?? this.background,
        dots: dots ?? this.dots,
        anim: anim ?? this.anim,
      );

  /// Material-тема, чтобы стандартные виджеты не выбивались из палитры.
  ThemeData toMaterial() {
    final p = palette;
    return ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: p.bg,
      fontFamily: NxType.ui,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent.a2,
        brightness: brightness,
        surface: p.solid,
        error: NxPalette.danger,
      ),
      textTheme: TextTheme(
        displayLarge: NxType.hero.copyWith(color: p.txt),
        titleLarge: NxType.title.copyWith(color: p.txt),
        bodyMedium: NxType.bodyText.copyWith(color: p.body),
        labelMedium: NxType.label.copyWith(color: p.body),
      ),
      dividerColor: p.stroke,
      splashFactory: NoSplash.splashFactory,
    );
  }
}

class NxTheme extends InheritedWidget {
  const NxTheme({super.key, required this.data, required this.onChanged, required super.child});

  final NxThemeData data;
  final ValueChanged<NxThemeData> onChanged;

  static NxThemeData of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NxTheme>()?.data ?? const NxThemeData();

  static void set(BuildContext context, NxThemeData next) =>
      context.findAncestorWidgetOfExactType<NxTheme>()?.onChanged(next);

  @override
  bool updateShouldNotify(NxTheme old) => old.data != data;
}

/// Обёртка приложения: держит настройки и раздаёт их вниз.
class NxApp extends StatefulWidget {
  const NxApp({super.key, required this.builder, this.initial = const NxThemeData(), this.onChanged});
  final WidgetBuilder builder;
  final NxThemeData initial;
  /// Вызывается при каждом изменении оформления — сюда вешается сохранение.
  final ValueChanged<NxThemeData>? onChanged;

  @override
  State<NxApp> createState() => _NxAppState();
}

class _NxAppState extends State<NxApp> {
  late NxThemeData _data = widget.initial;

  @override
  Widget build(BuildContext context) => NxTheme(
        data: _data,
        onChanged: (next) {
          setState(() => _data = next);
          widget.onChanged?.call(next);
        },
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _data.toMaterial(),
          home: Builder(builder: widget.builder),
        ),
      );
}
