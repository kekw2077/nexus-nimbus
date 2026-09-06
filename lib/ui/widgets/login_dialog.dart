import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_state.dart';
import '../../core/models/cloud_provider.dart';
import '../../services/google/google_auth.dart';
import '../../services/login_flow.dart';
import '../../services/webdav_client.dart';
import '../theme.dart';
import '../tokens.dart';
import 'controls.dart';
import 'glass_panel.dart';

/// Вход в облако отдельным окном — тем же, что открывается из панели учётных
/// записей и из настроек. Возвращает true, если запись подключилась.
///
/// Окно намеренно небольшое: форма короткая, а на невысоком экране ноутбука
/// оно должно помещаться целиком.
Future<bool> showLogin(
  BuildContext context, {
  required CloudProvider provider,
  required AppState app,
}) async {
  final t = NxTheme.of(context);
  final ok = await showDialog<bool>(
    context: context,
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
            child: _LoginBody(provider: provider, app: app),
          ),
        ),
      ),
    ),
  );
  return ok ?? false;
}

class _LoginBody extends StatefulWidget {
  const _LoginBody({required this.provider, required this.app});
  final CloudProvider provider;
  final AppState app;

  @override
  State<_LoginBody> createState() => _LoginBodyState();
}

class _LoginBodyState extends State<_LoginBody> {
  final _server = TextEditingController();
  final _login = TextEditingController();
  final _password = TextEditingController();

  bool _trustCertificate = false;
  bool _busy = false;
  String? _error;

  /// Пока ждём браузер, показываем отдельное состояние с отменой.
  LoginFlow? _flow;
  CancelToken? _flowCancel;

  /// То же ожидание, но для Google: у него свой обмен кодами.
  CancelableWait? _googleWait;

  /// Учётные данные приложения Google. Их вводят один раз, и дальше они
  /// живут в настройках — но начать вход без них нельзя, поэтому поля
  /// показываются прямо здесь, пока они пусты.
  final _clientId = TextEditingController();
  final _clientSecret = TextEditingController();
  bool _clientReady = false;

  CloudProvider get provider => widget.provider;

  @override
  void initState() {
    super.initState();
    if (provider == CloudProvider.google) {
      final saved = widget.app.googleClient;
      _clientId.text = saved.id;
      _clientSecret.text = saved.secret;
      _clientReady = !saved.isEmpty;
    }
  }

  @override
  void dispose() {
    _server.dispose();
    _login.dispose();
    _password.dispose();
    _clientId.dispose();
    _clientSecret.dispose();
    _flowCancel?.cancel();
    _flow?.dispose();
    _googleWait?.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------- Google

  Future<void> _saveGoogleClient() async {
    final id = _clientId.text.trim();
    final secret = _clientSecret.text.trim();
    if (id.isEmpty || secret.isEmpty) {
      setState(() => _error = 'Нужны и идентификатор, и секрет клиента');
      return;
    }
    await widget.app.saveGoogleClient(id, secret);
    if (mounted) {
      setState(() {
        _clientReady = true;
        _error = null;
      });
    }
  }

  Future<void> _connectGoogle() async {
    final client = widget.app.googleClient;
    if (client.isEmpty) {
      setState(() => _error = 'Сначала сохраните учётные данные приложения');
      return;
    }

    final wait = CancelableWait();
    setState(() {
      _busy = true;
      _error = null;
      _googleWait = wait;
    });

    final auth = GoogleAuth(client);
    try {
      final granted = await auth.authorize(
        onUrl: (url) => launchUrl(url, mode: LaunchMode.externalApplication),
        cancel: wait,
      );
      if (!mounted) return;
      if (granted == null) {
        setState(() => _error = wait.isCancelled ? null : 'Время на вход истекло');
        return;
      }

      await widget.app.connect(NxAccount(
        // Адрес у Диска один и в запросах не участвует — он нужен только
        // затем, чтобы отличать записи друг от друга.
        baseUrl: Uri.parse('https://drive.google.com'),
        loginName: granted.email,
        appPassword: granted.refreshToken,
        provider: CloudProvider.google,
      ));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      auth.close();
      if (mounted) {
        setState(() {
          _busy = false;
          _googleWait = null;
        });
      }
    }
  }

  void _cancelGoogle() {
    _googleWait?.cancel();
    setState(() {
      _googleWait = null;
      _busy = false;
    });
  }

  /// Приводит «cloud.example.com» и всё, что можно скопировать из адресной
  /// строки, к базовому адресу. У облака с постоянным адресом брать нечего.
  Uri? _parseServer() {
    final fixed = provider.fixedServer;
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

  Future<void> _connect() async {
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
        provider: provider,
      ));
      if (mounted) Navigator.of(context).pop(true);
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
      await widget.app.connect(account.copyWith(provider: provider));
      if (mounted) Navigator.of(context).pop(true);
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

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Вход в ${provider.label}',
            style: NxType.title.copyWith(color: p.txt, fontSize: 17)),
        const SizedBox(height: 14),
        if (provider == CloudProvider.google)
          _google(t, p)
        else if (_flow != null)
          _waiting(t, p)
        else
          _form(t, p),
      ],
    );
  }

  /// Вход в Google. Пароля здесь нет и быть не может: к Диску ведёт только
  /// OAuth, а он требует, чтобы приложение было заранее зарегистрировано.
  Widget _google(NxThemeData t, NxPalette p) {
    if (_googleWait != null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: t.accent.a2),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Ждём разрешения в браузере. Выберите учётную запись и разрешите '
              'доступ — окно закроется само.',
              style: NxType.bodyText.copyWith(color: p.sub, fontSize: 12.5, height: 1.45),
            ),
          ),
        ]),
        const SizedBox(height: 20),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          NxGhostButton(label: 'Отменить', onTap: _cancelGoogle),
        ]),
      ]);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (!_clientReady) ...[
        Text(
          'Google не пускает к Диску по паролю — только через разрешение в '
          'браузере, и только приложению, которое он знает. Зарегистрируйте '
          'его один раз в Google Cloud Console: создайте проект, включите '
          'Drive API, настройте экран согласия и создайте учётные данные '
          'типа «Desktop app».',
          style: NxType.bodyText.copyWith(color: p.sub, fontSize: 12, height: 1.5),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: NxGhostButton(
            label: 'Открыть Cloud Console',
            icon: Icons.open_in_new_rounded,
            onTap: () => launchUrl(
              Uri.parse('https://console.cloud.google.com/apis/credentials'),
              mode: LaunchMode.externalApplication,
            ),
          ),
        ),
        const SizedBox(height: 14),
        _label('Идентификатор клиента', p),
        NxField(controller: _clientId, hint: '…apps.googleusercontent.com'),
        const SizedBox(height: 12),
        _label('Секрет клиента', p),
        NxField(controller: _clientSecret, hint: 'GOCSPX-…', obscure: true),
        const SizedBox(height: 8),
        Text(
          'Пока приложение в Cloud Console не опубликовано, Google считает '
          'разрешение временным и просит войти заново примерно раз в неделю.',
          style: NxType.caption.copyWith(color: p.faint, fontSize: 10.5, height: 1.4),
        ),
      ] else
        Text(
          'Разрешение выдаётся в браузере: выберите учётную запись Google и '
          'подтвердите доступ к Диску.',
          style: NxType.bodyText.copyWith(color: p.sub, fontSize: 12.5, height: 1.5),
        ),
      if (_error != null) ...[
        const SizedBox(height: 12),
        _errorBox(),
      ],
      const SizedBox(height: 18),
      Row(children: [
        if (_clientReady)
          NxGhostButton(
            label: 'Изменить клиента',
            icon: Icons.tune_rounded,
            onTap: _busy ? null : () => setState(() => _clientReady = false),
          ),
        const Spacer(),
        NxGhostButton(
          label: 'Отмена',
          onTap: _busy ? null : () => Navigator.of(context).pop(false),
        ),
        const SizedBox(width: 10),
        if (_clientReady)
          GradientButton(
            label: _busy ? 'Открываем…' : 'Войти через браузер',
            onTap: _busy ? null : _connectGoogle,
          )
        else
          GradientButton(label: 'Сохранить', onTap: _busy ? null : _saveGoogleClient),
      ]),
    ]);
  }

  Widget _errorBox() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: NxPalette.danger.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(NxRadius.tile),
        border: Border.all(color: NxPalette.danger.withValues(alpha: 0.45)),
      ),
      child: Text(_error!,
          style: NxType.bodyText.copyWith(
              color: NxPalette.danger, fontSize: 12, height: 1.4)),
    );
  }

  Widget _waiting(NxThemeData t, NxPalette p) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: t.accent.a2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Ждём подтверждения в браузере. Разрешите доступ на открывшейся '
                'странице — окно закроется само.',
                style: NxType.bodyText.copyWith(color: p.sub, fontSize: 12.5, height: 1.45),
              ),
            ),
          ]),
          const SizedBox(height: 20),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            NxGhostButton(label: 'Отменить', onTap: _cancelFlow),
          ]),
        ],
      );

  Widget _form(NxThemeData t, NxPalette p) {
    final fixed = provider.fixedServer;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (fixed == null) ...[
          _label('Адрес сервера', p),
          NxField(controller: _server, hint: 'cloud.example.com'),
          const SizedBox(height: 12),
        ] else ...[
          Text('Адрес: ${fixed.host}',
              style: NxType.numeric.copyWith(color: p.faint, fontSize: 11)),
          const SizedBox(height: 12),
        ],
        _label('Логин', p),
        NxField(controller: _login, hint: provider == CloudProvider.yandex
            ? 'имя на Яндексе'
            : 'имя пользователя'),
        const SizedBox(height: 12),
        _label('Пароль приложения', p),
        NxField(controller: _password, hint: '••••••••', obscure: true),
        const SizedBox(height: 6),
        Text(
          provider.passwordHint,
          style: NxType.caption.copyWith(color: p.faint, fontSize: 10.5, height: 1.4),
        ),
        if (fixed == null) ...[
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: Text('Доверять сертификату сервера',
                  style: NxType.bodyText.copyWith(color: p.body, fontSize: 12.5)),
            ),
            NxToggle(
              value: _trustCertificate,
              onChanged: (v) => setState(() => _trustCertificate = v),
            ),
          ]),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          _errorBox(),
        ],
        const SizedBox(height: 18),
        Row(children: [
          if (provider.hasBrowserLogin)
            NxGhostButton(
              label: 'Через браузер',
              icon: Icons.open_in_browser_rounded,
              onTap: _busy ? null : _connectViaBrowser,
            ),
          const Spacer(),
          NxGhostButton(
            label: 'Отмена',
            onTap: _busy ? null : () => Navigator.of(context).pop(false),
          ),
          const SizedBox(width: 10),
          GradientButton(
            label: _busy ? 'Проверяем…' : 'Подключить',
            onTap: _busy ? null : _connect,
          ),
        ]),
      ],
    );
  }

  Widget _label(String text, NxPalette p) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: NxType.label.copyWith(color: p.sub, fontSize: 11.5)),
      );
}
