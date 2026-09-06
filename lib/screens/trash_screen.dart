import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/models/trash_item.dart';
import '../core/session.dart';
import '../services/webdav_client.dart';
import '../ui/theme.dart';
import '../ui/tokens.dart';
import '../ui/widgets/controls.dart';
import '../ui/widgets/dialogs.dart';
import '../ui/widgets/glass_panel.dart';
import '../ui/widgets/menu.dart';

/// Корзина сервера. Удалённое лежит здесь, пока его не вернут или не сотрут
/// насовсем; сколько именно — решает настройка retention на сервере.
class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key, required this.session});
  final Session session;

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  Session get s => widget.session;

  List<TrashItem> _items = const [];
  final Set<String> _selection = {};
  bool _loading = true;
  String? _error;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await s.dav.listTrash();
      if (!mounted) return;
      setState(() {
        _items = items;
        _selection.removeWhere((id) => !items.any((i) => i.id == id));
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _items = const [];
        _error = e.toString();
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<TrashItem> get _visible {
    final needle = _filter.trim().toLowerCase();
    if (needle.isEmpty) return _items;
    return _items.where((i) => i.name.toLowerCase().contains(needle)).toList();
  }

  List<TrashItem> get _selected =>
      _items.where((i) => _selection.contains(i.id)).toList();

  void _toast(String message, {bool danger = false}) {
    final p = NxTheme.of(context).palette;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        width: 520,
        backgroundColor: p.solid,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NxRadius.tile),
          side: BorderSide(color: danger ? NxPalette.danger : p.stroke2),
        ),
        content: Row(children: [
          Icon(danger ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
              size: 16, color: danger ? NxPalette.danger : NxPalette.ok),
          const SizedBox(width: 11),
          Expanded(
            child: Text(message, style: NxType.bodyText.copyWith(color: p.body, fontSize: 12.5)),
          ),
        ]),
      ));
  }

  Future<void> _restore(List<TrashItem> items) async {
    if (items.isEmpty) return;
    try {
      for (final item in items) {
        await s.dav.restoreFromTrash(item);
      }
      _selection.clear();
      await _load();
      // Файл вернулся в исходную папку — если мы сейчас в ней, список устарел.
      await s.refresh();
      if (mounted) {
        _toast(items.length == 1
            ? 'Восстановлено: «${items.first.name}»'
            : 'Восстановлено объектов: ${items.length}');
      }
    } on NextcloudException catch (e) {
      if (mounted) _toast(e.message, danger: true);
    } catch (e) {
      if (mounted) _toast(e.toString(), danger: true);
    }
  }

  Future<void> _deleteForever(List<TrashItem> items) async {
    if (items.isEmpty) return;
    final what = items.length == 1
        ? '«${items.first.name}»'
        : '${items.length} ${plural(items.length, 'объект', 'объекта', 'объектов')}';
    final ok = await confirm(
      context,
      title: 'Стереть $what насовсем?',
      message: 'После этого файл не вернуть ничем: ни из корзины, ни из версий.',
      confirmLabel: 'Стереть',
    );
    if (!ok) return;
    try {
      for (final item in items) {
        await s.dav.deleteFromTrash(item);
      }
      _selection.clear();
      await _load();
    } catch (e) {
      if (mounted) _toast(e.toString(), danger: true);
    }
  }

  Future<void> _empty() async {
    final ok = await confirm(
      context,
      title: 'Очистить корзину?',
      message: 'Будет стёрто ${_items.length} '
          '${plural(_items.length, 'объект', 'объекта', 'объектов')} '
          'на ${formatBytes(_items.fold<int>(0, (a, i) => a + i.size))}. '
          'Вернуть их будет нельзя.',
      confirmLabel: 'Очистить',
    );
    if (!ok) return;
    try {
      await s.dav.emptyTrash();
      _selection.clear();
      await _load();
      if (mounted) _toast('Корзина очищена');
    } catch (e) {
      if (mounted) _toast(e.toString(), danger: true);
    }
  }

  void _menu(Offset at, TrashItem item) {
    if (!_selection.contains(item.id)) {
      setState(() {
        _selection
          ..clear()
          ..add(item.id);
      });
    }
    final items = _selected;
    showNimbusMenu(context, at, [
      MenuAction(
        items.length > 1 ? 'Восстановить выбранное' : 'Восстановить',
        Icons.restore_rounded,
        () => _restore(items),
      ),
      menuSeparator,
      MenuAction('Стереть насовсем', Icons.delete_forever_rounded,
          () => _deleteForever(items), danger: true),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    final total = _items.fold<int>(0, (a, i) => a + i.size);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              GradientText('Корзина', style: NxType.title),
              const SizedBox(height: 3),
              Text(
                _items.isEmpty
                    ? 'Удалённое с сервера появляется здесь'
                    : '${_items.length} '
                        '${plural(_items.length, 'объект', 'объекта', 'объектов')} · '
                        '${formatBytes(total)}',
                style: NxType.caption.copyWith(color: p.sub),
              ),
            ]),
          ),
          SizedBox(
            width: 200,
            child: _Search(
              value: _filter,
              onChanged: (v) => setState(() => _filter = v),
            ),
          ),
          const SizedBox(width: 8),
          NxGhostButton(label: 'Обновить', icon: Icons.refresh_rounded, onTap: _load),
          if (_items.isNotEmpty) ...[
            const SizedBox(width: 8),
            NxGhostButton(
              label: 'Очистить корзину',
              icon: Icons.delete_sweep_rounded,
              danger: true,
              onTap: _empty,
            ),
          ],
        ]),
      ),
      if (_selection.isNotEmpty)
        Container(
          margin: const EdgeInsets.fromLTRB(18, 0, 18, 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: p.accentSoft,
            borderRadius: BorderRadius.circular(NxRadius.tile),
            border: Border.all(color: t.accent.a2.withValues(alpha: 0.45)),
          ),
          child: Row(children: [
            Icon(Icons.check_circle_rounded, size: 15, color: t.accent.a2),
            const SizedBox(width: 10),
            Text('Выбрано ${_selection.length}',
                style: NxType.label.copyWith(color: p.txt, fontSize: 12.5)),
            const Spacer(),
            NxGhostButton(
                label: 'Восстановить',
                icon: Icons.restore_rounded,
                onTap: () => _restore(_selected)),
            const SizedBox(width: 6),
            NxGhostButton(
              label: 'Стереть насовсем',
              icon: Icons.delete_forever_rounded,
              danger: true,
              onTap: () => _deleteForever(_selected),
            ),
            const SizedBox(width: 10),
            GestureDetector(
              onTap: () => setState(_selection.clear),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Icon(Icons.close_rounded, size: 15, color: p.sub),
              ),
            ),
          ]),
        ),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
          child: GlassPanel(
            radius: NxRadius.panel,
            padding: EdgeInsets.zero,
            child: _body(t, p),
          ),
        ),
      ),
    ]);
  }

  Widget _body(NxThemeData t, NxPalette p) {
    if (_loading && _items.isEmpty) {
      return Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.2, color: t.accent.a2),
        ),
      );
    }

    if (_error != null) {
      return _Placeholder(
        icon: Icons.delete_outline_rounded,
        title: 'Корзина недоступна',
        message: _error!,
        actionLabel: 'Повторить',
        onAction: _load,
      );
    }

    final items = _visible;
    if (items.isEmpty) {
      return _Placeholder(
        icon: _filter.isNotEmpty ? Icons.search_off_rounded : Icons.delete_outline_rounded,
        title: _filter.isNotEmpty ? 'Ничего не нашлось' : 'Корзина пуста',
        message: _filter.isNotEmpty
            ? 'Среди удалённого нет ничего, подходящего под «$_filter».'
            : 'Всё, что вы удалите, будет попадать сюда — и отсюда его можно '
                'вернуть на прежнее место.',
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => setState(_selection.clear),
      child: ListView.builder(
        padding: const EdgeInsets.all(10),
        itemCount: items.length,
        itemBuilder: (context, i) {
          final item = items[i];
          return _TrashRow(
            item: item,
            selected: _selection.contains(item.id),
            onTap: () => setState(() {
              _selection.contains(item.id)
                  ? _selection.remove(item.id)
                  : _selection.add(item.id);
            }),
            onRestore: () => _restore([item]),
            onSecondaryTap: (at) => _menu(at, item),
          );
        },
      ),
    );
  }
}

class _TrashRow extends StatefulWidget {
  const _TrashRow({
    required this.item,
    required this.selected,
    required this.onTap,
    required this.onRestore,
    required this.onSecondaryTap,
  });

  final TrashItem item;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onRestore;
  final void Function(Offset globalPosition) onSecondaryTap;

  @override
  State<_TrashRow> createState() => _TrashRowState();
}

class _TrashRowState extends State<_TrashRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    final item = widget.item;
    final from = item.restoreFolder.isEmpty ? 'Все файлы' : item.restoreFolder;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onDoubleTap: widget.onRestore,
        onSecondaryTapUp: (d) => widget.onSecondaryTap(d.globalPosition),
        child: Container(
          margin: const EdgeInsets.only(bottom: 3),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: widget.selected
                ? p.accentSoft
                : _hover
                    ? p.hover
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(NxRadius.tile),
            border: Border.all(
              color: widget.selected
                  ? t.accent.a2.withValues(alpha: 0.45)
                  : Colors.transparent,
            ),
          ),
          child: Row(children: [
            Icon(
              iconFor(isDir: item.isDir, extension: item.extension, mime: item.mimeType),
              size: 20,
              color: item.isDir ? t.accent.a2 : p.sub,
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NxType.bodyText.copyWith(color: p.txt, fontSize: 12.5)),
                const SizedBox(height: 2),
                Text('из $from',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NxType.numeric.copyWith(color: p.faint, fontSize: 10)),
              ]),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 78,
              child: Text(item.isDir && item.size == 0 ? '—' : formatBytes(item.size),
                  textAlign: TextAlign.right,
                  style: NxType.numeric.copyWith(color: p.sub, fontSize: 11)),
            ),
            const SizedBox(width: 16),
            SizedBox(
              width: 128,
              child: Text('удалён ${formatDate(item.deletedAt)}',
                  textAlign: TextAlign.right,
                  style: NxType.numeric.copyWith(color: p.faint, fontSize: 10.5)),
            ),
            SizedBox(
              width: 34,
              child: _hover
                  ? Tooltip(
                      message: 'Восстановить на прежнее место',
                      waitDuration: const Duration(milliseconds: 500),
                      child: GestureDetector(
                        onTap: widget.onRestore,
                        child: Icon(Icons.restore_rounded, size: 16, color: t.accent.a2),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Search extends StatelessWidget {
  const _Search({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    return SizedBox(
      height: 32,
      child: TextField(
        onChanged: onChanged,
        style: NxType.bodyText.copyWith(color: p.body, fontSize: 12.5),
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Поиск в корзине',
          hintStyle: NxType.bodyText.copyWith(color: p.faint, fontSize: 12.5),
          prefixIcon: Icon(Icons.search_rounded, size: 15, color: p.faint),
          prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          filled: true,
          fillColor: p.field,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(NxRadius.chip),
              borderSide: BorderSide(color: p.stroke)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(NxRadius.chip),
              borderSide: BorderSide(color: p.stroke)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(NxRadius.chip),
              borderSide: BorderSide(color: t.accent.a2)),
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final p = NxTheme.of(context).palette;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 42, color: p.faint),
          const SizedBox(height: 16),
          Text(title, style: NxType.title.copyWith(color: p.txt, fontSize: 17)),
          const SizedBox(height: 8),
          Text(message,
              textAlign: TextAlign.center,
              style: NxType.bodyText.copyWith(color: p.sub, fontSize: 12.5, height: 1.5)),
          if (actionLabel != null) ...[
            const SizedBox(height: 20),
            GradientButton(label: actionLabel!, onTap: onAction),
          ],
        ]),
      ),
    );
  }
}
