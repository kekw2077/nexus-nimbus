import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/models/remote_file.dart';
import '../../core/session.dart';
import '../theme.dart';
import '../tokens.dart';
import 'controls.dart';
import 'file_views.dart';
import 'glass_panel.dart';
import 'presence_badge.dart';

/// Поиск по всему дереву, а не по текущей папке. Возвращает путь папки,
/// которую надо открыть, — или null, если ничего не выбрали.
///
/// Имя с приставкой «server» не случайно: в Material уже есть свой
/// `showSearch`, и без неё вызов в экране файлов стал бы двусмысленным.
Future<String?> showServerSearch(
  BuildContext context, {
  required Session session,
  String initial = '',
}) {
  final t = NxTheme.of(context);
  return showDialog<String>(
    context: context,
    barrierColor: const Color(0x99000000),
    builder: (ctx) => NxTheme(
      data: t,
      onChanged: (_) {},
      child: Center(
        child: SizedBox(
          width: 620,
          child: GlassPanel(
            radius: NxRadius.card,
            padding: const EdgeInsets.all(22),
            shadow: true,
            color: t.palette.solid,
            child: _SearchBody(session: session, initial: initial),
          ),
        ),
      ),
    ),
  );
}

class _SearchBody extends StatefulWidget {
  const _SearchBody({required this.session, required this.initial});
  final Session session;
  final String initial;

  @override
  State<_SearchBody> createState() => _SearchBodyState();
}

class _SearchBodyState extends State<_SearchBody> {
  late final TextEditingController _query =
      TextEditingController(text: widget.initial);

  Timer? _debounce;
  List<RemoteFile> _results = const [];
  bool _searching = false;
  String? _error;

  /// Что искали в последний раз — по нему видно, устарел ли список.
  String _asked = '';

  /// Ждём, пока человек допечатает: каждый нажатый символ — запрос к серверу.
  static const _settle = Duration(milliseconds: 400);

  @override
  void initState() {
    super.initState();
    _query.addListener(_onTyped);
    if (widget.initial.trim().isNotEmpty) _run();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.removeListener(_onTyped);
    _query.dispose();
    super.dispose();
  }

  void _onTyped() {
    _debounce?.cancel();
    _debounce = Timer(_settle, _run);
  }

  Future<void> _run() async {
    final needle = _query.text.trim();
    if (needle.isEmpty) {
      setState(() {
        _results = const [];
        _error = null;
        _asked = '';
      });
      return;
    }

    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final found = await widget.session.dav.search(needle);
      if (!mounted) return;
      // Пока ходили на сервер, могли напечатать дальше — тогда этот ответ
      // уже не про то, что в поле, и показывать его не надо.
      if (_query.text.trim() != needle) return;
      setState(() {
        _results = found;
        _asked = needle;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _results = const [];
        _error = e.toString();
        _asked = needle;
        _searching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Поиск по серверу',
                style: NxType.title.copyWith(color: p.txt, fontSize: 17)),
            const SizedBox(height: 3),
            Text(_subtitle(), style: NxType.caption.copyWith(color: p.sub)),
          ]),
        ),
        if (_searching)
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: t.accent.a2),
          ),
      ]),
      const SizedBox(height: 14),
      NxField(controller: _query, hint: 'Часть имени файла или папки'),
      const SizedBox(height: 14),
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 360),
        child: _list(p),
      ),
      const SizedBox(height: 18),
      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        NxGhostButton(label: 'Закрыть', onTap: () => Navigator.of(context).pop()),
      ]),
    ]);
  }

  String _subtitle() {
    if (_error != null) return 'Не получилось';
    if (_asked.isEmpty) return 'Ищет по всему дереву, а не только в открытой папке';
    if (_results.isEmpty) return 'Ничего не нашлось';
    return '${_results.length} '
        '${plural(_results.length, 'совпадение', 'совпадения', 'совпадений')}';
  }

  Widget _list(NxPalette p) {
    final error = _error;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 22),
        child: Text(error,
            textAlign: TextAlign.center,
            style: NxType.bodyText.copyWith(color: NxPalette.danger, fontSize: 12.5)),
      );
    }

    if (_results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(
          _asked.isEmpty
              ? 'Начните печатать — поиск пойдёт сам.'
              : 'По запросу «$_asked» на сервере ничего нет.',
          textAlign: TextAlign.center,
          style: NxType.bodyText.copyWith(color: p.sub, fontSize: 12.5),
        ),
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      itemCount: _results.length,
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (context, i) {
        final f = _results[i];
        return _ResultRow(
          file: f,
          session: widget.session,
          // Папку открываем саму, файл — вместе с его папкой.
          onOpen: () => Navigator.of(context).pop(f.isDir ? f.path : f.parent),
        );
      },
    );
  }
}

class _ResultRow extends StatefulWidget {
  const _ResultRow({
    required this.file,
    required this.session,
    required this.onOpen,
  });

  final RemoteFile file;
  final Session session;
  final VoidCallback onOpen;

  @override
  State<_ResultRow> createState() => _ResultRowState();
}

class _ResultRowState extends State<_ResultRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = NxTheme.of(context).palette;
    final f = widget.file;
    final where = f.parent.isEmpty ? 'в корне' : f.parent;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onOpen,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          decoration: BoxDecoration(
            color: _hover ? p.hover : p.field,
            borderRadius: BorderRadius.circular(NxRadius.tile),
            border: Border.all(color: p.stroke),
          ),
          child: Row(children: [
            FileThumbnail(file: f, cache: widget.session.thumbs, size: 22),
            const SizedBox(width: 11),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(f.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NxType.bodyText.copyWith(color: p.txt, fontSize: 12.5)),
                const SizedBox(height: 2),
                Text(where,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NxType.numeric.copyWith(color: p.faint, fontSize: 10)),
              ]),
            ),
            const SizedBox(width: 10),
            PresenceBadge(presence: widget.session.vault.presenceOf(f), size: 13),
            const SizedBox(width: 12),
            SizedBox(
              width: 74,
              child: Text(
                f.isDir && f.size == 0 ? '—' : formatBytes(f.size),
                textAlign: TextAlign.right,
                style: NxType.numeric.copyWith(color: p.sub, fontSize: 11),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
