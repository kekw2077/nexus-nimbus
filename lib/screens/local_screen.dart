import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/format.dart';
import '../core/session.dart';
import '../services/vault.dart';
import '../ui/theme.dart';
import '../ui/tokens.dart';
import '../ui/widgets/dialogs.dart';
import '../ui/widgets/glass_panel.dart';
import '../ui/widgets/presence_badge.dart';
import '../core/models/remote_file.dart';

/// Прямой ответ на вопрос «а что у меня вообще лежит на диске».
/// Один список, честные размеры, кнопка «освободить».
class LocalScreen extends StatelessWidget {
  const LocalScreen({super.key, required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    final vault = session.vault;
    final usage = vault.usage();

    final entries = [...vault.entries]
      ..sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return b.size.compareTo(a.size);
      });

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Локальные копии', style: NxType.title.copyWith(color: p.txt)),
              const SizedBox(height: 3),
              Text(
                entries.isEmpty
                    ? 'На этом компьютере пока ничего не хранится'
                    : '${entries.length} ${_plural(entries.length, 'файл', 'файла', 'файлов')} · '
                        '${formatBytes(usage.total)} · закреплено ${formatBytes(usage.pinned)}',
                style: NxType.caption.copyWith(color: p.sub),
              ),
            ]),
          ),
          _Quiet(
            label: 'Открыть папку',
            icon: Icons.folder_open_rounded,
            onTap: () => launchUrl(Uri.file(vault.root.path)),
          ),
          const SizedBox(width: 8),
          _Quiet(
            label: 'Освободить место',
            icon: Icons.cleaning_services_rounded,
            onTap: () => _freeUp(context, vault),
          ),
        ]),
        const SizedBox(height: 14),
        Expanded(
          child: GlassPanel(
            radius: NxRadius.card,
            padding: EdgeInsets.zero,
            child: entries.isEmpty
                ? Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 400),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.cloud_done_rounded, size: 40, color: p.faint),
                        const SizedBox(height: 14),
                        Text('Всё лежит только на сервере',
                            style: NxType.title.copyWith(color: p.txt, fontSize: 16)),
                        const SizedBox(height: 7),
                        Text(
                          'Диск не занят ничем. Файлы появятся здесь, когда вы их '
                          'скачаете или закрепите значком булавки.',
                          textAlign: TextAlign.center,
                          style: NxType.bodyText
                              .copyWith(color: p.sub, fontSize: 12.5, height: 1.5),
                        ),
                      ]),
                    ),
                  )
                : Scrollbar(
                    thickness: 7,
                    radius: const Radius.circular(8),
                    child: ListView.separated(
                      padding: const EdgeInsets.all(10),
                      itemCount: entries.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 3),
                      itemBuilder: (context, i) => _EntryRow(
                        entry: entries[i],
                        session: session,
                      ),
                    ),
                  ),
          ),
        ),
      ]),
    );
  }

  Future<void> _freeUp(BuildContext context, Vault vault) async {
    final usage = vault.usage();
    final freeable = usage.total - usage.pinned;
    if (freeable <= 0) {
      return;
    }
    final ok = await confirm(
      context,
      title: 'Освободить ${formatBytes(freeable)}?',
      message: 'Удалим локальные копии всего, что не закреплено и не содержит '
          'несохранённых правок. На сервере файлы останутся нетронутыми.',
      confirmLabel: 'Освободить',
      danger: false,
    );
    if (!ok) return;
    await vault.evictUnpinned();
  }

  static String _plural(int n, String one, String few, String many) {
    final mod100 = n % 100;
    if (mod100 >= 11 && mod100 <= 14) return many;
    return switch (n % 10) { 1 => one, 2 || 3 || 4 => few, _ => many };
  }
}

class _EntryRow extends StatefulWidget {
  const _EntryRow({required this.entry, required this.session});
  final VaultEntry entry;
  final Session session;

  @override
  State<_EntryRow> createState() => _EntryRowState();
}

class _EntryRowState extends State<_EntryRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    final e = widget.entry;
    final vault = widget.session.vault;

    final presence = vault.isBusy(e.path)
        ? Presence.transferring
        : vault.isDirty(e.path)
            ? Presence.dirty
            : e.pinned
                ? Presence.pinned
                : Presence.cached;

    final name = e.path.split('/').last;
    final folder = e.path.contains('/')
        ? e.path.substring(0, e.path.lastIndexOf('/'))
        : 'Корень';

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: _hover ? p.hover : Colors.transparent,
          borderRadius: BorderRadius.circular(NxRadius.tile),
        ),
        child: Row(children: [
          PresenceBadge(presence: presence, size: 15),
          const SizedBox(width: 13),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NxType.bodyText.copyWith(color: p.txt, fontSize: 12.5)),
              const SizedBox(height: 2),
              Text(folder,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NxType.numeric.copyWith(color: p.faint, fontSize: 10)),
            ]),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 78,
            child: Text(formatBytes(e.size),
                textAlign: TextAlign.right,
                style: NxType.numeric.copyWith(color: p.sub, fontSize: 11)),
          ),
          SizedBox(
            width: 96,
            child: _hover
                ? Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    _Mini(
                      icon: Icons.folder_special_rounded,
                      tooltip: 'Показать в Проводнике',
                      onTap: () async {
                        final f = vault.localFile(e.path);
                        if (await f.exists()) {
                          await Process.start('explorer', ['/select,', f.path]);
                        }
                      },
                    ),
                    _Mini(
                      icon: e.pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                      tooltip: e.pinned ? 'Открепить' : 'Держать локально всегда',
                      active: e.pinned,
                      onTap: () => vault.setPinned(e.path, !e.pinned),
                    ),
                    _Mini(
                      icon: Icons.cloud_off_rounded,
                      tooltip: 'Удалить локальную копию',
                      onTap: () => vault.evict(e.path),
                    ),
                  ])
                : const SizedBox.shrink(),
          ),
        ]),
      ),
    );
  }
}

class _Mini extends StatefulWidget {
  const _Mini({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;

  @override
  State<_Mini> createState() => _MiniState();
}

class _MiniState extends State<_Mini> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 28,
            height: 26,
            alignment: Alignment.center,
            child: Icon(
              widget.icon,
              size: 14,
              color: widget.active ? t.accent.a2 : (_hover ? p.txt : p.sub),
            ),
          ),
        ),
      ),
    );
  }
}

class _Quiet extends StatefulWidget {
  const _Quiet({required this.label, required this.icon, required this.onTap});
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  State<_Quiet> createState() => _QuietState();
}

class _QuietState extends State<_Quiet> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = NxTheme.of(context).palette;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: NxMotion.hover,
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          decoration: BoxDecoration(
            color: _hover ? p.hover : p.field,
            borderRadius: BorderRadius.circular(NxRadius.chip),
            border: Border.all(color: p.stroke),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(widget.icon, size: 14, color: _hover ? p.txt : p.body),
            const SizedBox(width: 7),
            Text(widget.label,
                style: NxType.label.copyWith(color: _hover ? p.txt : p.body, fontSize: 12)),
          ]),
        ),
      ),
    );
  }
}
