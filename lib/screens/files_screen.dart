import 'dart:async';
import 'dart:io';

import 'package:super_drag_and_drop/super_drag_and_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/format.dart';
import '../core/models/remote_file.dart';
import '../core/session.dart';
import '../services/transfer_queue.dart';
import '../ui/theme.dart';
import '../ui/tokens.dart';
import '../ui/widgets/controls.dart';
import '../ui/widgets/dialogs.dart';
import '../ui/widgets/drag_out.dart';
import '../ui/widgets/file_views.dart';
import '../ui/widgets/glass_panel.dart';
import '../ui/widgets/menu.dart';
import '../ui/widgets/search_dialog.dart';
import '../ui/widgets/share_dialog.dart';
import '../ui/widgets/versions_dialog.dart';
import '../ui/widgets/workspace_panel.dart';

class FilesScreen extends StatefulWidget {
  const FilesScreen({
    super.key,
    required this.session,
    required this.onOpenTransfers,
  });

  final Session session;

  /// Уйти в раздел «Передачи» — по полосе под кнопками.
  final VoidCallback onOpenTransfers;

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  Session get s => widget.session;

  final _searchController = TextEditingController();
  final _focus = FocusNode();

  /// Якорь для выделения диапазоном по Shift.
  String? _anchor;

  /// Куда сейчас целится перетаскивание: '' — в текущую папку,
  /// иначе путь папки под курсором.
  bool _dragOverBody = false;
  String? _dragOverFolder;

  @override
  void initState() {
    super.initState();
    s.addListener(_onSession);
  }

  @override
  void dispose() {
    s.removeListener(_onSession);
    _searchController.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onSession() {
    if (!mounted) return;
    if (_searchController.text != s.filter) {
      _searchController.value = TextEditingValue(
        text: s.filter,
        selection: TextSelection.collapsed(offset: s.filter.length),
      );
    }
    setState(() {});
  }

  // ------------------------------------------------------------- действия

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) _toast(e.toString(), danger: true);
    }
  }

  void _toast(String message, {bool danger = false}) =>
      showNxToast(context, message, danger: danger);

  void _tap(RemoteFile file, bool ctrl, bool shift) {
    if (shift && _anchor != null) {
      s.selectRange(_anchor!, file.path);
    } else {
      s.select(file.path, toggle: ctrl);
      _anchor = file.path;
    }
    _focus.requestFocus();
  }

  Future<void> _activate(RemoteFile file) async {
    if (file.isDir) {
      await s.open(file.path);
    } else {
      await _guard(() => s.openFile(file));
    }
  }

  Future<void> _newFolder() async {
    final name = await askText(
      context,
      title: 'Новая папка',
      hint: 'Имя папки',
      confirmLabel: 'Создать',
    );
    if (name == null) return;
    await _guard(() => s.createFolder(name));
  }

  Future<void> _rename(RemoteFile file) async {
    final base = file.isDir ? file.name : p.basenameWithoutExtension(file.name);
    final name = await askText(
      context,
      title: 'Переименовать',
      hint: 'Новое имя',
      confirmLabel: 'Сохранить',
      initial: file.name,
      selectTo: base.length,
    );
    if (name == null) return;
    await _guard(() => s.rename(file, name));
  }

  Future<void> _delete() async {
    final files = s.selectedFiles;
    if (files.isEmpty) return;
    final what = files.length == 1
        ? '«${files.first.name}»'
        : '${files.length} ${plural(files.length, 'объект', 'объекта', 'объектов')}';
    final ok = await confirm(
      context,
      title: 'Удалить $what?',
      message: 'Файлы уедут в корзину Nextcloud — оттуда их ещё можно достать. '
          'Локальные копии будут стёрты сразу.',
    );
    if (!ok) return;
    await _guard(s.deleteSelected);
  }

  /// История версий одного файла. Восстановление меняет содержимое на
  /// сервере, поэтому после него папку перечитываем.
  Future<void> _versions(RemoteFile file) async {
    final restored = await showVersions(context, session: s, file: file);
    if (restored && mounted) await _guard(s.refresh);
  }

  /// Публичные ссылки. Список менялся — перечитываем папку: признак
  /// «расшарено» приходит вместе со свойствами записи.
  /// Поиск по всему дереву. Поле в шапке фильтрует открытую папку — этого
  /// хватает в девяти случаях из десяти, а на десятый есть это окно.
  Future<void> _searchServer() async {
    if (!s.account.provider.hasSearch) return;
    final go = await showServerSearch(context, session: s, initial: s.filter);
    if (go == null || !mounted) return;
    await _guard(() => s.open(go));
  }

  Future<void> _share(RemoteFile file) async {
    final changed = await showShareLinks(context, session: s, file: file);
    if (changed && mounted) await _guard(s.refresh);
  }

  Future<void> _pickAndUpload({bool folder = false}) async {
    if (folder) {
      final dir = await getDirectoryPath(confirmButtonText: 'Загрузить папку');
      if (dir == null) return;
      await _guard(() => s.uploadPaths([dir]));
    } else {
      final files = await openFiles();
      if (files.isEmpty) return;
      await _guard(() => s.uploadPaths(files.map((f) => f.path)));
    }
  }

  void _contextMenu(Offset at, RemoteFile file) {
    // Правый клик по невыделенному сбрасывает выделение на этот файл —
    // так же, как в Проводнике.
    if (!s.selection.contains(file.path)) {
      s.select(file.path);
      _anchor = file.path;
    }
    final files = s.selectedFiles;
    final single = files.length == 1;
    final presence = s.vault.presenceOf(file);
    final hasLocal = files.any((f) =>
        f.isDir ? s.vault.isPinnedDir(f.path) : s.vault.presenceOf(f).isLocal);
    final canPin = files.any((f) => s.vault.presenceOf(f) != Presence.pinned);
    final canUnpin = files.any((f) => s.vault.presenceOf(f) == Presence.pinned);

    showNimbusMenu(context, at, [
      if (single && file.isDir)
        MenuAction('Открыть', Icons.folder_open_rounded, () => s.open(file.path))
      else if (single)
        MenuAction('Открыть', Icons.open_in_new_rounded, () => _guard(() => s.openFile(file))),
      MenuAction(
        files.length > 1 ? 'Скачать выбранное' : 'Скачать',
        Icons.download_rounded,
        () => _guard(() => s.download(files)),
      ),
      MenuAction(
        files.any((f) => f.isDir) ? 'Держать локально и синхронизировать' : 'Держать локально',
        Icons.push_pin_rounded,
        () => _guard(() => s.setPinned(files, true)),
        enabled: canPin,
      ),
      if (canUnpin)
        MenuAction(
          'Не держать локально',
          Icons.push_pin_outlined,
          () => _guard(() => s.setPinned(files, false)),
        ),
      MenuAction(
        'Освободить место',
        Icons.cloud_off_rounded,
        () => _guard(() => s.evict(files)),
        enabled: hasLocal,
      ),
      if (presence == Presence.dirty || presence == Presence.conflict)
        MenuAction('Отправить мои правки', Icons.upload_rounded,
            () => _guard(() => s.pushLocalChanges(file))),
      if (s.account.provider.hasFavorites) ...[
        menuSeparator,
        if (files.every((f) => f.favorite))
          MenuAction('Убрать из избранного', Icons.star_border_rounded,
              () => _guard(() => s.setFavorite(files, false)))
        else
          MenuAction('В избранное', Icons.star_rounded,
              () => _guard(() => s.setFavorite(files, true))),
      ],
      if (s.account.provider.hasLocks) ...[
        menuSeparator,
        // Занятый файл сервер не даёт переписать никому, кроме того, кто
        // его занял. Чужую блокировку снять нельзя — пункт остаётся
        // видимым, но выключенным, иначе непонятно, почему его нет.
        if (files.every((f) => f.isLocked && f.lock!.byMe(s.account.loginName)))
          MenuAction('Отпустить', Icons.lock_open_rounded,
              () => _guard(() => s.setLocked(files, false)))
        else
          MenuAction(
            'Занять за собой',
            Icons.lock_rounded,
            () => _guard(() => s.setLocked(files, true)),
            enabled: files.every((f) => !f.isLocked),
          ),
      ],
      menuSeparator,
      if (single)
        MenuAction('Переименовать', Icons.drive_file_rename_outline_rounded,
            () => _rename(file), enabled: file.canRename),
      if (single && !file.isDir)
        MenuAction('Показать в Проводнике', Icons.folder_special_rounded,
            () => _guard(() => s.revealInExplorer(file)),
            enabled: presence.isLocal),
      if (single && s.account.provider.hasShares)
        MenuAction(
          file.isShared ? 'Ссылки на это…' : 'Поделиться ссылкой…',
          file.isShared ? Icons.link_rounded : Icons.link_outlined,
          () => _share(file),
        ),
      if (single && !file.isDir && s.account.provider.hasVersions)
        MenuAction('Версии файла…', Icons.history_rounded, () => _versions(file),
            enabled: file.fileId != null),
      if (single)
        MenuAction('Открыть на сервере', Icons.language_rounded,
            () => _guard(() => s.openInBrowser(file))),
      menuSeparator,
      MenuAction('Удалить', Icons.delete_outline_rounded, _delete,
          danger: true, enabled: files.every((f) => f.canDelete)),
    ]);
  }

  void _emptyAreaMenu(Offset at) {
    s.clearSelection();
    showNimbusMenu(context, at, [
      MenuAction('Новая папка', Icons.create_new_folder_outlined, _newFolder),
      MenuAction('Загрузить файлы', Icons.upload_file_rounded, () => _pickAndUpload()),
      MenuAction('Загрузить папку', Icons.drive_folder_upload_rounded,
          () => _pickAndUpload(folder: true)),
      menuSeparator,
      MenuAction('Обновить', Icons.refresh_rounded, () => _guard(s.refresh)),
      MenuAction('Синхронизировать закреплённое', Icons.sync_rounded,
          () => _guard(s.sync.syncNow),
          enabled: s.vault.pinnedDirs.isNotEmpty),
    ]);
  }

  /// Пути к тому, что бросили в окно. Проводник отдаёт их по одному
  /// обратным вызовом на элемент, поэтому собираем по очереди.
  Future<List<String>> _droppedPaths(PerformDropEvent event) async {
    final out = <String>[];
    for (final item in event.session.items) {
      final reader = item.dataReader;
      if (reader == null) continue;

      final done = Completer<void>();
      final progress = reader.getValue<Uri>(
        Formats.fileUri,
        (uri) {
          if (uri != null && uri.isScheme('file')) {
            out.add(uri.toFilePath(windows: Platform.isWindows));
          }
          if (!done.isCompleted) done.complete();
        },
        onError: (_) {
          if (!done.isCompleted) done.complete();
        },
      );
      // null означает, что этот элемент такой формат не предлагает —
      // ждать нечего, обратный вызов не придёт.
      if (progress == null) continue;
      await done.future;
    }
    return out;
  }

  Future<void> _onDrop(PerformDropEvent event, String? targetFolder) async {
    final paths = await _droppedPaths(event);
    if (paths.isEmpty || !mounted) return;
    await _guard(() => s.uploadPaths(paths, into: targetFolder ?? s.path));
    if (!mounted) return;
    _toast('Добавлено в очередь: ${paths.length} '
        '${plural(paths.length, 'объект', 'объекта', 'объектов')}');
  }

  // ---------------------------------------------------------------- сборка

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyA, control: true): s.selectAll,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): _searchServer,
        const SingleActivator(LogicalKeyboardKey.f5): () => _guard(s.refresh),
        const SingleActivator(LogicalKeyboardKey.delete): _delete,
        const SingleActivator(LogicalKeyboardKey.escape): s.clearSelection,
        const SingleActivator(LogicalKeyboardKey.backspace): () => _guard(s.goUp),
        const SingleActivator(LogicalKeyboardKey.f2): () {
          final files = s.selectedFiles;
          if (files.length == 1) _rename(files.first);
        },
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: Column(children: [
          _Toolbar(
            session: s,
            controller: _searchController,
            onNewFolder: _newFolder,
            onUpload: () => _pickAndUpload(),
            onUploadFolder: () => _pickAndUpload(folder: true),
            onRefresh: () => _guard(s.refresh),
            onSearchServer: _searchServer,
            onOpenTransfers: widget.onOpenTransfers,
          ),
          if (s.selection.isNotEmpty)
            _SelectionBar(
              session: s,
              onDownload: () => _guard(() => s.download(s.selectedFiles)),
              onPin: () => _guard(() => s.setPinned(s.selectedFiles, true)),
              onEvict: () => _guard(() => s.evict(s.selectedFiles)),
              onDelete: _delete,
              onRename: () {
                final f = s.selectedFiles;
                if (f.length == 1) _rename(f.first);
              },
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 6, 18, 16),
              child: DropRegion(
                formats: const [Formats.fileUri],
                hitTestBehavior: HitTestBehavior.opaque,
                onDropOver: (_) {
                  if (!_dragOverBody) setState(() => _dragOverBody = true);
                  return DropOperation.copy;
                },
                onDropLeave: (_) => setState(() {
                  _dragOverBody = false;
                  _dragOverFolder = null;
                }),
                onPerformDrop: (event) async {
                  setState(() {
                    _dragOverBody = false;
                    _dragOverFolder = null;
                  });
                  await _onDrop(event, null);
                },
                child: GlassPanel(
                  radius: NxRadius.panel,
                  padding: EdgeInsets.zero,
                  color: _dragOverBody ? t.accent.a2.withValues(alpha: 0.10) : null,
                  child: Stack(children: [
                    Positioned.fill(child: _body(p)),
                    if (_dragOverBody)
                      Positioned.fill(child: IgnorePointer(child: _dropHint(t, p))),
                  ]),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _dropHint(NxThemeData t, NxPalette p) {
    final into = _dragOverFolder;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(NxRadius.card),
        border: Border.all(color: t.accent.a2, width: 1.6),
      ),
      alignment: Alignment.bottomCenter,
      padding: const EdgeInsets.only(bottom: 26),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
        decoration: BoxDecoration(
          color: p.solid,
          borderRadius: BorderRadius.circular(NxRadius.chip),
          border: Border.all(color: p.stroke2),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.file_download_rounded, size: 16, color: t.accent.a2),
          const SizedBox(width: 10),
          Text(
            into == null
                ? 'Отпустите — загрузим в «${s.breadcrumbs.last.label}»'
                : 'Отпустите — загрузим в «${_baseName(into)}»',
            style: NxType.label.copyWith(color: p.txt, fontSize: 12.5),
          ),
        ]),
      ),
    );
  }

  static String _baseName(String path) => path.split('/').last;

  /// Описание папки идёт над всем остальным — и над списком, и над
  /// заглушкой пустой папки: у папки с одним лишь README описание есть,
  /// а показывать нечего, и без панели она выглядела бы просто пустой.
  Widget _body(NxPalette p) {
    final workspace = s.workspace;
    final content = _content(p);
    if (workspace == null) return content;

    // Потолок панели — доля окна: развёрнутое описание листается внутри,
    // а список файлов и кнопка «свернуть» остаются на экране.
    return LayoutBuilder(
      builder: (context, constraints) => Column(children: [
        WorkspacePanel(
          markdown: workspace,
          maxHeight: constraints.maxHeight * 0.55,
        ),
        Expanded(child: content),
      ]),
    );
  }

  Widget _content(NxPalette p) {
    if (s.loading && s.visible.isEmpty) {
      return Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(
              strokeWidth: 2.2, color: NxTheme.of(context).accent.a2),
        ),
      );
    }

    if (s.error != null) {
      return _Placeholder(
        icon: Icons.cloud_off_rounded,
        title: 'Не получилось открыть папку',
        message: s.error!,
        actionLabel: 'Повторить',
        onAction: () => _guard(s.refresh),
      );
    }

    final items = s.visible;
    if (items.isEmpty) {
      return _Placeholder(
        icon: s.filter.isNotEmpty ? Icons.search_off_rounded : Icons.inbox_rounded,
        title: s.filter.isNotEmpty ? 'Ничего не нашлось' : 'Папка пуста',
        message: s.filter.isNotEmpty
            ? 'В этой папке нет файлов, подходящих под «${s.filter}».'
            : 'Перетащите сюда файлы или нажмите «Загрузить».',
        actionLabel: s.filter.isNotEmpty ? null : 'Загрузить файлы',
        onAction: s.filter.isNotEmpty ? null : () => _pickAndUpload(),
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: s.clearSelection,
      onSecondaryTapUp: (d) => _emptyAreaMenu(d.globalPosition),
      child: s.view == ViewMode.list ? _list(items, p) : _grid(items),
    );
  }

  Widget _list(List<RemoteFile> items, NxPalette p) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: FileListHeader(
          sort: switch (s.sort) {
            SortField.size => SortKey.size,
            SortField.modified => SortKey.modified,
            _ => SortKey.name,
          },
          ascending: s.ascending,
          onSort: (key) => s.setSort(switch (key) {
            SortKey.size => SortField.size,
            SortKey.modified => SortField.modified,
            SortKey.name => SortField.name,
          }),
        ),
      ),
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(8, 2, 8, 10),
          itemCount: items.length,
          itemExtent: FileRow.height + 2,
          itemBuilder: (context, i) {
            final f = items[i];
            return Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: _wrapFolderTarget(
                f,
                DragOut(
                  session: s,
                  file: f,
                  child: FileRow(
                    file: f,
                    presence: s.vault.presenceOf(f),
                    selected: s.selection.contains(f.path),
                    cache: s.thumbs,
                    onTap: (ctrl, shift) => _tap(f, ctrl, shift),
                    onDoubleTap: () => _activate(f),
                    onSecondaryTap: (at) => _contextMenu(at, f),
                    onTogglePin: () => _guard(() => s.setPinned(
                          [f],
                          s.vault.presenceOf(f) != Presence.pinned,
                        )),
                    dropHighlight: _dragOverFolder == f.path,
                    transfer: s.transfers.activeFor(f.path),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ]);
  }

  Widget _grid(List<RemoteFile> items) {
    return GridView.builder(
      padding: const EdgeInsets.all(14),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 148,
        mainAxisExtent: 156,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final f = items[i];
        return _wrapFolderTarget(
          f,
          DragOut(
            session: s,
            file: f,
            child: FileTile(
              file: f,
              presence: s.vault.presenceOf(f),
              selected: s.selection.contains(f.path),
              cache: s.thumbs,
              onTap: (ctrl, shift) => _tap(f, ctrl, shift),
              onDoubleTap: () => _activate(f),
              onSecondaryTap: (at) => _contextMenu(at, f),
              dropHighlight: _dragOverFolder == f.path,
              transfer: s.transfers.activeFor(f.path),
            ),
          ),
        );
      },
    );
  }

  /// Папка — самостоятельная цель для перетаскивания: файлы можно бросить
  /// прямо в неё, не заходя внутрь.
  Widget _wrapFolderTarget(RemoteFile file, Widget child) {
    if (!file.isDir) return child;
    // Вложенная область приёма перехватывает бросок раньше внешней —
    // так файл попадает в папку под курсором, а не в открытую.
    return DropRegion(
      formats: const [Formats.fileUri],
      hitTestBehavior: HitTestBehavior.opaque,
      onDropOver: (_) {
        if (_dragOverFolder != file.path) {
          setState(() => _dragOverFolder = file.path);
        }
        return DropOperation.copy;
      },
      onDropLeave: (_) {
        if (_dragOverFolder == file.path) setState(() => _dragOverFolder = null);
      },
      onPerformDrop: (event) async {
        setState(() {
          _dragOverBody = false;
          _dragOverFolder = null;
        });
        await _onDrop(event, file.path);
      },
      child: child,
    );
  }
}

// ------------------------------------------------------------------ шапка

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.session,
    required this.controller,
    required this.onSearchServer,
    required this.onOpenTransfers,
    required this.onNewFolder,
    required this.onUpload,
    required this.onUploadFolder,
    required this.onRefresh,
  });

  final Session session;
  final TextEditingController controller;
  final VoidCallback onSearchServer;
  final VoidCallback onOpenTransfers;
  final VoidCallback onNewFolder, onUpload, onUploadFolder, onRefresh;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    final s = session;

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
      child: Column(children: [
        Row(children: [
          _IconAction(
              icon: Icons.arrow_back_rounded,
              tooltip: 'Назад',
              enabled: s.canGoBack,
              onTap: s.goBack),
          _IconAction(
              icon: Icons.arrow_forward_rounded,
              tooltip: 'Вперёд',
              enabled: s.canGoForward,
              onTap: s.goForward),
          _IconAction(
              icon: Icons.arrow_upward_rounded,
              tooltip: 'На уровень выше',
              enabled: s.canGoUp,
              onTap: s.goUp),
          const SizedBox(width: 8),
          Expanded(child: _Breadcrumbs(session: s)),
          const SizedBox(width: 12),
          SizedBox(
            width: 210,
            child: _Search(
              controller: controller,
              session: s,
              onSearchServer: onSearchServer,
            ),
          ),
          if (s.account.provider.hasSearch) ...[
            const SizedBox(width: 4),
            _IconAction(
                icon: Icons.travel_explore_rounded,
                tooltip: 'Искать по всему серверу (Ctrl F)',
                onTap: onSearchServer),
          ],
          const SizedBox(width: 8),
          _IconAction(
              icon: Icons.refresh_rounded,
              tooltip: 'Обновить (F5)',
              spinning: s.loading,
              onTap: onRefresh),
          const SizedBox(width: 4),
          NxSegmented(
            options: const ['Список', 'Плитка'],
            value: s.view == ViewMode.list ? 'Список' : 'Плитка',
            compact: true,
            onChanged: (v) => s.setView(v == 'Список' ? ViewMode.list : ViewMode.grid),
          ),
        ]),
        const SizedBox(height: 11),
        Row(children: [
          GradientButton(label: 'Загрузить', icon: Icons.upload_rounded, onTap: onUpload),
          const SizedBox(width: 8),
          NxGhostButton(
              label: 'Загрузить папку',
              icon: Icons.drive_folder_upload_rounded,
              onTap: onUploadFolder),
          const SizedBox(width: 8),
          NxGhostButton(
              label: 'Новая папка',
              icon: Icons.create_new_folder_outlined,
              onTap: onNewFolder),
          const Spacer(),
          Text(
            _summary(s),
            // Не faint: строка лежит на живом фоне, а не на панели.
            style: NxType.numeric
                .copyWith(color: p.sub, fontSize: 11, shadows: t.textHalo),
          ),
        ]),
        if (s.transfers.activeCount > 0) ...[
          const SizedBox(height: 10),
          _TransferStrip(queue: s.transfers, onOpen: onOpenTransfers),
        ],
      ]),
    );
  }

  static String _summary(Session s) {
    final items = s.visible;
    if (items.isEmpty) return '';
    final dirs = items.where((f) => f.isDir).length;
    final files = items.length - dirs;
    final bytes = items.where((f) => !f.isDir).fold<int>(0, (a, f) => a + f.size);
    final parts = <String>[];
    if (dirs > 0) parts.add('$dirs папок');
    if (files > 0) parts.add('$files файлов · ${formatBytes(bytes)}');
    return parts.join(' · ');
  }
}

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    final p = NxTheme.of(context).palette;
    final crumbs = session.breadcrumbs;
    return SizedBox(
      height: 28,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        reverse: crumbs.length > 5,
        itemCount: crumbs.length,
        itemBuilder: (context, index) {
          // При обратной прокрутке хвост должен оставаться видимым.
          final i = crumbs.length > 5 ? crumbs.length - 1 - index : index;
          final c = crumbs[i];
          final last = i == crumbs.length - 1;
          return Row(children: [
            if (i > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Icon(Icons.chevron_right_rounded, size: 15, color: p.faint),
              ),
            _Crumb(
              label: c.label,
              current: last,
              onTap: last ? null : () => session.open(c.path),
            ),
          ]);
        },
      ),
    );
  }
}

class _Crumb extends StatefulWidget {
  const _Crumb({required this.label, required this.current, this.onTap});
  final String label;
  final bool current;
  final VoidCallback? onTap;

  @override
  State<_Crumb> createState() => _CrumbState();
}

class _CrumbState extends State<_Crumb> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = NxTheme.of(context).palette;
    return MouseRegion(
      cursor: widget.onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: NxMotion.hover,
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: _hover && widget.onTap != null ? p.hover : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            widget.label,
            style: NxType.label.copyWith(
              color: widget.current ? p.txt : p.sub,
              fontSize: 13,
              fontWeight: widget.current ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// Что передаётся прямо сейчас — полосой под кнопками, не уходя в «Передачи».
///
/// Появляется, только пока очередь не пуста: постоянная пустая полоса
/// съедала бы строку у списка файлов и ничего не сообщала.
class _TransferStrip extends StatefulWidget {
  const _TransferStrip({required this.queue, required this.onOpen});
  final TransferQueue queue;
  final VoidCallback onOpen;

  @override
  State<_TransferStrip> createState() => _TransferStripState();
}

class _TransferStripState extends State<_TransferStrip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    final q = widget.queue;

    final total = q.totalBytes;
    final size = total > 0
        ? '${formatBytes(q.doneBytes)} из ${formatBytes(total)}'
        : 'считаем объём…';

    // Когда идёт одна пачка и больше ничего — называем её по имени.
    // «Передаётся 3 файла» про заливку папки на пятьдесят тысяч файлов
    // говорит неправду: три — это те, что влезли в три потока.
    final batches = q.activeBatches.toList();
    final single = batches.length == 1 && q.filesTotal == batches.first.files;
    final headline = single
        ? '${batches.first.kind == TransferKind.download ? 'Скачивается' : 'Загружается'} '
            '«${batches.first.label}»'
        : 'Передаётся ${formatCount(q.activeCount)} '
            '${plural(q.activeCount, 'файл', 'файла', 'файлов')}';

    // Счёт файлов важнее процентов: он не врёт, пока идёт обход дерева,
    // и по нему видно, далеко ли до конца, даже когда файлы разного веса.
    final files = q.filesTotal > 0
        ? '${formatCount(q.filesDone)} из ${formatCount(q.filesTotal)}'
        : '';

    final right = <String>[];
    final speed = q.bytesPerSecond;
    if (speed > 0) right.add(formatSpeed(speed));
    final left = q.remaining;
    if (left != null && left > Duration.zero) {
      right.add('осталось ${formatDuration(left)}');
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onOpen,
        child: Container(
          padding: const EdgeInsets.fromLTRB(13, 9, 9, 10),
          decoration: BoxDecoration(
            color: _hover ? p.hover : p.field,
            borderRadius: BorderRadius.circular(NxRadius.tile),
            border: Border.all(color: p.stroke),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(Icons.swap_vert_rounded, size: 15, color: t.accent.a1),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  headline,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NxType.label.copyWith(color: p.txt, fontSize: 12),
                ),
              ),
              if (files.isNotEmpty) ...[
                const SizedBox(width: 10),
                Text(files, style: NxType.numeric.copyWith(color: p.sub, fontSize: 11)),
              ],
              const SizedBox(width: 10),
              Text(size, style: NxType.numeric.copyWith(color: p.sub, fontSize: 11)),
              const Spacer(),
              if (right.isNotEmpty)
                Text(right.join(' · '),
                    style: NxType.numeric.copyWith(color: p.faint, fontSize: 11)),
              const SizedBox(width: 12),
              Text(
                q.scanning ? 'считаем…' : '${(q.overallFraction * 100).round()}%',
                style: NxType.numeric.copyWith(color: t.accent.a1, fontSize: 11),
              ),
              const SizedBox(width: 10),
              Tooltip(
                message: 'Отменить всё',
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: q.cancelAll,
                    child: Icon(Icons.close_rounded, size: 15, color: p.sub),
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            // Пока дерево обходится, полоса стоит на нуле, а не ползёт
            // назад с каждой найденной тысячей файлов.
            NxProgressLine(fraction: q.scanning ? 0 : q.overallFraction, height: 3),
          ]),
        ),
      ),
    );
  }
}

class _Search extends StatelessWidget {
  const _Search({
    required this.controller,
    required this.session,
    required this.onSearchServer,
  });

  final TextEditingController controller;
  final Session session;

  /// Enter в поле фильтра — «этого мало, ищи везде».
  final VoidCallback onSearchServer;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    return SizedBox(
      height: 32,
      child: TextField(
        controller: controller,
        onChanged: session.setFilter,
        onSubmitted: (_) => onSearchServer(),
        style: NxType.bodyText.copyWith(color: p.body, fontSize: 12.5),
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Фильтр по этой папке',
          hintStyle: NxType.bodyText.copyWith(color: p.faint, fontSize: 12.5),
          prefixIcon: Icon(Icons.search_rounded, size: 15, color: p.faint),
          prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          suffixIcon: controller.text.isEmpty
              ? null
              : GestureDetector(
                  onTap: () {
                    controller.clear();
                    session.setFilter('');
                  },
                  child: Icon(Icons.close_rounded, size: 14, color: p.sub),
                ),
          suffixIconConstraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          filled: true,
          fillColor: p.field,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(NxRadius.chip),
              borderSide: BorderSide(color: p.stroke)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(NxRadius.chip),
              borderSide: BorderSide(color: p.stroke)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(NxRadius.chip),
              borderSide: BorderSide(color: t.accent.a2)),
        ),
      ),
    );
  }
}

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.session,
    required this.onDownload,
    required this.onPin,
    required this.onEvict,
    required this.onDelete,
    required this.onRename,
  });

  final Session session;
  final VoidCallback onDownload, onPin, onEvict, onDelete, onRename;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    final n = session.selection.length;

    return Container(
      margin: const EdgeInsets.fromLTRB(18, 0, 18, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: p.accentSoft,
        borderRadius: BorderRadius.circular(NxRadius.tile),
        border: Border.all(color: t.accent.a2.withValues(alpha: 0.45)),
      ),
      child: Row(children: [
        Icon(Icons.check_circle_rounded, size: 15, color: t.accent.a2),
        const SizedBox(width: 10),
        Text(
          'Выбрано $n · ${formatBytes(session.selectedSize)}',
          style: NxType.label.copyWith(color: p.txt, fontSize: 12.5),
        ),
        const Spacer(),
        NxGhostButton(label: 'Скачать', icon: Icons.download_rounded, onTap: onDownload),
        const SizedBox(width: 6),
        NxGhostButton(label: 'Держать локально', icon: Icons.push_pin_outlined, onTap: onPin),
        const SizedBox(width: 6),
        NxGhostButton(label: 'Освободить', icon: Icons.cloud_off_rounded, onTap: onEvict),
        const SizedBox(width: 6),
        if (n == 1)
          NxGhostButton(
              label: 'Переименовать',
              icon: Icons.drive_file_rename_outline_rounded,
              onTap: onRename),
        if (n == 1) const SizedBox(width: 6),
        NxGhostButton(
            label: 'Удалить', icon: Icons.delete_outline_rounded, danger: true, onTap: onDelete),
        const SizedBox(width: 10),
        _IconAction(
            icon: Icons.close_rounded, tooltip: 'Снять выделение', onTap: session.clearSelection),
      ]),
    );
  }
}

// ------------------------------------------------------------ мелкие части

class _IconAction extends StatefulWidget {
  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.enabled = true,
    this.spinning = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool enabled;
  final bool spinning;

  @override
  State<_IconAction> createState() => _IconActionState();
}

class _IconActionState extends State<_IconAction> with SingleTickerProviderStateMixin {
  bool _hover = false;
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void didUpdateWidget(_IconAction old) {
    super.didUpdateWidget(old);
    if (widget.spinning && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!widget.spinning && _spin.isAnimating) {
      _spin.stop();
      _spin.value = 0;
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = NxTheme.of(context).palette;
    final color = !widget.enabled ? p.faint : (_hover ? p.txt : p.sub);
    Widget icon = Icon(widget.icon, size: 16, color: color);
    if (widget.spinning) icon = RotationTransition(turns: _spin, child: icon);

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: widget.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.enabled ? widget.onTap : null,
          child: AnimatedContainer(
            duration: NxMotion.hover,
            width: 30,
            height: 28,
            decoration: BoxDecoration(
              color: _hover && widget.enabled ? p.hover : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Center(child: icon),
          ),
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final p = NxTheme.of(context).palette;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 42, color: p.faint),
          const SizedBox(height: 16),
          Text(title, style: NxType.title.copyWith(color: p.txt, fontSize: 17)),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: NxType.bodyText.copyWith(color: p.sub, fontSize: 12.5, height: 1.5),
          ),
          if (actionLabel != null) ...[
            const SizedBox(height: 20),
            GradientButton(label: actionLabel!, onTap: onAction),
          ],
        ]),
      ),
    );
  }
}
