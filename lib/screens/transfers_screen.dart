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
              Text(
                q.activeCount == 0
                    ? 'Очередь пуста'
                    : 'Активных: ${q.activeCount} · ${(q.overallFraction * 100).round()}%',
                style: NxType.caption.copyWith(color: p.sub),
              ),
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
                : Scrollbar(
                    thickness: 7,
                    radius: const Radius.circular(8),
                    child: ListView.separated(
                      padding: const EdgeInsets.all(10),
                      itemCount: tasks.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 4),
                      itemBuilder: (context, i) =>
                          _TaskRow(task: tasks[i], onCancel: () => q.cancelTask(tasks[i])),
                    ),
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

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;

    final (icon, color, note) = switch (task.state) {
      TransferState.queued => (Icons.schedule_rounded, p.faint, 'В очереди'),
      TransferState.running => (
          task.kind == TransferKind.download
              ? Icons.download_rounded
              : Icons.upload_rounded,
          t.accent.a1,
          '${formatBytes(task.done)} из ${formatBytes(task.total)}'
        ),
      TransferState.done => (
          Icons.check_circle_rounded,
          NxPalette.ok,
          '${task.kind == TransferKind.download ? 'Скачан' : 'Загружен'} · '
              '${formatBytes(task.total)}'
        ),
      TransferState.failed => (Icons.error_outline_rounded, NxPalette.danger, task.error ?? 'Ошибка'),
      TransferState.cancelled => (Icons.cancel_outlined, p.faint, 'Отменено'),
    };

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
              Text(note,
                  style: NxType.numeric.copyWith(
                      color: task.state == TransferState.failed ? NxPalette.danger : p.sub,
                      fontSize: 10.5)),
            ]),
            if (task.isActive) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  height: 4,
                  child: Stack(children: [
                    ColoredBox(color: p.chip, child: const SizedBox.expand()),
                    FractionallySizedBox(
                      widthFactor: task.fraction,
                      child: DecoratedBox(decoration: BoxDecoration(gradient: t.accent.badge)),
                    ),
                  ]),
                ),
              ),
            ] else ...[
              const SizedBox(height: 4),
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

