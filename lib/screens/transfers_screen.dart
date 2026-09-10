import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/session.dart';
import '../services/transfer_queue.dart';
import '../ui/theme.dart';
import '../ui/tokens.dart';
import '../ui/widgets/controls.dart';
import '../ui/widgets/glass_panel.dart';

/// Очередь передач: что качается, что заливается, что сломалось.
///
/// Папка показывается **одной строкой** на всё дерево. Заливка проекта —
/// это десятки тысяч файлов, и списком по файлу экран превращается в
/// ленту, которая улетает вниз быстрее, чем её можно прочесть: найти в
/// ней вторую передачу уже нельзя. Отдельные файлы внутри пачки есть кому
/// показать — раскрыть строку и увидеть то, что идёт прямо сейчас, и то,
/// что не получилось.
class TransfersScreen extends StatefulWidget {
  const TransfersScreen({super.key, required this.session});
  final Session session;

  @override
  State<TransfersScreen> createState() => _TransfersScreenState();
}

class _TransfersScreenState extends State<TransfersScreen> {
  final _expanded = <int>{};

  /// Сводка по всей очереди — та же тройка, что и у каждой строки:
  /// сколько сделано, как быстро идёт, сколько осталось ждать.
  String _summary(TransferQueue q) {
    if (q.activeCount == 0) return 'Очередь пуста';

    final parts = <String>[
      // Пока идёт обход дерева, процент считать не из чего: знаменатель
      // растёт вместе с числителем, и на экране висел бы ноль.
      if (q.scanning) 'считаем файлы…' else '${(q.overallFraction * 100).round()}%',
      if (q.filesTotal > 0)
        '${formatCount(q.filesDone)} из ${formatCount(q.filesTotal)} '
            '${plural(q.filesTotal, 'файла', 'файлов', 'файлов')}',
    ];

    final speed = q.bytesPerSecond;
    if (speed > 0) parts.add(formatSpeed(speed));

    final left = q.remaining;
    if (left != null && left > Duration.zero) {
      parts.add('осталось ${formatDuration(left)}');
    }
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    final q = widget.session.transfers;

    // Пачки сверху, поимённые задачи под ними: пачка — это то, что
    // человек просил, а одиночная задача чаще всего её же обломок.
    final batches = q.batches;
    final tasks = q.tasks;
    final rows = batches.length + tasks.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              GradientText('Передачи', style: NxType.title),
              const SizedBox(height: 3),
              Text(_summary(q), style: NxType.caption.copyWith(color: p.sub)),
            ]),
          ),
          if (q.activeCount > 0)
            NxGhostButton(
                label: 'Отменить всё', icon: Icons.stop_circle_outlined, onTap: q.cancelAll),
          if (q.hasFinished) ...[
            const SizedBox(width: 8),
            NxGhostButton(
                label: 'Очистить список',
                icon: Icons.playlist_remove_rounded,
                onTap: q.clearFinished),
          ],
        ]),
        const SizedBox(height: 14),
        Expanded(
          child: GlassPanel(
            radius: NxRadius.panel,
            padding: EdgeInsets.zero,
            child: rows == 0
                ? Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.swap_vert_rounded, size: 40, color: p.faint),
                      const SizedBox(height: 14),
                      Text('Пока ничего не передаётся',
                          style: NxType.title.copyWith(color: p.txt, fontSize: 16)),
                      const SizedBox(height: 7),
                      Text('Скачанное и загруженное появится здесь вместе с прогрессом.',
                          style: NxType.bodyText.copyWith(color: p.sub, fontSize: 12.5)),
                    ]),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(10),
                    itemCount: rows,
                    separatorBuilder: (_, _) => const SizedBox(height: 4),
                    itemBuilder: (context, i) {
                      if (i < batches.length) {
                        final batch = batches[i];
                        return _BatchRow(
                          batch: batch,
                          expanded: _expanded.contains(batch.id),
                          onToggle: () => setState(() {
                            if (!_expanded.remove(batch.id)) _expanded.add(batch.id);
                          }),
                          onCancel: () => q.cancelBatch(batch),
                        );
                      }
                      final task = tasks[i - batches.length];
                      return _TaskRow(task: task, onCancel: () => q.cancelTask(task));
                    },
                  ),
          ),
        ),
      ]),
    );
  }
}

/// Строка пачки: папка или горсть файлов целиком.
class _BatchRow extends StatelessWidget {
  const _BatchRow({
    required this.batch,
    required this.expanded,
    required this.onToggle,
    required this.onCancel,
  });

  final TransferBatch batch;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onCancel;

  String get _headline => switch (batch.state) {
        TransferState.queued => 'В очереди',
        TransferState.running =>
          batch.scanning ? 'считаем…' : '${(batch.fraction * 100).round()}%',
        TransferState.done => batch.kind == TransferKind.download ? 'Скачано' : 'Загружено',
        TransferState.failed =>
          '${formatCount(batch.filesFailed)} не ${plural(batch.filesFailed, 'удался', 'удались', 'удались')}',
        TransferState.cancelled => 'Отменено',
      };

  /// Нижняя строка. Слева — счёт файлов: при заливке папки это главное,
  /// проценты по байтам мало что говорят, когда файлы разного размера.
  (String, String) get _stats {
    final left = <String>[];
    if (batch.scanning) {
      left.add('найдено ${formatCount(batch.files)} '
          '${plural(batch.files, 'файл', 'файла', 'файлов')}');
    } else {
      left.add('${formatCount(batch.filesDone)} из ${formatCount(batch.files)} '
          '${plural(batch.files, 'файла', 'файлов', 'файлов')}');
    }
    if (batch.bytesTotal > 0) {
      left.add(batch.isActive
          ? '${formatBytes(batch.bytesDone)} из ${formatBytes(batch.bytesTotal)}'
          : formatBytes(batch.bytesTotal));
    }

    if (!batch.isActive) {
      final skipped = batch.filesFailed + batch.filesCancelled;
      return (left.join(' · '), skipped > 0 ? 'пропущено ${formatCount(skipped)}' : '');
    }

    final right = <String>[];
    final speed = batch.bytesPerSecond;
    if (speed > 0) right.add(formatSpeed(speed));
    final remaining = batch.remaining;
    if (remaining != null && remaining > Duration.zero) {
      right.add('осталось ${formatDuration(remaining)}');
    }
    return (
      left.join(' · '),
      right.isEmpty ? (batch.scanning ? 'обходим папку…' : 'считаем скорость…') : right.join(' · ')
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;

    final (icon, color) = switch (batch.state) {
      TransferState.queued => (Icons.schedule_rounded, p.faint),
      TransferState.running => (
          batch.kind == TransferKind.download ? Icons.download_rounded : Icons.upload_rounded,
          t.accent.a1
        ),
      TransferState.done => (Icons.check_circle_rounded, NxPalette.ok),
      TransferState.failed => (Icons.error_outline_rounded, NxPalette.danger),
      TransferState.cancelled => (Icons.cancel_outlined, p.faint),
    };

    final (statsLeft, statsRight) = _stats;
    final failed = batch.state == TransferState.failed;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: p.field,
        borderRadius: BorderRadius.circular(NxRadius.tile),
        border: Border.all(color: p.stroke),
      ),
      child: Column(children: [
        Row(children: [
          Icon(icon, size: 17, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(
                  batch.isFolder ? Icons.folder_rounded : Icons.file_copy_rounded,
                  size: 13,
                  color: p.faint,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    batch.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NxType.bodyText.copyWith(color: p.txt, fontSize: 12.5),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  _headline,
                  style: NxType.numeric.copyWith(
                    color: failed ? NxPalette.danger : p.sub,
                    fontSize: 10.5,
                  ),
                ),
              ]),
              if (batch.isActive) ...[
                const SizedBox(height: 8),
                // Пока идёт обход, доля по байтам не значит ничего: полоса
                // ползла бы назад с каждой новой тысячей найденных файлов.
                NxProgressLine(fraction: batch.scanning ? 0 : batch.fraction),
              ],
              const SizedBox(height: 6),
              Row(children: [
                Flexible(
                  child: Text(
                    statsLeft,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NxType.numeric.copyWith(color: p.sub, fontSize: 10.5),
                  ),
                ),
                const Spacer(),
                Text(statsRight, style: NxType.numeric.copyWith(color: p.faint, fontSize: 10.5)),
              ]),
              if (batch.remoteRoot != null && !batch.isActive) ...[
                const SizedBox(height: 3),
                Text(
                  batch.remoteRoot!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NxType.numeric.copyWith(color: p.faint, fontSize: 10),
                ),
              ],
            ]),
          ),
          const SizedBox(width: 10),
          _IconTap(
            icon: expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
            tooltip: expanded ? 'Свернуть' : 'Что внутри',
            onTap: onToggle,
          ),
          if (batch.isActive) ...[
            const SizedBox(width: 4),
            _IconTap(icon: Icons.close_rounded, tooltip: 'Отменить всё в пачке', onTap: onCancel),
          ],
        ]),
        if (expanded) _BatchDetails(batch: batch),
      ]),
    );
  }
}

/// Раскрытая пачка. Показываем не всё её содержимое, а только то, что
/// имеет смысл читать: что идёт прямо сейчас и что не получилось.
/// Полный список — это те самые пятьдесят тысяч строк.
class _BatchDetails extends StatelessWidget {
  const _BatchDetails({required this.batch});

  final TransferBatch batch;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;

    final live = batch.live.toList();
    final failures = batch.failures;

    Widget caption(String text) => Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 5),
          child: Text(text, style: NxType.section.copyWith(color: p.faint)),
        );

    Widget line(String name, String note, Color noteColor) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: NxType.numeric.copyWith(color: p.sub, fontSize: 10.5),
              ),
            ),
            const SizedBox(width: 10),
            Text(note, style: NxType.numeric.copyWith(color: noteColor, fontSize: 10.5)),
          ]),
        );

    return Padding(
      padding: const EdgeInsets.only(left: 29, right: 4, bottom: 2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(height: 1, color: p.stroke, margin: const EdgeInsets.only(top: 8)),
        if (live.isNotEmpty) ...[
          caption('ИДЁТ СЕЙЧАС'),
          for (final task in live)
            line(task.name, '${(task.fraction * 100).round()}%', t.accent.a1),
        ],
        if (failures.isNotEmpty) ...[
          caption('НЕ ПОЛУЧИЛОСЬ'),
          for (final task in failures) line(task.name, 'ошибка', NxPalette.danger),
          if (batch.filesFailed > failures.length)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'и ещё ${formatCount(batch.filesFailed - failures.length)} — '
                'причина, скорее всего, та же',
                style: NxType.numeric.copyWith(color: p.faint, fontSize: 10),
              ),
            ),
          if (failures.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                failures.first.error ?? '',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: NxType.numeric.copyWith(color: NxPalette.danger, fontSize: 10),
              ),
            ),
        ],
        if (live.isEmpty && failures.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              batch.isActive ? 'Ждём очереди…' : 'Всё прошло без ошибок.',
              style: NxType.numeric.copyWith(color: p.faint, fontSize: 10.5),
            ),
          ),
      ]),
    );
  }
}

class _IconTap extends StatelessWidget {
  const _IconTap({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = NxTheme.of(context).palette;
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Icon(icon, size: 15, color: p.sub),
        ),
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.task, required this.onCancel});
  final TransferTask task;
  final VoidCallback onCancel;

  /// Правая подпись в первой строке: у идущей передачи — проценты,
  /// у остальных — чем всё кончилось.
  String get _headline => switch (task.state) {
        TransferState.queued => 'В очереди',
        TransferState.running => '${(task.fraction * 100).round()}%',
        TransferState.done => task.kind == TransferKind.download ? 'Скачан' : 'Загружен',
        TransferState.failed => task.error ?? 'Ошибка',
        TransferState.cancelled => 'Отменено',
      };

  /// Нижняя строка: слева объём, справа скорость и оценка остатка.
  /// У законченного объём и средняя скорость — по ним видно, во что
  /// обошлась передача.
  (String, String) get _stats {
    if (task.state == TransferState.running) {
      final size = task.total > 0
          ? '${formatBytes(task.done)} из ${formatBytes(task.total)}'
          : formatBytes(task.done);

      final right = <String>[];
      final speed = task.bytesPerSecond;
      if (speed > 0) right.add(formatSpeed(speed));
      final left = task.remaining;
      if (left != null && left > Duration.zero) {
        right.add('осталось ${formatDuration(left)}');
      }
      // Скорости ещё нет — первые полсекунды замерять нечего.
      return (size, right.isEmpty ? 'считаем скорость…' : right.join(' · '));
    }

    if (task.state == TransferState.done) {
      final average = task.averageSpeed;
      return (formatBytes(task.total), average > 0 ? 'в среднем ${formatSpeed(average)}' : '');
    }
    return (task.total > 0 ? formatBytes(task.total) : '', '');
  }

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;

    final (icon, color) = switch (task.state) {
      TransferState.queued => (Icons.schedule_rounded, p.faint),
      TransferState.running => (
          task.kind == TransferKind.download ? Icons.download_rounded : Icons.upload_rounded,
          t.accent.a1
        ),
      TransferState.done => (Icons.check_circle_rounded, NxPalette.ok),
      TransferState.failed => (Icons.error_outline_rounded, NxPalette.danger),
      TransferState.cancelled => (Icons.cancel_outlined, p.faint),
    };

    final failed = task.state == TransferState.failed;
    final (statsLeft, statsRight) = _stats;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: p.field,
        borderRadius: BorderRadius.circular(NxRadius.tile),
        border: Border.all(color: p.stroke),
      ),
      child: Row(children: [
        Icon(icon, size: 17, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(
                  task.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NxType.bodyText.copyWith(color: p.txt, fontSize: 12.5),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                _headline,
                style: NxType.numeric.copyWith(
                  color: failed ? NxPalette.danger : p.sub,
                  fontSize: 10.5,
                ),
              ),
            ]),
            if (task.isActive) ...[
              const SizedBox(height: 8),
              NxProgressLine(fraction: task.fraction),
            ],
            if (statsLeft.isNotEmpty || statsRight.isNotEmpty) ...[
              const SizedBox(height: 6),
              Row(children: [
                Text(statsLeft, style: NxType.numeric.copyWith(color: p.sub, fontSize: 10.5)),
                const Spacer(),
                Text(statsRight, style: NxType.numeric.copyWith(color: p.faint, fontSize: 10.5)),
              ]),
            ],
            if (!task.isActive) ...[
              const SizedBox(height: 3),
              Text(
                task.remotePath,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: NxType.numeric.copyWith(color: p.faint, fontSize: 10),
              ),
            ],
          ]),
        ),
        if (task.isActive) ...[
          const SizedBox(width: 10),
          _IconTap(icon: Icons.close_rounded, tooltip: 'Отменить', onTap: onCancel),
        ],
      ]),
    );
  }
}
