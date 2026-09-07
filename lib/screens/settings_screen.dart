import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_state.dart';
import '../core/format.dart';
import '../core/session.dart';
import '../services/prefs.dart';
import '../core/models/cloud_provider.dart';
import '../services/sync_engine.dart';
import '../services/tray_service.dart';
import '../services/updater.dart';
import '../ui/theme.dart';
import '../ui/tokens.dart';
import '../ui/widgets/controls.dart';
import '../ui/widgets/accounts_panel.dart';
import '../ui/widgets/dialogs.dart';
import '../ui/widgets/login_dialog.dart';
import '../ui/widgets/update_dialog.dart';
import '../ui/widgets/glass_panel.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.app,
    required this.session,
    required this.updater,
    required this.prefs,
    required this.tray,
  });

  final AppState app;
  final Session session;
  final UpdaterService updater;
  final Prefs prefs;
  final TrayService tray;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _server =
      TextEditingController(text: widget.updater.stationUrl);

  AppState get app => widget.app;
  Session get session => widget.session;
  UpdaterService get updater => widget.updater;
  Prefs get prefs => widget.prefs;
  TrayService get tray => widget.tray;

  @override
  void initState() {
    super.initState();
    updater.addListener(_onUpdater);
  }

  @override
  void dispose() {
    updater.removeListener(_onUpdater);
    _server.dispose();
    super.dispose();
  }

  /// Смена папки хранилища. Уже скачанное переносится следом: оставить его
  /// на старом месте значило бы развести копии неизвестно где — ровно то,
  /// против чего это приложение и написано.
  Future<void> _pickVaultFolder() async {
    final picked = await getDirectoryPath(confirmButtonText: 'Выбрать');
    if (picked == null || !mounted) return;

    final target = Directory(picked);
    if (target.path == session.vault.root.path) return;

    final usage = session.vault.usage();
    if (usage.total > 0) {
      final ok = await confirm(
        context,
        title: 'Перенести хранилище?',
        message: '${formatBytes(usage.total)} скачанных файлов переедет '
            'из «${session.vault.root.path}» в «${target.path}». '
            'На сервере ничего не изменится.',
        confirmLabel: 'Перенести',
        danger: false,
      );
      if (!ok || !mounted) return;
    }

    try {
      final moved = await session.vault.moveRootTo(target);
      await prefs.writeVaultRoot(session.account.slug, target.path);
      if (!mounted) return;
      _toast(moved == 0
          ? 'Новая папка: ${target.path}'
          : 'Перенесено файлов: $moved');
    } catch (e) {
      if (mounted) _toast('Не удалось перенести: $e', danger: true);
    }
  }

  void _toast(String message, {bool danger = false}) {
    final p = NxTheme.of(context).palette;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        width: 560,
        backgroundColor: p.solid,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NxRadius.tile),
          side: BorderSide(color: danger ? NxPalette.danger : p.stroke2),
        ),
        content: Row(children: [
          Icon(danger ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
              size: 16, color: danger ? NxPalette.danger : NxPalette.ok),
          const SizedBox(width: 11),
          Expanded(
            child: Text(message,
                style: NxType.bodyText.copyWith(color: p.body, fontSize: 12.5)),
          ),
        ]),
      ));
  }

  void _onUpdater() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    final account = session.account;
    final usage = session.vault.usage();

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        GradientText('Настройки', style: NxType.title),
        const SizedBox(height: 3),
        Text('Оформление, хранилище, обновления и подключение',
            style: NxType.caption.copyWith(color: p.sub, shadows: t.textHalo)),
        const SizedBox(height: 16),
        Expanded(
          child: ListView(children: [
          _Section(title: 'Подключение', children: [
            _Info(label: 'Сервер', value: account.baseUrl.toString()),
            _Info(label: 'Учётная запись',
                value: account.displayName ?? account.loginName),
            _Info(label: 'Вход', value: 'Пароль приложения (хранится в Credential Manager)'),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: NxGhostButton(
                label: 'Отключиться и забыть пароль',
                icon: Icons.logout_rounded,
                danger: true,
                onTap: () async {
                  final ok = await confirm(
                    context,
                    title: 'Отключиться от сервера?',
                    message: 'Пароль приложения будет удалён из хранилища Windows. '
                        'Скачанные файлы останутся на диске.',
                    confirmLabel: 'Отключиться',
                  );
                  if (ok) await app.disconnect();
                },
              ),
            ),
          ]),
          _accountsSection(p),
          _updatesSection(context, t, p),
          _Section(title: 'Хранилище', children: [
            _Info(label: 'Папка локальных копий', value: session.vault.root.path),
            _Info(
                label: 'Занято на диске',
                value: '${formatBytes(usage.total)} '
                    '(закреплено ${formatBytes(usage.pinned)})'),
            if (session.quota != null)
              _Info(
                  label: 'На сервере',
                  value: session.quota!.unlimited
                      ? '${formatBytes(session.quota!.used)} (без ограничения)'
                      : '${formatBytes(session.quota!.used)} из '
                          '${formatBytes(session.quota!.total)}'),
            const SizedBox(height: 12),
            Row(children: [
              NxGhostButton(
                label: 'Выбрать папку…',
                icon: Icons.drive_file_move_outlined,
                onTap: _pickVaultFolder,
              ),
              const SizedBox(width: 8),
              NxGhostButton(
                label: 'Открыть папку',
                icon: Icons.folder_open_rounded,
                onTap: () => launchUrl(Uri.file(session.vault.root.path)),
              ),
              const SizedBox(width: 8),
              NxGhostButton(
                label: 'Очистить кэш миниатюр',
                icon: Icons.image_not_supported_outlined,
                onTap: () => session.thumbs.clearDisk(),
              ),
            ]),
          ]),
          _Section(title: 'Правка файлов', children: [
            _Row(
              label: 'Отправлять правки сразу',
              hint: 'Файл, открытый двойным кликом, уходит на сервер, '
                  'как только программа его сохранит',
              child: NxToggle(
                value: session.edits.autoPush,
                onChanged: (v) async {
                  setState(() => session.edits.autoPush = v);
                  await prefs.writeAutoPushEdits(v);
                },
              ),
            ),
            _Info(
              label: 'Слежение за папкой',
              value: session.edits.watching
                  ? 'Работает'
                  : 'Недоступно — правки найдутся при открытии папки',
            ),
            if (session.edits.pending.isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(children: [
                NxGhostButton(
                  label: 'Отправить замеченные правки '
                      '(${session.edits.pending.length})',
                  icon: Icons.upload_rounded,
                  onTap: () => setState(session.edits.pushAll),
                ),
              ]),
            ],
          ]),
          _syncSection(context, p),
          _traySection(),
          _Section(title: 'Оформление', children: [
            _Row(
              label: 'Тема',
              child: NxSegmented(
                options: const ['Тёмная', 'Светлая'],
                value: t.brightness == Brightness.dark ? 'Тёмная' : 'Светлая',
                compact: true,
                onChanged: (v) => NxTheme.set(
                  context,
                  t.copyWith(
                    brightness: v == 'Тёмная' ? Brightness.dark : Brightness.light,
                  ),
                ),
              ),
            ),
            _Row(
              label: 'Акцент',
              child: Wrap(spacing: 7, children: [
                for (final a in NxAccent.all)
                  _AccentDot(
                    accent: a,
                    selected: t.accent.id == a.id,
                    onTap: () => NxTheme.set(context, t.copyWith(accent: a)),
                  ),
              ]),
            ),
            _Row(
              label: 'Матовость панелей',
              hint: 'Стекло красивее, «Плотное» — заметно быстрее на слабой видеокарте',
              child: NxSegmented(
                options: const ['Стекло', 'Иней', 'Плотное'],
                value: switch (t.glass) {
                  NxGlass.glass || NxGlass.off => 'Стекло',
                  NxGlass.frost => 'Иней',
                  NxGlass.solid => 'Плотное',
                },
                compact: true,
                onChanged: (v) => NxTheme.set(
                  context,
                  t.copyWith(
                    glass: switch (v) {
                      'Иней' => NxGlass.frost,
                      'Плотное' => NxGlass.solid,
                      _ => NxGlass.glass,
                    },
                  ),
                ),
              ),
            ),
            _Row(
              label: 'Фон',
              child: NxSegmented(
                options: const ['Аврора', 'Шейдер', 'Нет'],
                value: switch (t.background) {
                  NxBackground.aurora => 'Аврора',
                  NxBackground.shader => 'Шейдер',
                  NxBackground.off => 'Нет',
                },
                compact: true,
                onChanged: (v) => NxTheme.set(
                  context,
                  t.copyWith(
                    background: switch (v) {
                      'Шейдер' => NxBackground.shader,
                      'Нет' => NxBackground.off,
                      _ => NxBackground.aurora,
                    },
                  ),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 20),
          Center(
            child: Text(
              'Nexus Nimbus · клиент Nextcloud для Windows',
              style: NxType.caption.copyWith(color: p.faint),
            ),
          ),
          const SizedBox(height: 10),
        ]),
        ),
      ]),
    );
  }

  /// Раздел обновлений. Канал один на приложение, но выбирается: публичный
  /// файл на GitHub или свой сервер — станция в домашней сети.
  /// Учётные записи облаков: те же строки, что и в панели у карточки внизу
  /// слева. Список один на оба места — иначе состояние в них разошлось бы.
  Widget _accountsSection(NxPalette p) {
    final missing = CloudProvider.values
        .where((v) => !app.accounts.any((a) => a.provider == v))
        .toList();

    return _Section(title: 'Учётные записи', children: [
      Text(
        'Каждое облако подключается своей записью: своё хранилище, своя '
        'синхронизация, свои передачи. Открыта всегда одна.',
        style: NxType.bodyText.copyWith(color: p.sub, fontSize: 12, height: 1.45),
      ),
      const SizedBox(height: 14),
      AccountsList(app: app, compact: false),
      if (missing.isNotEmpty) ...[
        const SizedBox(height: 4),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final provider in missing)
            NxGhostButton(
              label: 'Войти в ${provider.label}',
              icon: Icons.login_rounded,
              onTap: () => _login(provider),
            ),
        ]),
      ],
    ]);
  }

  Future<void> _login(CloudProvider provider) async {
    final added = await showLogin(context, provider: provider, app: app);
    if (added && mounted) setState(() {});
  }

  /// Раздел синхронизации: расписание, состояние последнего обхода,
  /// список закреплённых папок и расхождения, которые обход отложил.
  Widget _syncSection(BuildContext context, NxPalette p) {
    final sync = session.sync;
    final dirs = session.vault.pinnedDirs.toList()..sort();

    return _Section(title: 'Синхронизация', children: [
      _Row(
        label: 'Держать закреплённые папки в согласии с сервером',
        hint: 'Обход в обе стороны: что изменилось на сервере — придёт сюда, '
            'что изменилось здесь — уйдёт туда',
        child: NxToggle(
          value: sync.enabled,
          onChanged: (v) async {
            setState(() => sync.enabled = v);
            await prefs.writeSyncEnabled(v);
          },
        ),
      ),
      _Row(
        label: 'Синхронизировать всё облако',
        hint: 'Не только закреплённое, а всё дерево целиком — вместе со всем, '
            'что весит место на диске',
        child: NxToggle(
          value: sync.everything,
          onChanged: _setSyncEverything,
        ),
      ),
      _Row(
        label: 'Как часто обходить',
        child: NxSegmented(
          compact: true,
          options: const ['5 мин', '15 мин', '30 мин', '1 ч'],
          value: _intervalLabel(sync.interval),
          onChanged: (v) async {
            final minutes = _intervalMinutes(v);
            setState(() => sync.interval = Duration(minutes: minutes));
            await prefs.writeSyncInterval(minutes);
          },
        ),
      ),
      _Info(label: 'Состояние', value: _syncStatus(sync)),
      _Info(
        label: 'Что обходим',
        value: sync.everything
            ? 'Всё дерево'
            : dirs.isEmpty
                ? 'Ничего — закрепите папку через «Держать локально»'
                : dirs.join(', '),
      ),
      const SizedBox(height: 12),
      Row(children: [
        NxGhostButton(
          label: 'Синхронизировать сейчас',
          icon: Icons.sync_rounded,
          onTap: () => setState(() => unawaited(sync.syncNow())),
        ),
      ]),
      if (sync.conflicts.isNotEmpty) ...[
        const SizedBox(height: 14),
        SectionLabel('Расхождения (${sync.conflicts.length})'),
        const SizedBox(height: 8),
        Text(
          'Эти файлы правили и здесь, и на сервере. Серверная версия лежит '
          'на прежнем месте, местная отложена рядом — сравните и решите сами.',
          style: NxType.bodyText.copyWith(color: p.sub, fontSize: 12),
        ),
        const SizedBox(height: 10),
        for (final c in sync.conflicts) _ConflictRow(conflict: c, sync: sync),
      ],
    ]);
  }

  /// Включение «всего облака» стоит подтвердить: это может утянуть на диск
  /// столько, сколько занято на сервере, и обратно оно само не уйдёт.
  Future<void> _setSyncEverything(bool value) async {
    final sync = session.sync;
    if (value) {
      final used = session.quota?.used;
      final ok = await confirm(
        context,
        title: 'Держать на диске всё облако?',
        message: used == null
            ? 'Клиент скачает всё дерево целиком и будет держать его в '
                'согласии с сервером. Освободить место потом можно только '
                'выключив это обратно и вычистив кэш.'
            : 'Клиент скачает всё дерево целиком — сейчас это '
                '${formatBytes(used)}. Освободить место потом можно только '
                'выключив это обратно и вычистив кэш.',
        confirmLabel: 'Скачать всё',
        danger: false,
      );
      if (!ok) return;
    }
    if (!mounted) return;
    setState(() => sync.everything = value);
    await prefs.writeSyncEverything(value);
  }

  static String _intervalLabel(Duration d) => switch (d.inMinutes) {
        <= 5 => '5 мин',
        <= 15 => '15 мин',
        <= 30 => '30 мин',
        _ => '1 ч',
      };

  static int _intervalMinutes(String label) => switch (label) {
        '5 мин' => 5,
        '15 мин' => 15,
        '30 мин' => 30,
        _ => 60,
      };

  String _syncStatus(SyncEngine sync) {
    if (!sync.enabled) return 'Выключена';
    if (sync.phase == SyncPhase.running) {
      final where = sync.current;
      return where == null ? 'Идёт обход' : 'Идёт обход: $where';
    }
    if (sync.phase == SyncPhase.failed) return 'Сорвалась: ${sync.error}';

    final at = sync.lastRun;
    if (at == null) return 'Ещё не запускалась';

    final report = sync.lastReport;
    if (report == null || report.quiet) {
      final skipped = report == null || report.skipped == 0
          ? ''
          : ' · пропущено папок ${report.skipped}';
      return 'Всё сходится · ${formatDate(at)}$skipped';
    }

    final parts = <String>[];
    if (report.downloaded > 0) parts.add('скачано ${report.downloaded}');
    if (report.uploaded > 0) parts.add('отправлено ${report.uploaded}');
    if (report.removed > 0) parts.add('убрано ${report.removed}');
    if (report.conflicts > 0) parts.add('расхождений ${report.conflicts}');
    if (report.skipped > 0) parts.add('пропущено папок ${report.skipped}');
    return '${parts.join(', ')} · ${formatDate(at)}';
  }

  /// Трей, автозапуск и горячая клавиша — одна мысль на три переключателя:
  /// приложение под рукой, но не в панели задач.
  Widget _traySection() {
    return _Section(title: 'Трей и запуск', children: [
      _Row(
        label: 'Значок в трее',
        hint: 'Щелчок открывает окно, правая кнопка — меню',
        child: NxToggle(
          value: tray.tray,
          onChanged: (v) async {
            await tray.setTray(v);
            if (mounted) setState(() {});
          },
        ),
      ),
      _Row(
        label: 'Закрытие сворачивает в трей',
        hint: tray.tray
            ? 'Крестик прячет окно, а не выходит из программы'
            : 'Нужен значок в трее — иначе окно станет не достать',
        child: NxToggle(
          value: tray.closeToTray,
          onChanged: tray.tray
              ? (v) async {
                  await tray.setCloseToTray(v);
                  if (mounted) setState(() {});
                }
              : (_) {},
        ),
      ),
      _Row(
        label: 'Запускать вместе с Windows',
        child: NxToggle(
          value: tray.startAtLogin,
          onChanged: (v) async {
            await tray.setStartAtLogin(v);
            if (mounted) setState(() {});
          },
        ),
      ),
      _Row(
        label: 'Вызывать окно с клавиатуры',
        hint: '${TrayService.hotkeyLabel} — показать окно или спрятать его',
        child: NxToggle(
          value: tray.hotkey,
          onChanged: (v) async {
            await tray.setHotkey(v);
            if (mounted) setState(() {});
          },
        ),
      ),
    ]);
  }

  Widget _updatesSection(BuildContext context, NxThemeData t, NxPalette p) {
    final station = updater.channel == UpdateChannel.station;
    return _Section(title: 'Обновления', children: [
      _Info(label: 'Установленная версия', value: updater.currentVersion),
      _Info(label: 'Канал', value: updater.effectiveFeedUrl),
      if (updater.overriddenByEnv)
        _Info(
          label: 'Внимание',
          value: 'Канал задан переменной окружения ${UpdaterService.envOverride} '
              'и настройками ниже не меняется',
        ),
      const SizedBox(height: 4),
      _Row(
        label: 'Откуда брать',
        hint: station
            ? 'Свой сервер: адрес папки, в которой лежит appcast.xml'
            : 'Публичный файл в репозитории проекта',
        child: NxSegmented(
          options: const ['GitHub', 'Свой сервер'],
          value: station ? 'Свой сервер' : 'GitHub',
          compact: true,
          onChanged: (v) => updater.setChannel(
            v == 'Свой сервер' ? UpdateChannel.station : UpdateChannel.github,
          ),
        ),
      ),
      if (station) ...[
        Padding(
          padding: const EdgeInsets.only(bottom: 13),
          child: SizedBox(
            height: 36,
            child: TextField(
              controller: _server,
              onSubmitted: updater.setStationUrl,
              onTapOutside: (_) => updater.setStationUrl(_server.text),
              style: NxType.numeric.copyWith(color: p.body, fontSize: 12),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'http://100.79.130.7:8099/nimbus',
                hintStyle: NxType.numeric.copyWith(color: p.faint, fontSize: 12),
                prefixIcon: Icon(Icons.dns_rounded, size: 15, color: p.faint),
                prefixIconConstraints:
                    const BoxConstraints(minWidth: 34, minHeight: 34),
                filled: true,
                fillColor: p.field,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: p.stroke)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: p.stroke)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: t.accent.a2)),
              ),
            ),
          ),
        ),
      ],
      _Row(
        label: 'Проверять автоматически',
        hint: 'Раз в шесть часов и при запуске',
        child: NxToggle(value: updater.autoCheck, onChanged: updater.setAutoCheck),
      ),
      Row(children: [
        NxGhostButton(
          label: updater.status == UpdateStatus.checking
              ? 'Проверяем…'
              : 'Проверить обновления',
          icon: Icons.system_update_alt_rounded,
          onTap: _checkNow,
        ),
        const SizedBox(width: 12),
        if (updater.message != null)
          Expanded(
            child: Text(
              updater.message!,
              maxLines: 3,
              style: NxType.caption.copyWith(
                color: updater.status == UpdateStatus.failed
                    ? NxPalette.danger
                    : updater.status == UpdateStatus.available
                        ? NxPalette.ok
                        : p.faint,
                height: 1.4,
              ),
            ),
          ),
      ]),
      const SizedBox(height: 10),
      Text(
        'Обновление приходит полным установщиком и подписано ключом проекта: '
        'если подпись не сойдётся, оно не установится.',
        style: NxType.caption.copyWith(color: p.faint, height: 1.45),
      ),
      if (updater.skippedVersion.isNotEmpty) ...[
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: Text(
              'Версия ${updater.skippedVersion} пропущена — про неё больше '
              'не спрашиваем.',
              style: NxType.caption.copyWith(color: p.faint, height: 1.45),
            ),
          ),
          const SizedBox(width: 10),
          NxGhostButton(
            label: 'Вернуть',
            icon: Icons.undo_rounded,
            onTap: () async {
              await updater.unskip();
              if (mounted) setState(() {});
            },
          ),
        ]),
      ],
      const SizedBox(height: 16),
      _Releases(updater: updater),
    ]);
  }

  /// Проверка по кнопке. Пропущенную версию здесь показываем всё равно:
  /// человек спросил сам, значит хочет знать.
  Future<void> _checkNow() async {
    final release = await updater.findUpdate(ignoreSkipped: true);
    if (!mounted || release == null) return;
    await showUpdate(context, updater: updater, release: release);
    if (mounted) setState(() {});
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassPanel(
        radius: NxRadius.card,
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SectionLabel(title),
          const SizedBox(height: 14),
          ...children,
        ]),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.child, this.hint});
  final String label;
  final String? hint;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: NxType.bodyText
                    .copyWith(color: p.body, fontSize: 13, shadows: t.textHalo)),
            if (hint != null) ...[
              const SizedBox(height: 2),
              Text(hint!,
                  style: NxType.caption
                      .copyWith(color: p.faint, fontSize: 11, shadows: t.textHalo)),
            ],
          ]),
        ),
        const SizedBox(width: 16),
        child,
      ]),
    );
  }
}

/// Прежние версии из канала обновлений — на случай, когда в свежей что-то
/// сломалось и надо вернуться назад.
///
/// Установщик мы не запускаем сами, а отдаём системе. Это не лень: подпись
/// установщика проверяет WinSparkle, и он же ставит только самое новое.
/// Скачать и запустить прежнюю версию своими руками значило бы выполнить
/// файл без этой проверки — а ради неё в проекте и заведён ключ.
class _Releases extends StatefulWidget {
  const _Releases({required this.updater});
  final UpdaterService updater;

  @override
  State<_Releases> createState() => _ReleasesState();
}

class _ReleasesState extends State<_Releases> {
  List<ReleaseEntry> _releases = const [];
  bool _loading = false;
  bool _asked = false;
  String? _error;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _asked = true;
      _error = null;
    });
    try {
      final list = await widget.updater.listReleases();
      if (!mounted) return;
      setState(() {
        _releases = list;
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

  @override
  Widget build(BuildContext context) {
    final p = NxTheme.of(context).palette;
    final current = widget.updater.currentVersion;

    if (!_asked) {
      return Align(
        alignment: Alignment.centerLeft,
        child: NxGhostButton(
          label: 'Показать выпущенные версии',
          icon: Icons.history_rounded,
          onTap: _load,
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: SectionLabel('Выпущенные версии')),
        NxGhostButton(
          label: _loading ? 'Читаем канал…' : 'Обновить список',
          icon: Icons.refresh_rounded,
          onTap: _loading ? null : _load,
        ),
      ]),
      const SizedBox(height: 9),
      if (_error != null)
        Text(_error!,
            style: NxType.caption.copyWith(color: NxPalette.danger, height: 1.45))
      else if (_loading && _releases.isEmpty)
        Text('Спрашиваем канал…', style: NxType.caption.copyWith(color: p.sub))
      else if (_releases.isEmpty)
        Text('В канале пока нет ни одной записи.',
            style: NxType.caption.copyWith(color: p.sub))
      else ...[
        for (final r in _releases) _ReleaseRow(release: r, current: current),
        const SizedBox(height: 6),
        Text(
          'Установщик откроется в браузере — запускать его надо самому. '
          'Так его подпись проверяет Windows и вы сами видите, что качаете; '
          'обратно наверх приложение обновится само.',
          style: NxType.caption.copyWith(color: p.faint, height: 1.45),
        ),
      ],
    ]);
  }
}

class _ReleaseRow extends StatelessWidget {
  const _ReleaseRow({required this.release, required this.current});
  final ReleaseEntry release;
  final String current;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;

    final order = ReleaseEntry.compare(release.version, current);
    final (mark, colour) = switch (order) {
      0 => ('стоит сейчас', t.accent.a1),
      < 0 => ('прежняя', p.faint),
      _ => ('новее', NxPalette.ok),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 9, 9, 9),
        decoration: BoxDecoration(
          color: p.field,
          borderRadius: BorderRadius.circular(NxRadius.tile),
          border: Border.all(color: order == 0 ? t.accent.a2 : p.stroke),
        ),
        child: Row(children: [
          Icon(order == 0 ? Icons.check_circle_rounded : Icons.inventory_2_outlined,
              size: 16, color: colour),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(release.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NxType.bodyText.copyWith(color: p.txt, fontSize: 12.5)),
              const SizedBox(height: 2),
              Text(
                [
                  mark,
                  if (release.publishedAt != null) formatDate(release.publishedAt),
                  if (release.size > 0) formatBytes(release.size),
                ].join(' · '),
                style: NxType.numeric.copyWith(color: p.faint, fontSize: 10),
              ),
            ]),
          ),
          const SizedBox(width: 10),
          if (order != 0)
            NxGhostButton(
              label: order < 0 ? 'Откатиться' : 'Скачать',
              icon: Icons.download_rounded,
              onTap: () => launchUrl(Uri.parse(release.installerUrl),
                  mode: LaunchMode.externalApplication),
            ),
        ]),
      ),
    );
  }
}

/// Одно расхождение: куда легла местная копия и что с ней можно сделать.
class _ConflictRow extends StatelessWidget {
  const _ConflictRow({required this.conflict, required this.sync});
  final SyncConflict conflict;
  final SyncEngine sync;

  @override
  Widget build(BuildContext context) {
    final p = NxTheme.of(context).palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 9, 9, 9),
        decoration: BoxDecoration(
          color: p.field,
          borderRadius: BorderRadius.circular(NxRadius.tile),
          border: Border.all(color: p.stroke),
        ),
        child: Row(children: [
          const Icon(Icons.call_split_rounded, size: 16, color: NxPalette.warn),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(conflict.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NxType.bodyText.copyWith(color: p.txt, fontSize: 12.5)),
              const SizedBox(height: 2),
              Text('местная копия: ${conflict.backupName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NxType.numeric.copyWith(color: p.faint, fontSize: 10)),
            ]),
          ),
          const SizedBox(width: 10),
          NxGhostButton(
            label: 'Показать',
            icon: Icons.folder_open_rounded,
            onTap: () => Process.start('explorer', ['/select,', conflict.backup.path]),
          ),
          const SizedBox(width: 6),
          NxGhostButton(
            label: 'Убрать из списка',
            icon: Icons.close_rounded,
            onTap: () => sync.forgetConflict(conflict),
          ),
        ]),
      ),
    );
  }
}

class _Info extends StatelessWidget {
  const _Info({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 176,
          child: Text(label,
              style: NxType.bodyText
                  .copyWith(color: p.sub, fontSize: 12.5, shadows: t.textHalo)),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: NxType.numeric.copyWith(
                color: p.body, fontSize: 11.5, height: 1.4, shadows: t.textHalo),
          ),
        ),
      ]),
    );
  }
}

class _AccentDot extends StatelessWidget {
  const _AccentDot({required this.accent, required this.selected, required this.onTap});
  final NxAccent accent;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = NxTheme.of(context).palette;
    return Tooltip(
      message: accent.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: NxMotion.hover,
            width: 30,
            height: 30,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: selected ? p.txt : p.stroke, width: selected ? 1.6 : 1),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(shape: BoxShape.circle, gradient: accent.badge),
            ),
          ),
        ),
      ),
    );
  }
}

