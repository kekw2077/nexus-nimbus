import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/format.dart';
import '../../core/models/public_link.dart';
import '../../core/models/remote_file.dart';
import '../../core/session.dart';
import '../theme.dart';
import '../tokens.dart';
import 'controls.dart';
import 'dialogs.dart';
import 'glass_panel.dart';

/// Публичные ссылки на файл или папку. Возвращает true, если список менялся —
/// значит, признак «расшарено» в списке файлов мог устареть.
Future<bool> showShareLinks(
  BuildContext context, {
  required Session session,
  required RemoteFile file,
}) async {
  final t = NxTheme.of(context);
  final changed = await showDialog<bool>(
    context: context,
    barrierColor: const Color(0x99000000),
    builder: (ctx) => NxTheme(
      data: t,
      onChanged: (_) {},
      child: Center(
        child: SizedBox(
          width: 560,
          child: GlassPanel(
            radius: NxRadius.card,
            padding: const EdgeInsets.all(22),
            shadow: true,
            color: t.palette.solid,
            child: _ShareBody(session: session, file: file),
          ),
        ),
      ),
    ),
  );
  return changed ?? false;
}

class _ShareBody extends StatefulWidget {
  const _ShareBody({required this.session, required this.file});
  final Session session;
  final RemoteFile file;

  @override
  State<_ShareBody> createState() => _ShareBodyState();
}

class _ShareBodyState extends State<_ShareBody> {
  final _password = TextEditingController();

  List<PublicLink> _links = const [];
  bool _loading = true;
  bool _working = false;
  String? _error;
  bool _changed = false;

  /// Срок ссылки в днях. Ноль — бессрочно.
  int _days = 0;
  bool _allowUpload = false;

  static const _termLabels = ['бессрочно', '7 дней', '30 дней'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.session.dav.listLinks(widget.file.path);
      if (!mounted) return;
      setState(() {
        _links = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _create() async {
    setState(() => _working = true);
    try {
      await widget.session.dav.createLink(
        widget.file.path,
        password: _password.text.trim().isEmpty ? null : _password.text.trim(),
        expiresAt: _days == 0 ? null : DateTime.now().add(Duration(days: _days)),
        allowUpload: _allowUpload && widget.file.isDir,
      );
      _changed = true;
      _password.clear();
      if (!mounted) return;
      await _load();
    } catch (e) {
      if (!mounted) return;
      showNxToast(context, e.toString(), danger: true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _delete(PublicLink link) async {
    final ok = await confirm(
      context,
      title: 'Убрать ссылку?',
      message: 'Она перестанет открываться у всех, кому её отправляли. '
          'Сам файл останется на месте.',
      confirmLabel: 'Убрать',
    );
    if (!ok || !mounted) return;

    try {
      await widget.session.dav.deleteLink(link.id);
      _changed = true;
      if (!mounted) return;
      await _load();
    } catch (e) {
      if (!mounted) return;
      showNxToast(context, e.toString(), danger: true);
    }
  }

  Future<void> _copy(PublicLink link) async {
    await Clipboard.setData(ClipboardData(text: link.url));
    if (!mounted) return;
    showNxToast(context, 'Ссылка скопирована', icon: Icons.link_rounded);
  }

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    final options = widget.session.account.provider.hasLinkOptions;

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Публичные ссылки', style: NxType.title.copyWith(color: p.txt, fontSize: 17)),
      const SizedBox(height: 3),
      Text(widget.file.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: NxType.caption.copyWith(color: p.sub)),
      const SizedBox(height: 16),

      // ------------------------------------------------------ новая ссылка
      Container(
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 14),
        decoration: BoxDecoration(
          color: p.field,
          borderRadius: BorderRadius.circular(NxRadius.tile),
          border: Border.all(color: p.stroke),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SectionLabel('Новая ссылка'),
          // Пароль, срок и право загружать принимает не всякое облако:
          // Яндекс ссылку просто включает и выключает.
          if (options) ...[
            const SizedBox(height: 11),
            NxField(
              controller: _password,
              hint: 'Пароль — если он нужен',
              obscure: true,
            ),
            const SizedBox(height: 11),
            Row(children: [
              Text('Срок',
                  style: NxType.bodyText.copyWith(color: p.body, fontSize: 12.5)),
              const SizedBox(width: 12),
              NxSegmented(
                compact: true,
                options: _termLabels,
                value: _termLabels[_days == 0 ? 0 : (_days == 7 ? 1 : 2)],
                onChanged: (v) => setState(() {
                  _days = switch (v) { '7 дней' => 7, '30 дней' => 30, _ => 0 };
                }),
              ),
            ]),
          ],
          if (options && widget.file.isDir) ...[
            const SizedBox(height: 11),
            Row(children: [
              Expanded(
                child: Text('Разрешить загружать в папку',
                    style: NxType.bodyText.copyWith(color: p.body, fontSize: 12.5)),
              ),
              NxToggle(
                value: _allowUpload,
                onChanged: (v) => setState(() => _allowUpload = v),
              ),
            ]),
          ],
          const SizedBox(height: 13),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            GradientButton(
              label: _working ? 'Создаём…' : 'Создать ссылку',
              onTap: _working ? null : _create,
            ),
          ]),
        ]),
      ),
      const SizedBox(height: 16),

      // ------------------------------------------------ уже существующие
      SectionLabel(_links.isEmpty ? 'Ссылок пока нет' : 'Ссылки (${_links.length})'),
      const SizedBox(height: 9),
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 230),
        child: _list(p, t),
      ),
      const SizedBox(height: 18),
      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        GradientButton(
          label: 'Закрыть',
          onTap: () => Navigator.of(context).pop(_changed),
        ),
      ]),
    ]);
  }

  Widget _list(NxPalette p, NxThemeData t) {
    if (_loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 26),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: t.accent.a2),
          ),
        ),
      );
    }

    final error = _error;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Text(error,
            textAlign: TextAlign.center,
            style: NxType.bodyText.copyWith(color: NxPalette.danger, fontSize: 12.5)),
      );
    }

    if (_links.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Text(
          'Пока эту запись по ссылке никто открыть не может. '
          'Создайте ссылку выше — и её можно будет отправить кому угодно.',
          style: NxType.bodyText.copyWith(color: p.sub, fontSize: 12.5),
        ),
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      itemCount: _links.length,
      separatorBuilder: (_, _) => const SizedBox(height: 5),
      itemBuilder: (context, i) => _LinkRow(
        link: _links[i],
        onCopy: () => _copy(_links[i]),
        onOpen: () => launchUrl(Uri.parse(_links[i].url),
            mode: LaunchMode.externalApplication),
        onDelete: () => _delete(_links[i]),
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({
    required this.link,
    required this.onCopy,
    required this.onOpen,
    required this.onDelete,
  });

  final PublicLink link;
  final VoidCallback onCopy;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final p = NxTheme.of(context).palette;

    // Подпись под адресом собирается из того, чем ссылка отличается от
    // самой простой: пароль, срок, право загружать.
    final marks = <String>[
      if (link.hasPassword) 'с паролем',
      if (link.canUpload) 'можно загружать',
      if (link.expiresAt != null)
        link.expired
            ? 'срок вышел ${formatDate(link.expiresAt)}'
            : 'до ${formatDate(link.expiresAt)}',
    ];

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 9, 9, 9),
      decoration: BoxDecoration(
        color: p.field,
        borderRadius: BorderRadius.circular(NxRadius.tile),
        border: Border.all(color: link.expired ? NxPalette.warn : p.stroke),
      ),
      child: Row(children: [
        Icon(link.hasPassword ? Icons.lock_rounded : Icons.link_rounded,
            size: 16, color: link.expired ? NxPalette.warn : p.sub),
        const SizedBox(width: 11),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(link.label ?? link.url,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: NxType.numeric.copyWith(color: p.txt, fontSize: 11.5)),
            if (marks.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(marks.join(' · '),
                  style: NxType.caption.copyWith(color: p.faint, fontSize: 10)),
            ],
          ]),
        ),
        const SizedBox(width: 10),
        _Icon(icon: Icons.copy_rounded, tip: 'Скопировать', onTap: onCopy),
        _Icon(icon: Icons.open_in_new_rounded, tip: 'Открыть', onTap: onOpen),
        _Icon(
          icon: Icons.delete_outline_rounded,
          tip: 'Убрать ссылку',
          onTap: onDelete,
          danger: true,
        ),
      ]),
    );
  }
}

class _Icon extends StatelessWidget {
  const _Icon({
    required this.icon,
    required this.tip,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String tip;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final p = NxTheme.of(context).palette;
    return Tooltip(
      message: tip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Icon(icon, size: 15, color: danger ? NxPalette.danger : p.sub),
          ),
        ),
      ),
    );
  }
}
