import 'package:flutter/material.dart';

import 'api.dart';
import 'strings.dart';
import 'themes.dart';

enum VoiceState { idle, listening, thinking, speaking }

/// Everything the UI needs, in one place. Screens listen to it with ListenableBuilder.
class AppState extends ChangeNotifier {
  final api = Api();

  bool ready = false;
  bool loggedIn = false;
  Map<String, dynamic> me = {};
  Map<String, dynamic> assistant = {
    'name': 'টমি',
    'theme': 'crimson',
    'voice': 'aoede',
    'ui_language': 'bn',
    'speech_language': 'auto',
    'renames_left': 5,
  };
  VoiceState voice = VoiceState.idle;

  String get lang => (assistant['ui_language'] ?? 'bn') as String;
  String get name => (assistant['name'] ?? 'টমি') as String;
  String get userName => ((me['display_name'] as String?)?.isNotEmpty ?? false) ? me['display_name'] as String : '';
  TommyTheme get theme => themeById((assistant['theme'] ?? 'crimson') as String);

  String t(String key, {Map<String, String> vars = const {}}) =>
      tr(lang, key, vars: {'name': name, 'user': userName, ...vars});

  String err(Object e) => e is ApiError ? trError(lang, e.code, e.message) : e.toString();

  Future<void> init() async {
    loggedIn = await api.restore();
    if (loggedIn) await refresh();
    ready = true;
    notifyListeners();
  }

  Future<void> refresh() async {
    try {
      me = await api.me();
      assistant = await api.assistant();
    } on ApiError catch (e) {
      if (e.status == 401) {
        await api.clear();
        loggedIn = false;
      }
    }
    notifyListeners();
  }

  Future<void> login(String login, String password, {bool replace = false}) async {
    await api.login(login, password, replace: replace);
    loggedIn = true;
    await refresh();
  }

  Future<void> logout() async {
    await api.logout();
    loggedIn = false;
    notifyListeners();
  }

  Future<void> setPref(String key, String value) async {
    assistant = {...assistant, key: value}; // instant UI update
    notifyListeners();
    assistant = await api.updatePrefs({key: value});
    notifyListeners();
  }

  Future<void> rename(String newName) async {
    assistant = await api.rename(newName);
    notifyListeners();
  }

  void setVoice(VoiceState s) {
    voice = s;
    notifyListeners();
  }
}
