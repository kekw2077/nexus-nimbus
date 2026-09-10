import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_nimbus/ui/widgets/workspace_panel.dart';

/// README со всем, что разбирает панель: заголовки, оформление в строке,
/// цитата, списки двух видов и вложенный, таблица, код блоком и строкой,
/// разделитель, ссылки в двух записях.
const _readme = '''
# Nexus Anima

**Nexus Anima** (прежнее имя — EVS) — десктопный голосовой ассистент
для *Windows*: прослушивание со словом-активатором и чат с ИИ.

> Важно: цитата с `кодом` внутри и ссылкой на [сайт](https://example.com).

## Что умеет

- постоянное прослушивание
- чат с ИИ — https://example.org
  - вложенный пункт
1. первый
2. второй

| Колонка | Ещё |
|---|---|
| a | b |

```dart
void main() {}
```

---
Последняя строка.
''';

/// Панель в том же окружении, что и в приложении: колонка, где под
/// панелью лежит список файлов, забирающий остаток высоты.
Widget _host(String markdown, {double height = 700}) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 900,
          height: height,
          child: LayoutBuilder(
            builder: (context, constraints) => Column(children: [
              WorkspacePanel(
                markdown: markdown,
                maxHeight: constraints.maxHeight * 0.55,
              ),
              const Expanded(child: SizedBox.expand(key: Key('list'))),
            ]),
          ),
        ),
      ),
    );

void main() {
  group('панель описания папки', () {
    testWidgets('свёрнутая рисует текст и не роняет раскладку', (tester) async {
      await tester.pumpWidget(_host(_readme));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('ОПИСАНИЕ ПАПКИ'), findsOneWidget);
      expect(find.textContaining('Nexus Anima'), findsWidgets);
      expect(find.textContaining('цитата'), findsOneWidget);
      expect(find.textContaining('вложенный пункт'), findsOneWidget);

      // Список под панелью должен остаться на экране.
      final list = tester.getSize(find.byKey(const Key('list')));
      expect(list.height, greaterThan(300));
    });

    testWidgets('развёрнутая не выталкивает список и оставляет кнопку', (tester) async {
      await tester.pumpWidget(_host(_readme));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Показать целиком'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('ОПИСАНИЕ ПАПКИ'), findsOneWidget);
      expect(find.byTooltip('Свернуть описание'), findsOneWidget);
      expect(find.textContaining('Последняя строка'), findsOneWidget);

      // Развёрнутая панель занимает не больше своей доли окна.
      final panel = tester.getSize(find.byType(WorkspacePanel));
      expect(panel.height, lessThanOrEqualTo(700 * 0.55 + 1));
      final list = tester.getSize(find.byKey(const Key('list')));
      expect(list.height, greaterThan(250));

      // И сворачивается обратно.
      await tester.tap(find.byTooltip('Свернуть описание'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Показать целиком'), findsOneWidget);
    });

    testWidgets('короткое описание не растягивается до предела', (tester) async {
      await tester.pumpWidget(_host('Одна строка.'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final panel = tester.getSize(find.byType(WorkspacePanel));
      expect(panel.height, lessThan(120));
    });

    testWidgets('смена папки сворачивает описание', (tester) async {
      await tester.pumpWidget(_host(_readme));
      await tester.tap(find.byTooltip('Показать целиком'));
      await tester.pumpAndSettle();

      await tester.pumpWidget(_host('# Другая папка\n\nСовсем другой текст.'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Показать целиком'), findsOneWidget);
      expect(find.textContaining('Другая папка'), findsOneWidget);
    });
  });
}
