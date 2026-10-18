import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'config.dart';

/// Logged-in person. uid decides which local folder holds their data.
class Session {
  final String uid;
  final String email;
  final String displayName;
  final String provider; // password | google | offline
  final String refreshToken;
  const Session({required this.uid, required this.email, required this.displayName, required this.provider,
      this.refreshToken = ''});

  Map<String, dynamic> toJson() =>
      {'uid': uid, 'email': email, 'displayName': displayName, 'provider': provider, 'refreshToken': refreshToken};

  factory Session.fromJson(Map<String, dynamic> j) => Session(
      uid: j['uid'] as String,
      email: (j['email'] ?? '') as String,
      displayName: (j['displayName'] ?? '') as String,
      provider: (j['provider'] ?? 'password') as String,
      refreshToken: (j['refreshToken'] ?? '') as String);
}

class AuthError implements Exception {
  final String code; // stable code, translated in strings.dart
  AuthError(this.code);
  @override
  String toString() => code;
}

/// Accounts saved on this device (phone number or email + password). Passwords are stored only as salted hashes.
/// Used until online accounts (Firebase / own server) are switched on.
class LocalAccounts {
  Future<File> _file() async {
    final d = await getApplicationSupportDirectory();
    return File('${d.path}${Platform.pathSeparator}accounts.json');
  }

  Future<Map<String, dynamic>> _read() async {
    final f = await _file();
    if (!await f.exists()) return {};
    try {
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  static String norm(String login) => login.trim().toLowerCase().replaceAll(' ', '');
  static String _hash(String salt, String pass) => sha256.convert(utf8.encode('$salt:$pass')).toString();
  static String uidFor(String login) => 'dev_${sha256.convert(utf8.encode(norm(login))).toString().substring(0, 20)}';

  Future<Session> register(String login, String password, String name) async {
    final l = norm(login);
    if (l.length < 5) throw AuthError('INVALID_LOGIN');
    if (password.length < 6) throw AuthError('WEAK_PASSWORD');
    final all = await _read();
    if (all.containsKey(l)) throw AuthError('EMAIL_EXISTS');
    final rnd = Random.secure();
    final salt = base64UrlEncode(List.generate(16, (_) => rnd.nextInt(256)));
    all[l] = {'salt': salt, 'hash': _hash(salt, password), 'name': name.trim(), 'uid': uidFor(l)};
    await (await _file()).writeAsString(jsonEncode(all));
    return Session(uid: uidFor(l), email: l, displayName: name.trim(), provider: 'device');
  }

  /// Forgot password for an account on this device: set a new one (the person has the device in hand).
  Future<Session> resetPassword(String login, String newPassword) async {
    final l = norm(login);
    if (newPassword.length < 6) throw AuthError('WEAK_PASSWORD');
    final all = await _read();
    final a = all[l] as Map<String, dynamic>?;
    if (a == null) throw AuthError('EMAIL_NOT_FOUND');
    final rnd = Random.secure();
    final salt = base64UrlEncode(List.generate(16, (_) => rnd.nextInt(256)));
    all[l] = {...a, 'salt': salt, 'hash': _hash(salt, newPassword)};
    await (await _file()).writeAsString(jsonEncode(all));
    return Session(uid: a['uid'] as String, email: l, displayName: (a['name'] ?? '') as String, provider: 'device');
  }

  Future<bool> exists(String login) async => (await _read()).containsKey(norm(login));

  Future<Session> login(String login, String password) async {
    final l = norm(login);
    final a = (await _read())[l] as Map<String, dynamic>?;
    if (a == null) throw AuthError('EMAIL_NOT_FOUND');
    if (_hash(a['salt'] as String, password) != a['hash']) throw AuthError('INVALID_PASSWORD');
    return Session(uid: a['uid'] as String, email: l, displayName: (a['name'] ?? '') as String, provider: 'device');
  }
}

/// Accounts through Firebase Authentication's REST API — no server of our own needed.
class Auth {
  final local = LocalAccounts();

  static const _base = 'https://identitytoolkit.googleapis.com/v1/accounts';

  Future<Map<String, dynamic>> _post(String method, Map<String, dynamic> body) async {
    if (!AppConfig.accountsEnabled) throw AuthError('ACCOUNTS_OFF');
    http.Response r;
    try {
      r = await http
          .post(Uri.parse('$_base:$method?key=${AppConfig.firebaseApiKey}'),
              headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      throw AuthError('NETWORK');
    }
    final data = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    if (r.statusCode >= 400) {
      final msg = ((data['error'] as Map?)?['message'] ?? 'ERROR').toString();
      throw AuthError(msg.split(' ').first.split(':').first.trim());
    }
    return data;
  }

  Session _session(Map<String, dynamic> d, String provider, {String? name}) => Session(
        uid: d['localId'] as String,
        email: (d['email'] ?? '') as String,
        displayName: name ?? (d['displayName'] ?? d['fullName'] ?? '') as String,
        provider: provider,
        refreshToken: (d['refreshToken'] ?? '') as String,
      );

  /// Online (Firebase) when it is set up and the login is an email; otherwise an account on this device.
  bool _online(String login) => AppConfig.accountsEnabled && login.contains('@');

  Future<Session> register(String login, String password, String name) async {
    if (!_online(login)) return local.register(login, password, name);
    final email = login;
    final d = await _post('signUp', {'email': email.trim(), 'password': password, 'returnSecureToken': true});
    if (name.trim().isNotEmpty) {
      await _post('update', {'idToken': d['idToken'], 'displayName': name.trim(), 'returnSecureToken': false});
    }
    return _session(d, 'password', name: name.trim());
  }

  Future<Session> login(String login, String password) async {
    if (!_online(login)) return local.login(login, password);
    final email = login;
    final d = await _post('signInWithPassword', {'email': email.trim(), 'password': password, 'returnSecureToken': true});
    return _session(d, 'password');
  }

  Future<void> sendPasswordReset(String email) async {
    if (!_online(email)) throw AuthError('RESET_OFF');
    await _post('sendOobCode', {'requestType': 'PASSWORD_RESET', 'email': email.trim()});
  }

  /// Google: Android uses the system account picker; Windows opens the browser.
  Future<Session> google() async {
    if (!AppConfig.accountsEnabled) throw AuthError('GOOGLE_OFF');
    final idToken = Platform.isAndroid ? await _googleAndroid() : await _googleDesktop();
    final d = await _post('signInWithIdp', {
      'postBody': 'id_token=$idToken&providerId=google.com',
      'requestUri': 'http://localhost',
      'returnSecureToken': true,
      'returnIdpCredential': true,
    });
    return _session(d, 'google');
  }

  Future<String> _googleAndroid() async {
    if (AppConfig.googleWebClientId.isEmpty) throw AuthError('GOOGLE_OFF');
    final g = GoogleSignIn.instance;
    await g.initialize(serverClientId: AppConfig.googleWebClientId);
    final account = await g.authenticate();
    final token = account.authentication.idToken;
    if (token == null) throw AuthError('GOOGLE_FAILED');
    return token;
  }

  /// Standard "loopback" sign-in for desktop apps: browser → 127.0.0.1 → code → id_token.
  Future<String> _googleDesktop() async {
    if (AppConfig.googleDesktopClientId.isEmpty) throw AuthError('GOOGLE_OFF');
    final rnd = Random.secure();
    final verifier = base64UrlEncode(List.generate(48, (_) => rnd.nextInt(256))).replaceAll('=', '');
    final challenge = base64UrlEncode(sha256.convert(utf8.encode(verifier)).bytes).replaceAll('=', '');
    final state = base64UrlEncode(List.generate(16, (_) => rnd.nextInt(256))).replaceAll('=', '');

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirect = 'http://127.0.0.1:${server.port}';
    try {
      final url = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
        'client_id': AppConfig.googleDesktopClientId,
        'redirect_uri': redirect,
        'response_type': 'code',
        'scope': 'openid email profile',
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': state,
        'prompt': 'select_account',
      });
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) throw AuthError('GOOGLE_FAILED');

      final req = await server.first.timeout(const Duration(minutes: 3), onTimeout: () => throw AuthError('GOOGLE_FAILED'));
      final code = req.uri.queryParameters['code'];
      final ok = code != null && req.uri.queryParameters['state'] == state;
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write('<html><body style="font-family:sans-serif;background:#111;color:#eee;text-align:center;padding-top:80px">'
            '<h2>${ok ? '✅ Signed in — you can close this tab and return to Tommy.' : '❌ Sign-in failed'}</h2></body></html>');
      await req.response.close();
      if (!ok) throw AuthError('GOOGLE_FAILED');

      final r = await http.post(Uri.parse('https://oauth2.googleapis.com/token'), body: {
        'code': code,
        'client_id': AppConfig.googleDesktopClientId,
        'client_secret': AppConfig.googleDesktopClientSecret,
        'redirect_uri': redirect,
        'grant_type': 'authorization_code',
        'code_verifier': verifier,
      });
      final token = (jsonDecode(r.body) as Map<String, dynamic>)['id_token'] as String?;
      if (token == null) throw AuthError('GOOGLE_FAILED');
      return token;
    } finally {
      await server.close(force: true);
    }
  }

  Future<void> signOutGoogle() async {
    if (Platform.isAndroid) {
      try {
        await GoogleSignIn.instance.signOut();
      } catch (_) {}
    }
  }
}
