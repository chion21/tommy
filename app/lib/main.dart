import 'package:flutter/material.dart';

import 'core/app_state.dart';
import 'core/themes.dart';
import 'screens/login.dart';
import 'screens/shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final app = AppState()..init();
  runApp(TommyApp(app: app));
}

class TommyApp extends StatelessWidget {
  final AppState app;
  const TommyApp({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => MaterialApp(
        title: app.name,
        debugShowCheckedModeBanner: false,
        theme: materialThemeFor(app.theme),
        home: !app.ready
            ? const Scaffold(body: Center(child: CircularProgressIndicator()))
            : app.loggedIn
                ? Shell(app: app)
                : LoginScreen(app: app),
      ),
    );
  }
}
