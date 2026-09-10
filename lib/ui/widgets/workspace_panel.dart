import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';
import '../tokens.dart';

/// Описание папки — её README.md, который сервер отдаёт свойством
/// `nc:rich-workspace`. Веб-интерфейс показывает его шапкой над списком;
/// здесь оно занимает то же место — внутри панели с файлами, над шапкой
/// колонок, и отделено от списка той же линией, что и шапка. Своего
/// стекла у него нет: карточка в карточке читалась бы как другое окно,
/// а это часть той же папки.
///
/// Сворачивается: описание полезно, когда его читают, и мешает, когда
/// пришли за файлами. Длинный текст свёрнут до нескольких строк и
/// растворяется книзу — так видно, что там есть продолжение.
class WorkspacePanel extends StatefulWidget {
  const WorkspacePanel({super.key, required this.markdown, required this.maxHeight});

  final String markdown;

  /// Потолок для развёрнутой панели. Без него длинный README вытолкнул бы
  /// список файлов за край окна вместе с кнопкой «свернуть» — и вернуть
  /// всё назад было бы нечем. Внутри потолка текст листается.
  final double maxHeight;

  /// До какой высоты ужимается свёрнутое описание.
  static const _collapsedHeight = 132.0;

  /// Шапка с отступами и линией — вычитается из потолка, чтобы он был
  /// потолком всей панели, а не только текста.
  static const _chromeHeight = 66.0;

  /// Текст стоит вровень с колонкой «Имя»: у шапки списка это отступ 12
  /// плюс место под значок файла, 36.
  static const _textInset = 48.0;

  @override
  State<WorkspacePanel> createState() => _WorkspacePanelState();
}

class _WorkspacePanelState extends State<WorkspacePanel> {
  bool _expanded = false;

  @override
  void didUpdateWidget(WorkspacePanel old) {
    super.didUpdateWidget(old);
    // Другая папка — другое описание, и разворот от прошлого к нему
    // отношения не имеет.
    if (old.markdown != widget.markdown) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;

    final body = _Markdown(source: widget.markdown);

    // Отступы те же, что у шапки колонок: 12 по краям, линия во всю
    // ширину между ними.
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            // Значок стоит так, чтобы подпись начиналась вровень с текстом.
            padding: const EdgeInsets.only(left: WorkspacePanel._textInset - 12 - 20),
            child: Row(children: [
              Icon(Icons.subject_rounded, size: 13, color: p.faint),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  'ОПИСАНИЕ ПАПКИ',
                  style: NxType.section.copyWith(color: p.faint),
                ),
              ),
              _ToggleButton(
                expanded: _expanded,
                onTap: () => setState(() => _expanded = !_expanded),
              ),
            ]),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.only(left: WorkspacePanel._textInset - 12, right: 36),
            child: AnimatedSize(
            duration: NxMotion.hover,
            curve: NxMotion.curve,
            alignment: Alignment.topCenter,
            child: _expanded
                ? ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: (widget.maxHeight - WorkspacePanel._chromeHeight)
                          .clamp(WorkspacePanel._collapsedHeight, double.infinity),
                    ),
                    child: SingleChildScrollView(
                      child: SizedBox(width: double.infinity, child: body),
                    ),
                  )
                : _Faded(
                    height: WorkspacePanel._collapsedHeight,
                    child: body,
                  ),
            ),
          ),
          const SizedBox(height: 14),
          Divider(height: 1, thickness: 1, color: p.stroke),
        ],
      ),
    );
  }
}

/// Свёрнутый текст: не выше [height], растворяется книзу, если не влез.
/// Обрезка сама по себе выглядит как оборванная строка — градиент
/// показывает, что там есть продолжение. Короткому описанию гаснуть
/// нечему, и оно занимает ровно столько, сколько занимает.
class _Faded extends StatelessWidget {
  const _Faded({required this.height, required this.child});

  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: height),
      child: ShaderMask(
        // Прокрутка внизу ужимается к содержимому, поэтому её высота равна
        // потолку ровно тогда, когда текст в него не влез. Только тогда и
        // растворяем; иначе гасили бы хвост у текста, который виден целиком.
        shaderCallback: (rect) {
          final overflowing = rect.height >= height - 0.5;
          return LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: overflowing
                ? const [Colors.white, Colors.white, Colors.transparent]
                : const [Colors.white, Colors.white, Colors.white],
            stops: const [0, 0.62, 1],
          ).createShader(rect);
        },
        blendMode: BlendMode.dstIn,
        // Прокрутка — только ради раскладки: она даёт тексту любую высоту,
        // сама ужимается к нему и обрезает лишнее. Листать её нельзя —
        // для этого есть «показать целиком».
        child: SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          child: SizedBox(width: double.infinity, child: child),
        ),
      ),
    );
  }
}

class _ToggleButton extends StatefulWidget {
  const _ToggleButton({required this.expanded, required this.onTap});

  final bool expanded;
  final VoidCallback onTap;

  @override
  State<_ToggleButton> createState() => _ToggleButtonState();
}

class _ToggleButtonState extends State<_ToggleButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;

    return Tooltip(
      message: widget.expanded ? 'Свернуть описание' : 'Показать целиком',
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: _hover ? p.hover : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              widget.expanded ? Icons.unfold_less_rounded : Icons.unfold_more_rounded,
              size: 15,
              color: _hover ? p.body : p.faint,
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- markdown

/// Свой разбор markdown вместо пакета. Причина не в гордости: описание
/// папки — это несколько абзацев, заголовков и списков, а любой готовый
/// пакет тянет своё оформление, которое пришлось бы перекрашивать под
/// палитру целиком. Здесь же текст сразу рисуется токенами Nexus.
///
/// Поддержано то, что встречается в README: заголовки, списки, цитаты,
/// код (строкой и блоком), разделители, жирный, наклонный, ссылки.
/// Таблицы показываются как есть, моноширинно — ломать их выравнивание
/// хуже, чем оставить.
class _Markdown extends StatefulWidget {
  const _Markdown({required this.source});

  final String source;

  @override
  State<_Markdown> createState() => _MarkdownState();
}

class _MarkdownState extends State<_Markdown> {
  /// Распознаватели нажатий по ссылкам. Они не виджеты и сами не
  /// исчезают: если создавать их прямо в отрисовке, каждая перерисовка
  /// оставляла бы после себя новый набор. Держим по одному на адрес и
  /// отпускаем все разом вместе с панелью.
  final _links = <String, TapGestureRecognizer>{};

  @override
  void dispose() {
    for (final r in _links.values) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    final lines = widget.source.replaceAll('\r\n', '\n').split('\n');
    final out = <Widget>[];

    var inFence = false;
    var fence = <String>[];

    void flushFence() {
      if (fence.isEmpty) return;
      out.add(_CodeBlock(lines: List.of(fence)));
      fence = [];
    }

    for (final raw in lines) {
      final line = raw.trimRight();

      if (line.trimLeft().startsWith('```')) {
        if (inFence) {
          flushFence();
          inFence = false;
        } else {
          inFence = true;
        }
        continue;
      }
      if (inFence) {
        fence.add(raw);
        continue;
      }

      if (line.trim().isEmpty) {
        out.add(const SizedBox(height: 8));
        continue;
      }

      // Разделитель: три и больше дефиса, звёздочки или подчёркивания.
      if (RegExp(r'^\s*([-*_])\s*\1\s*\1[\s\-*_]*$').hasMatch(line)) {
        out.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Container(height: 1, color: p.stroke),
        ));
        continue;
      }

      final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line.trimLeft());
      if (heading != null) {
        final level = heading.group(1)!.length;
        out.add(Padding(
          padding: EdgeInsets.only(top: out.isEmpty ? 0 : 6, bottom: 4),
          child: _inline(
            heading.group(2)!,
            context,
            base: NxType.bodyText.copyWith(
              color: p.txt,
              fontSize: switch (level) { 1 => 17, 2 => 15, 3 => 13.5, _ => 12.5 },
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
              height: 1.35,
            ),
          ),
        ));
        continue;
      }

      // Таблицу не разбираем — показываем строкой, как написано.
      if (line.trim().startsWith('|') && line.trim().endsWith('|')) {
        out.add(Text(
          line.trim(),
          style: NxType.numeric.copyWith(color: p.sub, fontSize: 11, height: 1.6),
        ));
        continue;
      }

      final quote = RegExp(r'^\s*>\s?(.*)$').firstMatch(line);
      if (quote != null) {
        // Полоса слева — рамкой контейнера, а не отдельным виджетом в Row
        // со stretch: у панели нет ограничения по высоте, и stretch
        // потребовал бы от полосы бесконечной высоты. В отладке это
        // исключение, в релизе — молча пустая панель.
        out.add(Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: t.accent.a2.withValues(alpha: 0.6), width: 2),
            ),
          ),
          child: _inline(quote.group(1)!, context,
              base: NxType.bodyText.copyWith(color: p.sub, fontSize: 12.5, height: 1.55)),
        ));
        continue;
      }

      final bullet = RegExp(r'^(\s*)[-*+]\s+(.*)$').firstMatch(line);
      final numbered = RegExp(r'^(\s*)(\d+)[.)]\s+(.*)$').firstMatch(line);
      if (bullet != null || numbered != null) {
        final indent = (bullet ?? numbered)!.group(1)!.length ~/ 2;
        final marker = bullet != null ? '•' : '${numbered!.group(2)}.';
        final text = bullet != null ? bullet.group(2)! : numbered!.group(3)!;
        out.add(Padding(
          padding: EdgeInsets.only(left: 6.0 + indent * 14, top: 1, bottom: 1),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: bullet != null ? 14 : 20,
              child: Text(
                marker,
                style: NxType.bodyText.copyWith(
                  color: bullet != null ? t.accent.a2 : p.faint,
                  fontSize: 12.5,
                  height: 1.55,
                ),
              ),
            ),
            Expanded(
              child: _inline(text, context,
                  base: NxType.bodyText.copyWith(color: p.body, fontSize: 12.5, height: 1.55)),
            ),
          ]),
        ));
        continue;
      }

      out.add(_inline(line.trimLeft(), context,
          base: NxType.bodyText.copyWith(color: p.body, fontSize: 12.5, height: 1.55)));
    }

    if (inFence) flushFence();

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: out);
  }

  /// Разбор внутри строки. Идём слева направо и откусываем первое из
  /// того, что встретилось; вложенность оформления в README редкость,
  /// а разбирать её как следует — это уже свой парсер.
  Widget _inline(String text, BuildContext context, {required TextStyle base}) {
    final t = NxTheme.of(context);
    final p = t.palette;
    final spans = <InlineSpan>[];
    final pattern = RegExp(
      r'\*\*(.+?)\*\*'
      r'|__(.+?)__'
      r'|(?<!\w)\*(?!\s)(.+?)(?<!\s)\*(?!\w)'
      r'|(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)'
      r'|`([^`]+)`'
      r'|\[([^\]]+)\]\(([^)\s]+)\)'
      r'|(https?://\S+)',
    );

    var at = 0;
    for (final m in pattern.allMatches(text)) {
      if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start), style: base));
      at = m.end;

      if (m.group(1) != null || m.group(2) != null) {
        spans.add(TextSpan(
          text: m.group(1) ?? m.group(2),
          style: base.copyWith(fontWeight: FontWeight.w700, color: p.txt),
        ));
      } else if (m.group(3) != null || m.group(4) != null) {
        spans.add(TextSpan(
          text: m.group(3) ?? m.group(4),
          style: base.copyWith(fontStyle: FontStyle.italic),
        ));
      } else if (m.group(5) != null) {
        spans.add(TextSpan(
          text: m.group(5),
          style: base.copyWith(
            fontFamily: NxType.mono,
            fontSize: (base.fontSize ?? 12.5) - 1.5,
            color: t.accent.a1,
            backgroundColor: p.chip,
          ),
        ));
      } else {
        final label = m.group(6) ?? m.group(8) ?? '';
        final href = m.group(7) ?? m.group(8) ?? '';
        spans.add(TextSpan(
          text: label,
          style: base.copyWith(color: t.accent.a2, decoration: TextDecoration.underline),
          recognizer: _linkTap(href),
        ));
      }
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at), style: base));

    return Text.rich(TextSpan(children: spans));
  }

  /// Ссылка открывается в браузере — и только настоящая. Относительные
  /// пути внутри облака сюда не годятся: у клиента нет способа показать
  /// их, а браузер увёл бы в никуда.
  GestureRecognizer? _linkTap(String href) {
    final uri = Uri.tryParse(href);
    if (uri == null || !uri.hasScheme || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return null;
    }
    return _links.putIfAbsent(
      href,
      () => TapGestureRecognizer()..onTap = () => launchUrl(uri),
    );
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: p.field,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: p.stroke),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text(
          lines.join('\n'),
          style: NxType.numeric.copyWith(color: p.sub, fontSize: 11, height: 1.5),
        ),
      ),
    );
  }
}
