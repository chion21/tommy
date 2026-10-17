import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../widgets/orb.dart';

/// Phone number or email + password (works without a server), Google (coming soon), forgot password.
class LoginScreen extends StatefulWidget {
  final AppState app;
  const LoginScreen({super.key, required this.app});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController(); // phone number or email
  final _pass = TextEditingController();
  final _name = TextEditingController();
  bool _register = false, _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = widget.app.err(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgot() async {
    final app = widget.app;
    final ctrl = TextEditingController(text: _email.text);
    final email = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(app.t('forgot')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(app.t('forgot_hint')),
          TextField(controller: ctrl, keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(labelText: app.t('email'))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(app.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, ctrl.text), child: Text(app.t('send'))),
        ],
      ),
    );
    if (email == null || email.trim().isEmpty) return;
    await _run(() async {
      await app.sendReset(email);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(app.t('reset_sent'))));
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final c = app.theme.primary;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Center(child: CrystalOrb(color: c, state: VoiceState.idle, size: 150)),
              const SizedBox(height: 8),
              if (_register) TextField(controller: _name, decoration: InputDecoration(labelText: app.t('your_name'))),
              TextField(controller: _email, decoration: InputDecoration(labelText: app.t('phone_or_email')),
                  keyboardType: TextInputType.emailAddress),
              TextField(controller: _pass, decoration: InputDecoration(labelText: app.t('password')), obscureText: true),
              if (!_register)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(onPressed: _busy ? null : _forgot, child: Text(app.t('forgot'))),
                ),
              const SizedBox(height: 8),
              if (_error != null)
                Padding(padding: const EdgeInsets.only(bottom: 8),
                    child: Text(_error!, style: const TextStyle(color: Colors.redAccent), textAlign: TextAlign.center)),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _run(() => _register
                        ? app.register(_email.text, _pass.text, _name.text)
                        : app.login(_email.text, _pass.text)),
                child: Text(_register ? app.t('register') : app.t('login')),
              ),
              TextButton(
                onPressed: () => setState(() => _register = !_register),
                child: Text(_register ? app.t('have_account') : app.t('no_account')),
              ),
              Row(children: [
                const Expanded(child: Divider()),
                Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Text(app.t('or'))),
                const Expanded(child: Divider()),
              ]),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _run(app.loginGoogle),
                icon: const Text('G', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
                label: Text(app.t('google')),
              ),
              if (_busy) const Padding(padding: EdgeInsets.all(8), child: Center(child: CircularProgressIndicator())),
            ]),
          ),
        ),
      ),
    );
  }
}
