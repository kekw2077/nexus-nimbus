import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/session.dart';
import '../services/transfer_queue.dart';
import '../ui/theme.dart';
import '../ui/tokens.dart';
import '../ui/widgets/controls.dart';
import '../ui/widgets/glass_panel.dart';

/// Очередь передач: что качается, что заливается, что сломалось.
class TransfersScreen extends StatelessWidget {
  const TransfersScreen({super.key, required this.session});
  final Session session;

  /// Сводка по всей очереди — та же тройка, что и у каждой строки:
  /// сколько сделано, как быстро идёт, сколько осталось ждать.
  String _summary(TransferQueue q) {
    if (q.activeCount == 0) return 'Очередь пуста';

    final parts = <String>[
      'Активных: ${q.activeCount}',
      '${(q.overallFraction * 100).round()}%',
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
    final q = session.transfers;
    final tasks = q.tasks;

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
            NxGhostButton(label: 'Отменить всё', icon: Icons.stop_circle_outlined, onTap: q.cancelAll),
          if (tasks.any((t) => !t.isActive)) ...[
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
            child: tasks.isEmpty
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
                  itemCount: tasks.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 4),
                  itemBuilder: (context, i) =>
                      _TaskRow(task: tasks[i], onCancel: () => q.cancelTask(tasks[i])),
                ),
          ),
        ),
      ]),
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
        TransferState.done =>
          task.kind == TransferKind.download ? 'Скачан' : 'Загружен',
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
      return (
        formatBytes(task.total),
        average > 0 ? 'в среднем ${formatSpeed(average)}' : ''
      );
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
          task.kind == TransferKind.download
              ? Icons.download_rounded
              : Icons.upload_rounded,
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
                Text(statsLeft,
                    style: NxType.numeric.copyWith(color: p.sub, fontSize: 10.5)),
                const Spacer(),
                Text(statsRight,
                    style: NxType.numeric.copyWith(color: p.faint, fontSize: 10.5)),
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
          Tooltip(
            message: 'Отменить',
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: onCancel,
                child: Icon(Icons.close_rounded, size: 15, color: p.sub),
              ),
            ),
          ),
        ],
      ]),
    );
  }
}
