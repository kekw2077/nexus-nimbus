import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../services/updater.dart';
import '../theme.dart';
import '../tokens.dart';
import 'controls.dart';
import 'glass_panel.dart';

/// Предложение обновиться — в оформлении приложения, а не в окне WinSparkle.
///
/// Само скачивание и сверку подписи после согласия делает всё тот же
/// WinSparkle: здесь только вопрос и список изменений.
Future<void> showUpdate(
  BuildContext context, {
  required UpdaterService updater,
  required ReleaseEntry release,
}) {
  final t = NxTheme.of(context);
  return showDialog<void>(
    context: context,
    barrierColor: const Color(0x99000000),
    builder: (ctx) => NxTheme(
      data: t,
      onChanged: (_) {},
      child: Center(
        child: SizedBox(
          width: 440,
          child: GlassPanel(
            radius: NxRadius.card,
            padding: const EdgeInsets.all(22),
            shadow: true,
            color: t.palette.solid,
            child: _UpdateBody(updater: updater, release: release),
          ),
        ),
      ),
    ),
  );
}

class _UpdateBody extends StatelessWidget {
  const _UpdateBody({required this.updater, required this.release});
  final UpdaterService updater;
  final ReleaseEntry release;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;

    final marks = <String>[
      if (release.publishedAt != null) formatDate(release.publishedAt),
      if (release.size > 0) formatBytes(release.size),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              gradient: t.accent.badge,
              borderRadius: BorderRadius.circular(11),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.system_update_alt_rounded,
                size: 19, color: Colors.white),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Есть версия ${release.version}',
                  style: NxType.title.copyWith(color: p.txt, fontSize: 16.5)),
              const SizedBox(height: 3),
              Text(
                marks.isEmpty
                    ? 'Сейчас установлена ${updater.currentVersion}'
                    : '${marks.join(' · ')} · сейчас ${updater.currentVersion}',
                style: NxType.caption.copyWith(color: p.sub),
              ),
            ]),
          ),
        ]),
        if (release.notes.isNotEmpty) ...[
          const SizedBox(height: 16),
          SectionLabel('Что изменилось'),
          const SizedBox(height: 9),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                for (final note in release.notes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 7),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Container(
                            width: 4,
                            height: 4,
                            decoration: BoxDecoration(
                              color: t.accent.a2,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(note,
                              style: NxType.bodyText.copyWith(
                                  color: p.body, fontSize: 12.5, height: 1.45)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 14),
        Text(
          'Приложение закроется, поставит обновление и откроется снова. '
          'Настройки, вход и скачанные файлы останутся на месте.',
          style: NxType.caption.copyWith(color: p.faint, height: 1.45),
        ),
        const SizedBox(height: 18),
        Row(children: [
          NxGhostButton(
            label: 'Пропустить эту версию',
            onTap: () {
              Navigator.of(context).pop();
              updater.skip(release.version);
            },
          ),
          const Spacer(),
          NxGhostButton(
            label: 'Позже',
            onTap: () {
              Navigator.of(context).pop();
              updater.forgetFound();
            },
          ),
          const SizedBox(width: 10),
          GradientButton(
            label: 'Обновить',
            icon: Icons.download_rounded,
            onTap: () {
              Navigator.of(context).pop();
              updater.install();
            },
          ),
        ]),
      ],
    );
  }
}
