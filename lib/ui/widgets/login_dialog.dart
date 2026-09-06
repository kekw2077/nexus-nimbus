import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_state.dart';
import '../../core/models/cloud_provider.dart';
import '../../services/google/google_auth.dart';
import '../../services/login_flow.dart';
import '../../services/oauth/loopback.dart';
import '../../services/webdav_client.dart';
import '../../services/yandex/yandex_auth.dart';
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
          width: 420,
          child: GlassPanel(
            radius: NxRadius.card,
            padding: const EdgeInsets.all(20),
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

  /// Учётные данные приложения у облака с OAuth. Вводятся один раз и живут
  /// в настройках, но без них вход не начать — поэтому поля показываются
  /// прямо здесь, пока они пусты.
  final _clientId = TextEditingController();
  final _clientSecret = TextEditingController();

  /// Код, который Яндекс показывает на своей странице после разрешения.
  /// Ловить его приёмником нельзя: адрес возврата у приложения постоянный.
  final _code = TextEditingController();
  bool _codeWanted = false;

  bool _trustCertificate = false;
  bool _busy = false;
  String? _error;
  bool _clientReady = false;

  /// Ожидание браузера: у Nextcloud свой поток, у OAuth — общий приёмник.
  LoginFlow? _flow;
  CancelToken? _flowCancel;
  CancelableWait? _oauthWait;

  CloudProvider get provider => widget.provider;

  @override
  void initState() {
    super.initState();
    if (provider == CloudProvider.google) {
      final saved = widget.app.googleClient;
      _clientId.text = saved.id;
      _clientSecret.text = saved.secret;
      _clientReady = !saved.isEmpty;
    } else if (provider == CloudProvider.yandex) {
      final saved = widget.app.yandexClient;
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
    _code.dispose();
    _flowCancel?.cancel();
    _flow?.dispose();
    _oauthWait?.cancel();
    super.dispose();
  }

  // --------------------------------------------------------------- OAuth

  Future<void> _saveClient() async {
    final id = _clientId.text.trim();
    final secret = _clientSecret.text.trim();
    if (id.isEmpty || secret.isEmpty) {
      setState(() => _error = 'Нужны и идентификатор, и секрет приложения');
      return;
    }

    if (provider == CloudProvider.yandex) {
      await widget.app.saveYandexClient(id, secret);
    } else {
      await widget.app.saveGoogleClient(id, secret);
    }

    if (mounted) {
      setState(() {
        _clientReady = true;
        _error = null;
      });
    }
  }

  /// Яндекс: отправляем за разрешением и ждём, пока код перенесут в поле.
  Future<void> _askYandexCode() async {
    final auth = YandexAuth(widget.app.yandexClient);
    try {
      await launchUrl(auth.authorizeUrl, mode: LaunchMode.externalApplication);
      if (mounted) {
        setState(() {
          _codeWanted = true;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      auth.close();
    }
  }

  Future<void> _connectYandex() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    final auth = YandexAuth(widget.app.yandexClient);
    try {
      final granted = await auth.exchange(_code.text);
      await widget.app.connect(NxAccount(
        baseUrl: provider.fixedServer!,
        loginName: granted.login,
        // Токен ложится туда же, где у прочих облаков пароль приложения:
        // в защищённое хранилище системы.
        appPassword: granted.token,
        provider: provider,
      ));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      auth.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Google: код ловит приёмник на локальном адресе — Google любой порт
  /// принимает, и переносить руками ничего не нужно.
  Future<void> _connectGoogle() async {
    final wait = CancelableWait();
    setState(() {
      _busy = true;
      _error = null;
      _oauthWait = wait;
    });

    final auth = GoogleAuth(widget.app.googleClient);
    try {
      final granted = await auth.authorize(
        onUrl: (url) => launchUrl(url, mode: LaunchMode.externalApplication),
        cancel: wait,
      );
      if (granted == null) {
        _timedOut(wait);
        return;
      }
      await widget.app.connect(NxAccount(
        baseUrl: provider.fixedServer!,
        loginName: granted.email,
        appPassword: granted.refreshToken,
        provider: provider,
      ));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      auth.close();
      if (mounted) {
        setState(() {
          _busy = false;
          _oauthWait = null;
        });
      }
    }
  }

  void _timedOut(CancelableWait wait) {
    if (!mounted) return;
    setState(() => _error = wait.isCancelled ? null : 'Время на вход истекло');
  }

  void _cancelOAuth() {
    _oauthWait?.cancel();
    setState(() {
      _oauthWait = null;
      _busy = false;
    });
  }

  // ----------------------------------------------------------- пароль и DAV

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

  // ---------------------------------------------------------------- сборка

  @override
  Widget build(BuildContext context) {
    final t = NxTheme.of(context);
    final p = t.palette;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Вход в ${provider.label}',
            style: NxType.title.copyWith(color: p.txt, fontSize: 16.5)),
        const SizedBox(height: 13),
        if (provider.needsOAuth)
          _oauth(t, p)
        else if (_flow != null)
          _waiting(t, p, 'Ждём подтверждения в браузере. Разрешите доступ на '
              'открывшейся странице — окно закроется само.', _cancelFlow)
        else
          _form(t, p),
      ],
    );
  }

  Widget _oauth(NxThemeData t, NxPalette p) {
    if (_oauthWait != null) {
      return _waiting(t, p, 'Ждём разрешения в браузере. Выберите учётную '
          'запись и разрешите доступ — окно закроется само.', _cancelOAuth);
    }

    final yandex = provider == CloudProvider.yandex;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (!_clientReady) ...[
        Text(
          yandex
              ? 'WebDAV Яндекс оставил платным подпискам, поэтому работаем '
                  'по их API — а он ходит по разрешению из браузера. Выданному '
                  'приложению, которое надо один раз зарегистрировать.'
              : 'Google не пускает к Диску по паролю — только через разрешение '
                  'в браузере, и только приложению, которое он знает.',
          style: NxType.bodyText.copyWith(color: p.sub, fontSize: 12, height: 1.45),
        ),
        const SizedBox(height: 9),
        Align(
          alignment: Alignment.centerLeft,
          child: NxGhostButton(
            label: yandex ? 'Зарегистрировать приложение' : 'Открыть Cloud Console',
            icon: Icons.open_in_new_rounded,
            onTap: () => launchUrl(Uri.parse(provider.consoleUrl),
                mode: LaunchMode.externalApplication),
          ),
        ),
        if (yandex) ...[
          const SizedBox(height: 9),
          Text(
            'Там нужны права «Яндекс.Диск: чтение и запись» и «Доступ к логину». '
            'Redirect URI менять не нужно — подойдёт тот, что Яндекс подставил сам.',
            style: NxType.caption.copyWith(color: p.faint, fontSize: 10.5, height: 1.4),
          ),
        ],
        const SizedBox(height: 13),
        _label('Идентификатор приложения', p),
        NxField(controller: _clientId,
            hint: yandex ? '32 знака' : '…apps.googleusercontent.com'),
        const SizedBox(height: 11),
        _label('Пароль приложения', p),
        NxField(controller: _clientSecret, hint: '••••••••', obscure: true),
        if (!yandex) ...[
          const SizedBox(height: 8),
          Text(
            'Пока приложение в Cloud Console не опубликовано, Google просит '
            'входить заново примерно раз в неделю.',
            style: NxType.caption.copyWith(color: p.faint, fontSize: 10.5, height: 1.4),
          ),
        ],
      ] else if (yandex && _codeWanted) ...[
        Text(
          'На странице Яндекса разрешите доступ — он покажет короткий код. '
          'Перенесите его сюда.',
          style: NxType.bodyText.copyWith(color: p.sub, fontSize: 12.5, height: 1.45),
        ),
        const SizedBox(height: 12),
        _label('Код подтверждения', p),
        NxField(controller: _code, hint: 'семь цифр со страницы'),
      ] else
        Text(
          yandex
              ? 'Разрешение выдаётся в браузере: подтвердите доступ к Диску, '
                  'а показанный код перенесите обратно сюда.'
              : 'Разрешение выдаётся в браузере: выберите учётную запись Google '
                  'и подтвердите доступ к Диску.',
          style: NxType.bodyText.copyWith(color: p.sub, fontSize: 12.5, height: 1.45),
        ),
      if (_error != null) ...[
        const SizedBox(height: 11),
        _errorBox(),
      ],
      const SizedBox(height: 16),
      Row(children: [
        if (_clientReady && !_codeWanted)
          NxGhostButton(
            label: 'Изменить',
            icon: Icons.tune_rounded,
            onTap: _busy ? null : () => setState(() => _clientReady = false),
          ),
        if (_codeWanted)
          NxGhostButton(
            label: 'Открыть снова',
            icon: Icons.open_in_new_rounded,
            onTap: _busy ? null : _askYandexCode,
          ),
        const Spacer(),
        NxGhostButton(
          label: 'Отмена',
          onTap: _busy ? null : () => Navigator.of(context).pop(false),
        ),
        const SizedBox(width: 9),
        if (!_clientReady)
          GradientButton(label: 'Сохранить', onTap: _busy ? null : _saveClient)
        else if (_codeWanted)
          GradientButton(
            label: _busy ? 'Проверяем…' : 'Подключить',
            onTap: _busy ? null : _connectYandex,
          )
        else
          GradientButton(
            label: _busy ? 'Открываем…' : 'Войти через браузер',
            onTap: _busy ? null : (yandex ? _askYandexCode : _connectGoogle),
          ),
      ]),
    ]);
  }

  Widget _waiting(NxThemeData t, NxPalette p, String text, VoidCallback onCancel) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: t.accent.a2),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text,
                style: NxType.bodyText.copyWith(
                    color: p.sub, fontSize: 12.5, height: 1.45)),
          ),
        ]),
        const SizedBox(height: 18),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          NxGhostButton(label: 'Отменить', onTap: onCancel),
        ]),
      ]);

  Widget _form(NxThemeData t, NxPalette p) {
    final fixed = provider.fixedServer;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (fixed == null) ...[
        _label('Адрес сервера', p),
        NxField(controller: _server, hint: 'cloud.example.com'),
        const SizedBox(height: 11),
      ],
      _label('Логин', p),
      NxField(controller: _login, hint: provider.loginHint),
      const SizedBox(height: 11),
      _label('Пароль приложения', p),
      NxField(controller: _password, hint: '••••••••', obscure: true),
      const SizedBox(height: 6),
      Text(
        provider.passwordHint,
        style: NxType.caption.copyWith(color: p.faint, fontSize: 10.5, height: 1.4),
      ),
      if (fixed == null) ...[
        const SizedBox(height: 11),
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
        const SizedBox(height: 11),
        _errorBox(),
      ],
      const SizedBox(height: 16),
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
        const SizedBox(width: 9),
        GradientButton(
          label: _busy ? 'Проверяем…' : 'Подключить',
          onTap: _busy ? null : _connect,
        ),
      ]),
    ]);
  }

  Widget _errorBox() => Container(
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

  Widget _label(String text, NxPalette p) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: NxType.label.copyWith(color: p.sub, fontSize: 11.5)),
      );
}
