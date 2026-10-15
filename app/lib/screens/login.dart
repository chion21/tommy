import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/app_state.dart';
import '../widgets/orb.dart';

class LoginScreen extends StatefulWidget {
  final AppState app;
  const LoginScreen({super.key, required this.app});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _login = TextEditingController();
  final _pass = TextEditingController();
  final _name = TextEditingController();
  late final _server = TextEditingController(text: widget.app.api.baseUrl);
  bool _register = false, _busy = false;
  String? _error;

  Future<void> _submit({bool replace = false}) async {
    final app = widget.app;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await app.api.setServer(_server.text);
      if (_register && !replace) await app.api.register(_login.text, _pass.text, _name.text);
      await app.login(_login.text, _pass.text, replace: replace);
    } on ApiError catch (e) {
      if (e.code == 'DEVICE_LIMIT' && mounted) {
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            content: Text(app.t('replace_device_q')),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: Text(app.t('no'))),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(app.t('yes'))),
            ],
          ),
        );
        if (ok == true) return _submit(replace: true);
      } else {
        setState(() => _error = app.err(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              CrystalOrb(color: app.theme.primary, state: VoiceState.idle, size: 160),
              const SizedBox(height: 12),
              if (_register)
                TextField(controller: _name, decoration: InputDecoration(labelText: app.t('your_name'))),
              TextField(controller: _login, decoration: InputDecoration(labelText: app.t('phone_or_email')),
                  keyboardType: TextInputType.emailAddress),
              TextField(controller: _pass, decoration: InputDecoration(labelText: app.t('password')), obscureText: true),
              TextField(controller: _server, decoration: InputDecoration(labelText: app.t('server'),
                  hintText: 'https://xxxx.trycloudflare.com'), keyboardType: TextInputType.url),
              const SizedBox(height: 16),
              if (_error != null) Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: Text(_register ? app.t('register') : app.t('login')),
                ),
              ),
              TextButton(
                onPressed: () => setState(() => _register = !_register),
                child: Text(_register ? app.t('login') : app.t('register')),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
