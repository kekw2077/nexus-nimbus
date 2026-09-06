import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/models/remote_file.dart';
import '../core/session.dart';
import '../ui/theme.dart';
import '../ui/tokens.dart';
import '../ui/widgets/controls.dart';
import '../ui/widgets/file_views.dart';
import '../ui/widgets/glass_panel.dart';
import '../ui/widgets/presence_badge.dart';

/// Избранное со всего сервера, а не по текущей папке. Оно живёт на сервере,
/// поэтому список одинаков во всех клиентах — и в веб-интерфейсе тоже.
class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({
    super.key,
    required this.session,
    required this.onOpenFiles,
  });

  final Session session;

  /// Уйти в «Файлы» и открыть там папку.
  final void Function(String path) onOpenFiles;

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  Session get s => widget.session;

  @override
  void initState() {
    super.initState();
    // Список приходит с сервера отдельным запросом — просим его при входе
    // в раздел, а не держим постоянно свежим.
    WidgetsBinding.instance.addPostFrameCallback((_) => s.refreshFavorites());
  }

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    final items = s.favorites;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              GradientText('Избранное', style: NxType.title),
              const SizedBox(height: 3),
              Text(
                s.favoritesLoading
                    ? 'Спрашиваем сервер…'
                    : items.isEmpty
                        ? 'Пока ничего не отмечено'
                        : '${items.length} '
                            '${plural(items.length, 'запись', 'записи', 'записей')} '
                            'со всего сервера',
                style: NxType.caption.copyWith(color: p.sub),
              ),
            ]),
          ),
          NxGhostButton(
            label: 'Обновить',
            icon: Icons.refresh_rounded,
            onTap: s.refreshFavorites,
          ),
        ]),
        const SizedBox(height: 14),
        Expanded(
          child: GlassPanel(
            radius: NxRadius.panel,
            padding: EdgeInsets.zero,
            child: _body(context, p, items),
          ),
        ),
      ]),
    );
  }

  Widget _body(BuildContext context, NxPalette p, List<RemoteFile> items) {
    final error = s.favoritesError;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline_rounded, size: 40, color: NxPalette.danger),
            const SizedBox(height: 14),
            Text('Список не пришёл',
                style: NxType.title.copyWith(color: p.txt, fontSize: 16)),
            const SizedBox(height: 7),
            Text(error,
                textAlign: TextAlign.center,
                style: NxType.bodyText.copyWith(color: p.sub, fontSize: 12.5)),
          ]),
        ),
      );
    }

    if (items.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.star_outline_rounded, size: 40, color: p.faint),
          const SizedBox(height: 14),
          Text('Здесь пусто', style: NxType.title.copyWith(color: p.txt, fontSize: 16)),
          const SizedBox(height: 7),
          Text('Отметьте файл звёздочкой — и он появится тут, '
              'в какой бы папке ни лежал.',
              style: NxType.bodyText.copyWith(color: p.sub, fontSize: 12.5)),
        ]),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(10),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (context, i) => _FavoriteRow(
        file: items[i],
        session: s,
        onGoToFolder: () => widget.onOpenFiles(items[i].parent),
      ),
    );
  }
}

class _FavoriteRow extends StatelessWidget {
  const _FavoriteRow({
    required this.file,
    required this.session,
    required this.onGoToFolder,
  });

  final RemoteFile file;
  final Session session;
  final VoidCallback onGoToFolder;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    final presence = session.vault.presenceOf(file);

    // Путь без имени: он и объясняет, откуда эта запись взялась.
    final where = file.parent.isEmpty ? 'в корне' : file.parent;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 9, 9, 9),
      decoration: BoxDecoration(
        color: p.field,
        borderRadius: BorderRadius.circular(NxRadius.tile),
        border: Border.all(color: p.stroke),
      ),
      child: Row(children: [
        FileThumbnail(file: file, cache: session.thumbs, size: 24),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(file.name,
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
        PresenceBadge(presence: presence, size: 14),
        const SizedBox(width: 12),
        SizedBox(
          width: 84,
          child: Text(
            file.isDir && file.size == 0 ? '—' : formatBytes(file.size),
            textAlign: TextAlign.right,
            style: NxType.numeric.copyWith(color: p.sub, fontSize: 11),
          ),
        ),
        const SizedBox(width: 14),
        NxGhostButton(
          label: 'К папке',
          icon: Icons.folder_open_rounded,
          onTap: onGoToFolder,
        ),
        const SizedBox(width: 6),
        Tooltip(
          message: 'Убрать из избранного',
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => session.setFavorite([file], false),
              child: const Icon(Icons.star_rounded, size: 17, color: NxPalette.warn),
            ),
          ),
        ),
      ]),
    );
  }
}
