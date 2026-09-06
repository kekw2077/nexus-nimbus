import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_state.dart';
import '../core/models/cloud_provider.dart';
import '../services/login_flow.dart';
import '../services/webdav_client.dart';
import '../ui/theme.dart';
import '../ui/tokens.dart';
import '../ui/widgets/aurora_background.dart';
import '../ui/widgets/controls.dart';
import '../ui/widgets/login_dialog.dart';
import '../ui/widgets/glass_panel.dart';
import '../ui/widgets/window_chrome.dart';

/// Вход целиком внутри окна приложения. Два пути:
/// вручную вбить пароль приложения, либо отправить пользователя в браузер
/// и дождаться, пока Nextcloud выдаст пароль сам (Login Flow v2).
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, required this.app});
  final AppState app;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  /// Куда входим. Облака, которые клиент ещё не умеет, сюда не попадают:
  /// выбрать то, что не заработает, было бы обманом.
  CloudProvider _provider = CloudProvider.nextcloud;

  static const _choices = CloudProvider.values;

  final _server = TextEditingController();
  final _login = TextEditingController();
  final _password = TextEditingController();

  bool _trustCertificate = false;
  bool _busy = false;
  String? _error;

  /// Пока идёт ожидание браузера, показываем отдельное состояние с отменой.
  LoginFlow? _flow;
  CancelToken? _flowCancel;

  @override
  void dispose() {
    _server.dispose();
    _login.dispose();
    _password.dispose();
    _flowCancel?.cancel();
    _flow?.dispose();
    super.dispose();
  }

  /// Приводит «cloud.example.com», «https://cloud.example.com/index.php/apps/files»
  /// и прочее, что можно скопировать из адресной строки, к базовому адресу.
  Uri? _parseServer() {
    final fixed = _provider.fixedServer;
    if (fixed != null) return fixed;

    var raw = _server.text.trim();
    if (raw.isEmpty) return null;
    if (!raw.contains('://')) raw = 'https://$raw';
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) return null;

    final segments = <String>[];
    for (final s in uri.pathSegments.where((s) => s.isNotEmpty)) {
      // Всё, что начиная с index.php и remote.php — уже не база.
      if (s == 'index.php' || s == 'remote.php' || s == 'apps' || s == 'login') break;
      segments.add(s);
    }
    return Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null)
        .replace(pathSegments: segments);
  }

  Future<void> _connectManually() async {
    final server = _parseServer();
    if (server == null) {
      setState(() => _error = 'Не разобрал адрес сервера. Пример: cloud.example.com');
      return;
    }
    if (_login.text.trim().isEmpty || _password.text.isEmpty) {
      setState(() => _error = 'Нужны логин и пароль приложения');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.app.connect(NxAccount(
        baseUrl: server,
        loginName: _login.text.trim(),
        appPassword: _password.text,
        allowBadCertificate: _trustCertificate,
        provider: _provider,
      ));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connectViaBrowser() async {
    final server = _parseServer();
    if (server == null) {
      setState(() => _error = 'Сначала укажите адрес сервера');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final flow = await LoginFlow.start(server, allowBadCertificate: _trustCertificate);
      final cancel = CancelToken();
      setState(() {
        _flow = flow;
        _flowCancel = cancel;
      });

      await launchUrl(flow.loginUrl, mode: LaunchMode.externalApplication);
      final account = await flow.awaitCredentials(
        allowBadCertificate: _trustCertificate,
        cancel: cancel,
      );

      if (!mounted) return;
      if (account == null) {
        setState(() => _error = cancel.isCancelled ? null : 'Время на вход истекло');
        return;
      }
      await widget.app.connect(account.copyWith(provider: _provider));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      _flow?.dispose();
      if (mounted) {
        setState(() {
          _flow = null;
          _flowCancel = null;
          _busy = false;
        });
      }
    }
  }

  void _cancelFlow() {
    _flowCancel?.cancel();
    setState(() {
      _flow = null;
      _flowCancel = null;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;

    return Container(
      color: p.bg,
      child: Stack(children: [
        const Positioned.fill(child: NxBackgroundLayer()),
        Positioned.fill(
          child: Column(children: [
            const WindowChrome(),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: SizedBox(
                    width: 460,
                    child: GlassPanel(
                      radius: NxRadius.panel,
                      padding: const EdgeInsets.all(30),
                      shadow: true,
                      child: _flow != null ? _waiting(t, p) : _form(t, p),
                    ),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _form(NxThemeData t, NxPalette p) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            gradient: t.accent.badge,
            borderRadius: BorderRadius.circular(13),
          ),
          alignment: Alignment.center,
          child: const Icon(Icons.cloud_rounded, size: 22, color: Colors.white),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            GradientText('Nexus Nimbus', style: NxType.title.copyWith(fontSize: 21)),
            const SizedBox(height: 2),
            Text('Файлы вашего облака',
                style: NxType.caption.copyWith(color: p.sub)),
          ]),
        ),
      ]),
      const SizedBox(height: 26),

      const SectionLabel('Облако'),
      const SizedBox(height: 8),
      NxSegmented(
        options: _choices.map((v) => v.label).toList(),
        value: _provider.label,
        onChanged: (v) => setState(() {
          _provider = _choices.firstWhere((c) => c.label == v);
          _error = null;
        }),
      ),
      const SizedBox(height: 16),

      // У Google пароля нет — только разрешение в браузере, и вход у него
      // свой. Отдельным окном, тем же, что открывается из настроек.
      if (!_provider.hasPasswordLogin) ...[
        Text(
          'К Google Drive пароль не подходит: доступ выдаётся разрешением '
          'в браузере, и только приложению, которое Google знает.',
          style: NxType.bodyText.copyWith(color: p.sub, fontSize: 12.5, height: 1.5),
        ),
        const SizedBox(height: 16),
        GradientButton(
          label: 'Настроить и войти',
          icon: Icons.open_in_new_rounded,
          onTap: () => showLogin(context, provider: _provider, app: widget.app),
        ),
      ] else ...[
      if (_provider.fixedServer == null) ...[
        const SectionLabel('Сервер'),
        const SizedBox(height: 8),
        NxField(controller: _server, hint: 'cloud.example.com'),
        const SizedBox(height: 16),
      ],

      const SectionLabel('Учётная запись'),
      const SizedBox(height: 8),
      NxField(
        controller: _login,
        hint: _provider == CloudProvider.yandex ? 'Имя на Яндексе' : 'Имя пользователя',
      ),
      const SizedBox(height: 9),
      _PasswordField(controller: _password),
      const SizedBox(height: 9),
      Text(
        'Пароль приложения создаётся на стороне облака: ${_provider.passwordHint}. '
        'Пароль от самой учётной записи вводить не нужно, и он никуда '
        'не сохраняется.',
        style: NxType.caption.copyWith(color: p.faint, height: 1.45),
      ),

      if (_provider.fixedServer == null) ...[
        const SizedBox(height: 16),
        Row(children: [
          NxToggle(
            value: _trustCertificate,
            onChanged: (v) => setState(() => _trustCertificate = v),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Text('Доверять самоподписанному сертификату',
                style: NxType.bodyText.copyWith(color: p.body, fontSize: 12.5)),
          ),
        ]),
      ],

      if (_error != null) ...[
        const SizedBox(height: 18),
        _ErrorBox(text: _error!),
      ],

      const SizedBox(height: 22),
      Row(children: [
        Expanded(
          child: _busy
              ? Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.2, color: t.accent.a2),
                  ),
                )
              : Center(
                  child: GradientButton(
                    label: 'Подключиться',
                    icon: Icons.arrow_forward_rounded,
                    onTap: _connectManually,
                    large: true,
                  ),
                ),
        ),
      ]),
      ],
      // Вход через браузер — Login Flow v2, расширение Nextcloud.
      if (_provider.hasBrowserLogin) ...[
        const SizedBox(height: 12),
        Center(
          child: _TextAction(
            label: 'Войти через браузер',
            icon: Icons.open_in_new_rounded,
            onTap: _busy ? null : _connectViaBrowser,
          ),
        ),
      ],
    ]);
  }

  Widget _waiting(NxThemeData t, NxPalette p) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Center(
        child: SizedBox(
          width: 34,
          height: 34,
          child: CircularProgressIndicator(strokeWidth: 2.4, color: t.accent.a2),
        ),
      ),
      const SizedBox(height: 22),
      Text('Ждём подтверждения в браузере',
          textAlign: TextAlign.center,
          style: NxType.title.copyWith(color: p.txt, fontSize: 18)),
      const SizedBox(height: 10),
      Text(
        'Откройте вкладку, которая только что появилась, войдите и разрешите '
        'доступ приложению Nexus Nimbus. Как только вы это сделаете, окно '
        'продолжит работу само.',
        textAlign: TextAlign.center,
        style: NxType.bodyText.copyWith(color: p.sub, fontSize: 12.5, height: 1.5),
      ),
      const SizedBox(height: 18),
      Center(
        child: _TextAction(
          label: 'Открыть ссылку ещё раз',
          icon: Icons.refresh_rounded,
          onTap: () => launchUrl(_flow!.loginUrl, mode: LaunchMode.externalApplication),
        ),
      ),
      const SizedBox(height: 8),
      Center(child: _TextAction(label: 'Отмена', onTap: _cancelFlow)),
    ]);
  }
}

class _PasswordField extends StatefulWidget {
  const _PasswordField({required this.controller});
  final TextEditingController controller;

  @override
  State<_PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<_PasswordField> {
  bool _hidden = true;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    return TextField(
      controller: widget.controller,
      obscureText: _hidden,
      style: NxType.numeric.copyWith(color: p.body, fontSize: 13, height: 1.5),
      decoration: InputDecoration(
        hintText: 'Пароль приложения',
        hintStyle: NxType.bodyText.copyWith(color: p.faint, fontSize: 13.5),
        filled: true,
        fillColor: p.field,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        suffixIcon: IconButton(
          icon: Icon(_hidden ? Icons.visibility_rounded : Icons.visibility_off_rounded,
              size: 17, color: p.sub),
          onPressed: () => setState(() => _hidden = !_hidden),
        ),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: p.stroke)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: p.stroke)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: t.accent.a2)),
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = NxTheme.of(context).palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: NxPalette.danger.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(NxRadius.tile),
        border: Border.all(color: NxPalette.danger.withValues(alpha: 0.4)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.error_outline_rounded, size: 16, color: NxPalette.danger),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text,
              style: NxType.bodyText.copyWith(color: p.body, fontSize: 12.5, height: 1.45)),
        ),
      ]),
    );
  }
}

class _TextAction extends StatefulWidget {
  const _TextAction({required this.label, this.icon, this.onTap});
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;

  @override
  State<_TextAction> createState() => _TextActionState();
}

class _TextActionState extends State<_TextAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;
    final enabled = widget.onTap != null;
    final color = !enabled ? p.faint : (_hover ? t.accent.a2 : p.sub);
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (widget.icon != null) ...[
              Icon(widget.icon, size: 14, color: color),
              const SizedBox(width: 7),
            ],
            Text(widget.label, style: NxType.label.copyWith(color: color, fontSize: 12.5)),
          ]),
        ),
      ),
    );
  }
}
