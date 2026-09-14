import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../services/updater.dart';
import '../theme.dart';
import '../tokens.dart';
import 'controls.dart';
import 'dialogs.dart';
import 'glass_panel.dart';

/// Предложение обновиться — и всё, что за ним: скачивание с полосой,
/// проверка подписи, запуск установщика. Одно окно в оформлении
/// приложения; чужих окон в этой цепочке больше нет.
Future<void> showUpdate(
  BuildContext context, {
  required UpdaterService updater,
  required ReleaseEntry release,
}) {
  final t = NxTheme.of(context);
  return showDialog<void>(
    context: context,
    // Щелчок мимо окна посреди скачивания оставил бы загрузку без окна.
    // Закрыть его можно кнопками — «Позже» или «Отмена».
    barrierDismissible: false,
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

class _UpdateBody extends StatefulWidget {
  const _UpdateBody({required this.updater, required this.release});
  final UpdaterService updater;
  final ReleaseEntry release;

  @override
  State<_UpdateBody> createState() => _UpdateBodyState();
}

class _UpdateBodyState extends State<_UpdateBody> {
  UpdaterService get updater => widget.updater;
  ReleaseEntry get release => widget.release;

  /// Нажали «Обновить». С этого момента окно показывает ход установки,
  /// а не предложение — даже если сервис уже успел сообщить об ошибке.
  bool _started = false;

  @override
  void initState() {
    super.initState();
    updater.addListener(_onUpdater);
  }

  @override
  void dispose() {
    updater.removeListener(_onUpdater);
    super.dispose();
  }

  void _onUpdater() {
    if (mounted) setState(() {});
  }

  Future<void> _start() async {
    // Спрашиваем ещё раз перед самой установкой. Дальше программа
    // закроется без предупреждения — а закрыть её посреди правки
    // файла обиднее, чем лишний раз нажать кнопку.
    final ok = await confirm(
      context,
      title: 'Обновить сейчас?',
      message: 'Программа скачает установщик, проверит его подпись, закроется '
          'и через несколько секунд откроется заново уже новой версии. '
          'Если что-то открыто на правку — сохраните перед обновлением.',
      confirmLabel: 'Обновить и перезапустить',
      danger: false,
    );
    if (!ok || !mounted) return;
    setState(() => _started = true);
    await updater.install(release);
  }

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(updater: updater, release: release),
        if (!_started) ...[
          if (release.notes.isNotEmpty) ...[
            const SizedBox(height: 16),
            SectionLabel('Что изменилось'),
            const SizedBox(height: 9),
            _Notes(notes: release.notes),
          ],
          const SizedBox(height: 14),
          Text(
            'Приложение закроется, поставит обновление и откроется снова. '
            'Настройки, вход и скачанные файлы останутся на месте.',
            style: NxType.caption.copyWith(color: p.faint, height: 1.45),
          ),
          const SizedBox(height: 18),
          _offerButtons(context),
        ] else ...[
          const SizedBox(height: 18),
          _Progress(updater: updater),
          const SizedBox(height: 18),
          _progressButtons(context),
        ],
      ],
    );
  }

  Widget _offerButtons(BuildContext context) {
    return Row(children: [
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
        onTap: _start,
      ),
    ]);
  }

  Widget _progressButtons(BuildContext context) {
    switch (updater.status) {
      case UpdateStatus.downloading:
        return Row(children: [
          const Spacer(),
          NxGhostButton(
            label: 'Отмена',
            onTap: () {
              updater.cancelInstall();
              Navigator.of(context).pop();
            },
          ),
        ]);
      case UpdateStatus.failed:
        return Row(children: [
          const Spacer(),
          NxGhostButton(
            label: 'Закрыть',
            onTap: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 10),
          GradientButton(
            label: 'Попробовать ещё раз',
            icon: Icons.refresh_rounded,
            onTap: () => updater.install(release),
          ),
        ]);
      // Проверка и запуск — секунды, отменять там уже нечего.
      default:
        return const SizedBox(height: 4);
    }
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.updater, required this.release});
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

    return Row(children: [
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
    ]);
  }
}

class _Notes extends StatelessWidget {
  const _Notes({required this.notes});
  final List<String> notes;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: ListView(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        children: [
          for (final note in notes)
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
    );
  }
}

/// Ход установки: полоса, сколько скачано, что происходит сейчас.
/// При ошибке — её текст вместо полосы, и он же объясняет, почему
/// установщик не запустился.
class _Progress extends StatelessWidget {
  const _Progress({required this.updater});
  final UpdaterService updater;

  @override
  Widget build(BuildContext context) {
    final p = NxTheme.of(context).palette;
    final status = updater.status;

    if (status == UpdateStatus.failed) {
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Padding(
          padding: EdgeInsets.only(top: 1),
          child: Icon(Icons.error_outline_rounded, size: 16, color: NxPalette.danger),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            updater.message ?? 'Не удалось установить обновление.',
            style: NxType.bodyText.copyWith(
                color: p.body, fontSize: 12.5, height: 1.45),
          ),
        ),
      ]);
    }

    final fraction = updater.progress;
    final downloading = status == UpdateStatus.downloading;
    // Проверка и запуск — полоса полная: скачивание позади.
    final shown = downloading ? (fraction ?? 0) : 1.0;

    final String amount;
    if (!downloading) {
      amount = formatBytes(updater.received);
    } else if (updater.total > 0) {
      amount = '${formatBytes(updater.received)} из ${formatBytes(updater.total)}';
    } else {
      amount = formatBytes(updater.received);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      NxProgressLine(fraction: shown, height: 6),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(
          child: Text(
            updater.message ?? '',
            style: NxType.bodyText.copyWith(color: p.body, fontSize: 12.5),
          ),
        ),
        Text(amount, style: NxType.caption.copyWith(color: p.sub)),
      ]),
    ]);
  }
}
