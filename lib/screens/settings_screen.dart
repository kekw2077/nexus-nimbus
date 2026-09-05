import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/format.dart';
import '../core/session.dart';
import '../services/updater.dart';
import '../ui/theme.dart';
import '../ui/tokens.dart';
import '../ui/widgets/controls.dart';
import '../ui/widgets/dialogs.dart';
import '../ui/widgets/glass_panel.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.app,
    required this.session,
    required this.updater,
  });

  final AppState app;
  final Session session;
  final UpdaterService updater;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _server =
      TextEditingController(text: widget.updater.stationUrl);

  AppState get app => widget.app;
  Session get session => widget.session;
  UpdaterService get updater => widget.updater;

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
        Text('Настройки', style: NxType.title.copyWith(color: p.txt)),
        const SizedBox(height: 3),
        Text('Оформление, хранилище, обновления и подключение',
            style: NxType.caption.copyWith(color: p.sub)),
        const SizedBox(height: 16),
        Expanded(
          child: Scrollbar(
            thickness: 7,
            radius: const Radius.circular(8),
            child: ListView(children: [
              _Section(title: 'Подключение', children: [
                _Info(label: 'Сервер', value: account.baseUrl.toString()),
                _Info(label: 'Учётная запись',
                    value: account.displayName ?? account.loginName),
                _Info(label: 'Вход', value: 'Пароль приложения (хранится в Credential Manager)'),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: _Quiet(
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
                  _Quiet(
                    label: 'Очистить кэш миниатюр',
                    icon: Icons.image_not_supported_outlined,
                    onTap: () => session.thumbs.clearDisk(),
                  ),
                ]),
              ]),
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
                _Row(
                  label: 'Сетка точек',
                  hint: 'Режим «Отталкивание» пересчитывает физику каждый кадр',
                  child: NxSegmented(
                    options: const ['Свечение', 'Отталкивание', 'Нет'],
                    value: switch (t.dots) {
                      NxDotMode.glow => 'Свечение',
                      NxDotMode.push => 'Отталкивание',
                      NxDotMode.off => 'Нет',
                    },
                    compact: true,
                    onChanged: (v) => NxTheme.set(
                      context,
                      t.copyWith(
                        dots: switch (v) {
                          'Отталкивание' => NxDotMode.push,
                          'Нет' => NxDotMode.off,
                          _ => NxDotMode.glow,
                        },
                      ),
                    ),
                  ),
                ),
                _Row(
                  label: 'Анимации',
                  child: NxSegmented(
                    options: const ['Дыхание', 'Поток', 'Экономия'],
                    value: switch (t.anim) {
                      NxAnim.breathe => 'Дыхание',
                      NxAnim.flow || NxAnim.pulse => 'Поток',
                      NxAnim.off => 'Экономия',
                    },
                    compact: true,
                    onChanged: (v) => NxTheme.set(
                      context,
                      t.copyWith(
                        anim: switch (v) {
                          'Поток' => NxAnim.flow,
                          'Экономия' => NxAnim.off,
                          _ => NxAnim.breathe,
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
        ),
      ]),
    );
  }

  /// Раздел обновлений. Канал один на приложение, но выбирается: публичный
  /// файл на GitHub или свой сервер — станция в домашней сети.
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
        _Quiet(
          label: updater.status == UpdateStatus.checking
              ? 'Проверяем…'
              : 'Проверить обновления',
          icon: Icons.system_update_alt_rounded,
          onTap: () => updater.check(),
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
    ]);
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
    final p = NxTheme.of(context).palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: NxType.bodyText.copyWith(color: p.body, fontSize: 13)),
            if (hint != null) ...[
              const SizedBox(height: 2),
              Text(hint!, style: NxType.caption.copyWith(color: p.faint, fontSize: 11)),
            ],
          ]),
        ),
        const SizedBox(width: 16),
        child,
      ]),
    );
  }
}

class _Info extends StatelessWidget {
  const _Info({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final p = NxTheme.of(context).palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 176,
          child: Text(label, style: NxType.bodyText.copyWith(color: p.sub, fontSize: 12.5)),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: NxType.numeric.copyWith(color: p.body, fontSize: 11.5, height: 1.4),
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

class _Quiet extends StatefulWidget {
  const _Quiet({
    required this.label,
    required this.icon,
    required this.onTap,
    this.danger = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool danger;

  @override
  State<_Quiet> createState() => _QuietState();
}

class _QuietState extends State<_Quiet> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = NxTheme.of(context).palette;
    final fg = widget.danger ? NxPalette.danger : (_hover ? p.txt : p.body);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: NxMotion.hover,
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          decoration: BoxDecoration(
            color: _hover ? p.hover : p.field,
            borderRadius: BorderRadius.circular(NxRadius.chip),
            border: Border.all(
              color: widget.danger && _hover
                  ? NxPalette.danger.withValues(alpha: 0.6)
                  : p.stroke,
            ),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(widget.icon, size: 14, color: fg),
            const SizedBox(width: 7),
            Text(widget.label, style: NxType.label.copyWith(color: fg, fontSize: 12)),
          ]),
        ),
      ),
    );
  }
}
