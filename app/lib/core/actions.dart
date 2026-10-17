import 'dart:io';

import 'package:url_launcher/url_launcher.dart';

import 'brain.dart';
import 'native.dart';

/// Carries out what the brain decided. Returns false if it could not.
Future<bool> runAction(BrainReply r) async {
  final arg = r.arg.trim();
  Future<bool> open(String url) async {
    try {
      return await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  switch (r.action) {
    case 'youtube':
      return open('https://www.youtube.com/results?search_query=${Uri.encodeQueryComponent(arg)}');
    case 'web_search':
      return open('https://www.google.com/search?q=${Uri.encodeQueryComponent(arg)}');
    case 'open_url':
      return arg.startsWith('http') ? open(arg) : open('https://$arg');
    case 'call':
      final num = arg.replaceAll(RegExp(r'[^0-9+]'), '');
      return num.isEmpty ? false : open('tel:$num');
    case 'whatsapp':
      final num = arg.replaceAll(RegExp(r'[^0-9]'), '');
      final text = Uri.encodeQueryComponent(r.text);
      return open(num.isEmpty ? 'https://wa.me/?text=$text' : 'https://wa.me/$num?text=$text');
    case 'answer_call':
      return Native.answerCall();
    case 'reject_call':
      return Native.endCall();
    case 'open_app':
      return _openApp(arg);
    default:
      return true;
  }
}

Future<bool> _openApp(String name) async {
  final n = name.toLowerCase().trim();
  if (Platform.isAndroid) return Native.openApp(name);
  if (!Platform.isWindows) return false;
  const known = {
    'notepad': 'notepad',
    'calculator': 'calc',
    'calc': 'calc',
    'file explorer': 'explorer',
    'explorer': 'explorer',
    'files': 'explorer',
    'settings': 'ms-settings:',
    'paint': 'mspaint',
    'cmd': 'cmd',
    'command prompt': 'cmd',
    'task manager': 'taskmgr',
    'chrome': 'chrome',
    'edge': 'msedge',
    'whatsapp': 'whatsapp:',
    'spotify': 'spotify:',
    'camera': 'microsoft.windows.camera:',
    'word': 'winword',
    'excel': 'excel',
    'powerpoint': 'powerpnt',
  };
  const web = {
    'youtube': 'https://www.youtube.com',
    'facebook': 'https://www.facebook.com',
    'instagram': 'https://www.instagram.com',
    'gmail': 'https://mail.google.com',
    'messenger': 'https://www.messenger.com',
  };
  if (web.containsKey(n)) return launchUrl(Uri.parse(web[n]!), mode: LaunchMode.externalApplication);
  final target = known[n] ?? name;
  try {
    await Process.start('cmd', ['/c', 'start', '', target], mode: ProcessStartMode.detached);
    return true;
  } catch (_) {
    return false;
  }
}
