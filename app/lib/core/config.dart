/// Values filled in at build time from GitHub repository variables (Settings → Variables).
/// None of these are secrets: they only identify the app to Google/Firebase.
class AppConfig {
  /// Firebase project "Web API key" (Project settings → General).
  static const firebaseApiKey = String.fromEnvironment('FIREBASE_API_KEY');

  /// Google OAuth "Web client" id (used by Android Google sign-in).
  static const googleWebClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');

  /// Google OAuth "Desktop app" client id + secret (used by the Windows browser sign-in).
  /// Google treats desktop client secrets as non-confidential.
  static const googleDesktopClientId = String.fromEnvironment('GOOGLE_DESKTOP_CLIENT_ID');
  static const googleDesktopClientSecret = String.fromEnvironment('GOOGLE_DESKTOP_CLIENT_SECRET');

  static bool get accountsEnabled => firebaseApiKey.isNotEmpty;
}
