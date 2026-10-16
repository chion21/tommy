import 'package:http/http.dart' as http;

enum KeyCheck { valid, invalid, network }

/// Asks Google whether an AI Studio key works (lists models — free, no tokens used).
Future<KeyCheck> checkGeminiKey(String key) async {
  final k = key.trim();
  if (k.length < 20 || k.contains(' ')) return KeyCheck.invalid;
  try {
    final r = await http
        .get(Uri.parse('https://generativelanguage.googleapis.com/v1beta/models?pageSize=1&key=$k'))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode == 200) return KeyCheck.valid;
    if (r.statusCode == 400 || r.statusCode == 401 || r.statusCode == 403) return KeyCheck.invalid;
    return KeyCheck.network;
  } catch (_) {
    return KeyCheck.network;
  }
}

String maskKey(String k) => k.length <= 8 ? '••••' : '${k.substring(0, 4)}••••••••${k.substring(k.length - 4)}';
