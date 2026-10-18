import 'brain.dart';
import 'native.dart';
import 'tools.dart';

/// Carries out what the (classic, non-Live) brain decided. Returns false if it could not.
Future<bool> runAction(BrainReply r) async {
  final arg = r.arg.trim();
  switch (r.action) {
    case 'youtube': // plays the first matching video directly
      return (await runDeviceTool('play_youtube', {'query': arg}))['ok'] == true;
    case 'web_search':
      return openUrl('https://www.google.com/search?q=${Uri.encodeQueryComponent(arg)}');
    case 'open_url':
      return arg.startsWith('http') ? openUrl(arg) : openUrl('https://$arg');
    case 'call':
      return (await runDeviceTool('phone_call', {'who': arg}))['ok'] == true;
    case 'whatsapp':
      final num = arg.replaceAll(RegExp(r'[^0-9]'), '');
      if (num.isEmpty) return openUrl('https://wa.me/?text=${Uri.encodeQueryComponent(r.text)}');
      return (await runDeviceTool('send_whatsapp', {'to': num, 'message': r.text}))['ok'] == true;
    case 'answer_call':
      return Native.answerCall();
    case 'reject_call':
      return Native.endCall();
    case 'open_app':
      return openAppByName(arg);
    default:
      return true;
  }
}
