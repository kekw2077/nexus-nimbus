import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/format.dart';
import '../../core/models/remote_file.dart';
import '../../services/thumbnail_cache.dart';
import '../../services/transfer_queue.dart';
import '../theme.dart';
import '../tokens.dart';
import 'controls.dart';
import 'presence_badge.dart';

/// Миниатюра с сервера, если она есть, иначе — иконка по расширению.
/// Уже загруженные превью отдаются синхронно, чтобы прокрутка не мигала.
class FileThumbnail extends StatefulWidget {
  const FileThumbnail({
    super.key,
    required this.file,
    required this.cache,
    required this.size,
    this.radius = 6,
  });

  final RemoteFile file;
  final ThumbnailCache cache;
  final double size;
  final double radius;

  @override
  State<FileThumbnail> createState() => _FileThumbnailState();
}

class _FileThumbnailState extends State<FileThumbnail> {
  Uint8List? _bytes;
  bool _requested = false;

  int get _pixels => (widget.size * 2).round().clamp(64, 512);

  bool get _eligible =>
      !widget.file.isDir &&
      widget.file.fileId != null &&
      (widget.file.hasPreview || wantsThumbnail(widget.file.extension));

  @override
  void initState() {
    super.initState();
    _prime();
  }

  @override
  void didUpdateWidget(FileThumbnail old) {
    super.didUpdateWidget(old);
    if (old.file.fileId != widget.file.fileId) {
      _bytes = null;
      _requested = false;
      _prime();
    }
  }

  void _prime() {
    if (!_eligible) return;
    final id = widget.file.fileId!;
    final ready = widget.cache.peek(id, _pixels);
    if (ready != null) {
      _bytes = ready;
      _requested = true;
      return;
    }
    if (widget.cache.knownMissing(id, _pixels)) {
      _requested = true;
      return;
    }
    _requested = true;
    widget.cache.get(id, size: _pixels).then((bytes) {
      if (mounted && bytes != null) setState(() => _bytes = bytes);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    if (!_requested) _prime();

    final bytes = _bytes;
    if (bytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: Image.memory(
          bytes,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, _, _) => _icon(p, t),
        ),
      );
    }
    return _icon(p, t);
  }

  Widget _icon(NxPalette p, NxThemeData t) {
    final isDir = widget.file.isDir;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Icon(
        iconFor(isDir: isDir, extension: widget.file.extension, mime: widget.file.mimeType),
        size: widget.size * (isDir ? 0.86 : 0.76),
        color: isDir ? t.accent.a2 : p.sub,
      ),
    );
  }
}

/// Строка списка. Пишется руками, а не через ListTile: нужны своя высота,
/// свой ховер и колонки, выровненные по общей сетке заголовка.
class FileRow extends StatefulWidget {
  const FileRow({
    super.key,
    required this.file,
    required this.presence,
    required this.selected,
    required this.cache,
    required this.onTap,
    required this.onDoubleTap,
    required this.onSecondaryTap,
    required this.onTogglePin,
    this.dropHighlight = false,
    this.transfer,
  });

  final RemoteFile file;
  final Presence presence;
  final bool selected;
  final ThumbnailCache cache;
  final void Function(bool ctrl, bool shift) onTap;
  final VoidCallback onDoubleTap;
  final void Function(Offset globalPosition) onSecondaryTap;
  final VoidCallback onTogglePin;

  /// Подсветка, когда на строку-папку тащат файлы.
  final bool dropHighlight;

  /// Передача по этому файлу, пока она идёт. На время передачи колонки
  /// размера и даты уступают место скорости и оценке остатка — цифры и так
  /// стоят справа, а искать их в другом разделе не приходится.
  final TransferTask? transfer;

  static const height = 40.0;

  @override
  State<FileRow> createState() => _FileRowState();
}

class _FileRowState extends State<FileRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    final f = widget.file;

    // Пока идёт передача, две правые колонки показывают её: скорость там,
    // где обычно размер, и остаток там, где дата.
    final task = widget.transfer;
    final speed = task?.bytesPerSecond ?? 0;
    final left = task?.remaining;

    final sizeColumn = task == null
        ? (f.isDir && f.size == 0 ? '—' : formatBytes(f.size))
        : speed > 0
            ? formatSpeed(speed)
            : '${(task.fraction * 100).round()}%';

    final dateColumn = task == null
        ? formatDate(f.modified)
        : left != null && left > Duration.zero
            ? 'осталось ${formatDuration(left)}'
            : task.kind == TransferKind.download
                ? 'скачивание'
                : 'отправка';

    final background = widget.dropHighlight
        ? t.accent.a2.withValues(alpha: 0.22)
        : widget.selected
            ? p.accentSoft
            : _hover
                ? p.hover
                : Colors.transparent;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          final keys = HardwareKeyboard.instance;
          widget.onTap(keys.isControlPressed, keys.isShiftPressed);
        },
        onDoubleTap: widget.onDoubleTap,
        onSecondaryTapUp: (d) => widget.onSecondaryTap(d.globalPosition),
        child: Container(
          height: FileRow.height,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: widget.dropHighlight
                  ? t.accent.a2
                  : widget.selected
                      ? t.accent.a2.withValues(alpha: 0.45)
                      : Colors.transparent,
            ),
          ),
          child: Stack(children: [
            if (task != null)
              Positioned(
                left: 12,
                right: 12,
                bottom: 3,
                child: NxProgressLine(fraction: task.fraction, height: 2),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                FileThumbnail(file: f, cache: widget.cache, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  flex: 5,
                  child: Text(
                    f.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NxType.bodyText.copyWith(
                      color: widget.selected ? p.txt : p.body,
                      fontSize: 13,
                      fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // Звёздочка стоит перед статусом присутствия: это про сам
                // файл, а не про то, где он лежит.
                SizedBox(
                  width: 18,
                  child: f.favorite
                      ? const Icon(Icons.star_rounded, size: 13, color: NxPalette.warn)
                      : const SizedBox.shrink(),
                ),
                // Признак «на это есть ссылка» — сервер отдаёт его правом S.
                SizedBox(
                  width: 18,
                  child: f.isShared
                      ? Icon(Icons.link_rounded, size: 13, color: t.accent.a2)
                      : const SizedBox.shrink(),
                ),
                SizedBox(
                  width: 26,
                  child: Center(child: PresenceBadge(presence: widget.presence, size: 14)),
                ),
                SizedBox(
                  width: 28,
                  child: _hover || widget.presence == Presence.pinned
                      ? _PinButton(pinned: widget.presence == Presence.pinned, onTap: widget.onTogglePin)
                      : const SizedBox.shrink(),
                ),
                SizedBox(
                  width: 92,
                  child: Text(
                    sizeColumn,
                    textAlign: TextAlign.right,
                    style: NxType.numeric.copyWith(
                      color: task == null ? p.sub : t.accent.a1,
                      fontSize: 11,
                    ),
                  ),
                ),
                const SizedBox(width: 18),
                SizedBox(
                  width: 132,
                  child: Text(
                    dateColumn,
                    textAlign: TextAlign.right,
                    style: NxType.numeric.copyWith(color: p.faint, fontSize: 11),
                  ),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _PinButton extends StatelessWidget {
  const _PinButton({required this.pinned, required this.onTap});
  final bool pinned;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    return Tooltip(
      message: pinned ? 'Открепить: файл можно будет вычистить' : 'Держать локально всегда',
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Icon(
            pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
            size: 14,
            color: pinned ? t.accent.a2 : t.palette.faint,
          ),
        ),
      ),
    );
  }
}

/// Плитка для режима сетки.
class FileTile extends StatefulWidget {
  const FileTile({
    super.key,
    required this.file,
    required this.presence,
    required this.selected,
    required this.cache,
    required this.onTap,
    required this.onDoubleTap,
    required this.onSecondaryTap,
    this.dropHighlight = false,
    this.transfer,
  });

  final RemoteFile file;
  final Presence presence;
  final bool selected;
  final ThumbnailCache cache;
  final void Function(bool ctrl, bool shift) onTap;
  final VoidCallback onDoubleTap;
  final void Function(Offset globalPosition) onSecondaryTap;
  final bool dropHighlight;

  /// Передача по этой плитке, пока она идёт.
  final TransferTask? transfer;

  @override
  State<FileTile> createState() => _FileTileState();
}

class _FileTileState extends State<FileTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    final f = widget.file;

    final task = widget.transfer;
    final speed = task?.bytesPerSecond ?? 0;
    // На плитке места на одну строку — берём самое ходовое: скорость,
    // а пока её не замерили — проценты.
    final caption = task == null
        ? (f.isDir ? 'Папка' : formatBytes(f.size))
        : speed > 0
            ? '${(task.fraction * 100).round()}% · ${formatSpeed(speed)}'
            : '${(task.fraction * 100).round()}%';

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          final keys = HardwareKeyboard.instance;
          widget.onTap(keys.isControlPressed, keys.isShiftPressed);
        },
        onDoubleTap: widget.onDoubleTap,
        onSecondaryTapUp: (d) => widget.onSecondaryTap(d.globalPosition),
        child: AnimatedContainer(
          duration: NxMotion.hover,
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: widget.dropHighlight
                ? t.accent.a2.withValues(alpha: 0.22)
                : widget.selected
                    ? p.accentSoft
                    : _hover
                        ? p.hover
                        : Colors.transparent,
            borderRadius: BorderRadius.circular(NxRadius.tile),
            border: Border.all(
              color: widget.dropHighlight
                  ? t.accent.a2
                  : widget.selected
                      ? t.accent.a2.withValues(alpha: 0.45)
                      : Colors.transparent,
            ),
          ),
          child: Column(children: [
            Expanded(
              child: Stack(children: [
                Center(child: FileThumbnail(file: f, cache: widget.cache, size: 78, radius: 9)),
                Positioned(
                  right: 0,
                  top: 0,
                  child: PresenceBadge(presence: widget.presence, size: 14),
                ),
                if (f.favorite)
                  const Positioned(
                    left: 0,
                    top: 0,
                    child: Icon(Icons.star_rounded, size: 14, color: NxPalette.warn),
                  ),
              ]),
            ),
            const SizedBox(height: 8),
            Text(
              f.name,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: NxType.bodyText.copyWith(
                color: widget.selected ? p.txt : p.body,
                fontSize: 12,
                height: 1.3,
              ),
            ),
            if (task != null) ...[
              const SizedBox(height: 5),
              NxProgressLine(fraction: task.fraction, height: 2),
            ],
            const SizedBox(height: 3),
            Text(
              caption,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: NxType.numeric.copyWith(
                color: task == null ? p.faint : t.accent.a1,
                fontSize: 10,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Шапка колонок списка. Клик по заголовку меняет сортировку.
class FileListHeader extends StatelessWidget {
  const FileListHeader({
    super.key,
    required this.sort,
    required this.ascending,
    required this.onSort,
  });

  final SortKey sort;
  final bool ascending;
  final ValueChanged<SortKey> onSort;

  @override
  Widget build(BuildContext context) {
    final p = NxTheme.of(context).palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(children: [
        const SizedBox(width: 36),
        Expanded(flex: 5, child: _head(context, 'Имя', SortKey.name, TextAlign.left)),
        const SizedBox(width: 10),
        const SizedBox(width: 26),
        const SizedBox(width: 28),
        SizedBox(width: 92, child: _head(context, 'Размер', SortKey.size, TextAlign.right)),
        const SizedBox(width: 18),
        SizedBox(width: 132, child: _head(context, 'Изменён', SortKey.modified, TextAlign.right)),
      ]).withDivider(p.stroke),
    );
  }

  Widget _head(BuildContext context, String label, SortKey key, TextAlign align) {
    final p = NxTheme.of(context).palette;
    final on = sort == key;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => onSort(key),
        child: Row(
          mainAxisAlignment:
              align == TextAlign.right ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: [
            Text(label.toUpperCase(),
                style: NxType.section.copyWith(color: on ? p.body : p.faint, fontSize: 10)),
            if (on) ...[
              const SizedBox(width: 4),
              Icon(ascending ? Icons.arrow_drop_up_rounded : Icons.arrow_drop_down_rounded,
                  size: 15, color: p.body),
            ],
          ],
        ),
      ),
    );
  }
}

/// Ключ сортировки в терминах шапки — отдельный от доменного, чтобы
/// виджет не зависел от слоя сессии.
enum SortKey { name, size, modified }

extension on Row {
  Widget withDivider(Color color) => Column(children: [
        this,
        const SizedBox(height: 7),
        Divider(height: 1, thickness: 1, color: color),
      ]);
}
