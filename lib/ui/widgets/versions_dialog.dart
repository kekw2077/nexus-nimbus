import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/models/file_version.dart';
import '../../core/models/remote_file.dart';
import '../../core/session.dart';
import '../theme.dart';
import '../tokens.dart';
import 'controls.dart';
import 'dialogs.dart';
import 'glass_panel.dart';

/// История версий одного файла. Возвращает true, если что-то восстановили —
/// тогда список файлов надо перечитать.
Future<bool> showVersions(
  BuildContext context, {
  required Session session,
  required RemoteFile file,
}) async {
  final t = NxTheme.of(context);
  final restored = await showDialog<bool>(
    context: context,
    barrierColor: const Color(0x99000000),
    builder: (ctx) => NxTheme(
      data: t,
      onChanged: (_) {},
      child: Center(
        child: SizedBox(
          width: 520,
          child: GlassPanel(
            radius: NxRadius.card,
            padding: const EdgeInsets.all(22),
            shadow: true,
            color: t.palette.solid,
            child: _VersionsBody(session: session, file: file),
          ),
        ),
      ),
    ),
  );
  return restored ?? false;
}

class _VersionsBody extends StatefulWidget {
  const _VersionsBody({required this.session, required this.file});
  final Session session;
  final RemoteFile file;

  @override
  State<_VersionsBody> createState() => _VersionsBodyState();
}

class _VersionsBodyState extends State<_VersionsBody> {
  List<FileVersion> _versions = const [];
  bool _loading = true;
  String? _error;
  bool _restored = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = widget.file.fileId;
    if (id == null) {
      setState(() {
        _loading = false;
        _error = 'Сервер не сказал идентификатор файла — по нему и ищутся версии.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.session.dav.listVersions(id);
      if (!mounted) return;
      setState(() {
        _versions = list;
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

  Future<void> _restore(FileVersion version) async {
    final id = widget.file.fileId;
    if (id == null) return;

    final ok = await confirm(
      context,
      title: 'Вернуть версию от ${formatDate(version.when)}?',
      message: 'Нынешнее содержимое файла не пропадёт: сервер сохранит его '
          'очередной версией, и вернуться обратно можно будет отсюда же.',
      confirmLabel: 'Вернуть',
      danger: false,
    );
    if (!ok || !mounted) return;

    try {
      await widget.session.dav.restoreVersion(id, version.id);
      _restored = true;
      // Локальная копия устарела — пусть её перекачают заново.
      await widget.session.vault.evict(widget.file.path);
      if (!mounted) return;
      await _load();
    } catch (e) {
      if (!mounted) return;
      showNxToast(context, e.toString(), danger: true);
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
            Text('Версии файла', style: NxType.title.copyWith(color: p.txt, fontSize: 17)),
            const SizedBox(height: 3),
            Text(widget.file.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: NxType.caption.copyWith(color: p.sub)),
          ]),
        ),
        NxGhostButton(label: 'Обновить', icon: Icons.refresh_rounded, onTap: _load),
      ]),
      const SizedBox(height: 16),
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 340),
        child: _list(p, t),
      ),
      const SizedBox(height: 18),
      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        GradientButton(
          label: 'Закрыть',
          onTap: () => Navigator.of(context).pop(_restored),
        ),
      ]),
    ]);
  }

  Widget _list(NxPalette p, NxThemeData t) {
    if (_loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
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
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(children: [
          const Icon(Icons.error_outline_rounded, size: 32, color: NxPalette.danger),
          const SizedBox(height: 12),
          Text(error,
              textAlign: TextAlign.center,
              style: NxType.bodyText.copyWith(color: p.sub, fontSize: 12.5)),
        ]),
      );
    }

    if (_versions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 30),
        child: Column(children: [
          Icon(Icons.history_rounded, size: 34, color: p.faint),
          const SizedBox(height: 12),
          Text('Прежних версий нет',
              style: NxType.title.copyWith(color: p.txt, fontSize: 15)),
          const SizedBox(height: 6),
          Text('Сервер снимает версию при каждой перезаписи файла. '
              'Этот файл пока переписывали не больше раза.',
              textAlign: TextAlign.center,
              style: NxType.bodyText.copyWith(color: p.sub, fontSize: 12.5)),
        ]),
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      itemCount: _versions.length,
      separatorBuilder: (_, _) => const SizedBox(height: 5),
      itemBuilder: (context, i) {
        final v = _versions[i];
        return Container(
          padding: const EdgeInsets.fromLTRB(12, 9, 9, 9),
          decoration: BoxDecoration(
            color: p.field,
            borderRadius: BorderRadius.circular(NxRadius.tile),
            border: Border.all(color: p.stroke),
          ),
          child: Row(children: [
            Icon(Icons.history_rounded, size: 16, color: p.sub),
            const SizedBox(width: 11),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(v.label ?? formatDate(v.when),
                    style: NxType.bodyText.copyWith(color: p.txt, fontSize: 12.5)),
                if (v.label != null) ...[
                  const SizedBox(height: 2),
                  Text(formatDate(v.when),
                      style: NxType.numeric.copyWith(color: p.faint, fontSize: 10)),
                ],
              ]),
            ),
            const SizedBox(width: 10),
            Text(formatBytes(v.size),
                style: NxType.numeric.copyWith(color: p.sub, fontSize: 11)),
            const SizedBox(width: 14),
            NxGhostButton(
              label: 'Вернуть',
              icon: Icons.restore_rounded,
              onTap: () => _restore(v),
            ),
          ]),
        );
      },
    );
  }
}
