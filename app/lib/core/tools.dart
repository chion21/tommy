import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'native.dart';
import 'pc.dart';

/// Everything Tommy can *do*. Gemini Live calls these as functions; each returns a small result map
/// ({ok: true/false, ...}) so Tommy knows whether the job is really done — and if not, asks the person.

Map<String, dynamic> _fn(String name, String description, [Map<String, dynamic> props = const {}, List<String> required = const []]) => {
      'name': name,
      'description': description,
      if (props.isNotEmpty)
        'parameters': {
          'type': 'OBJECT',
          'properties': props,
          if (required.isNotEmpty) 'required': required,
        },
    };

const _device = {
  'type': 'STRING',
  'enum': ['here', 'pc', 'phone'],
  'description': 'Which device does it: "here" (default), or the linked "pc"/"phone" when the person says so.',
};
Map<String, dynamic> _s(String d) => {'type': 'STRING', 'description': d};

final toolDeclarations = <Map<String, dynamic>>[
  _fn('play_youtube', 'Find a video/song on YouTube and START PLAYING it directly (not just a search page).',
      {'query': _s('What to play, e.g. "Arijit Singh romantic song" or an exact song name.'), 'device': _device}, ['query']),
  _fn('search_youtube', 'Open YouTube search results (only when they want to browse/choose themselves).',
      {'query': _s('Search words'), 'device': _device}, ['query']),
  _fn('open_website', 'Open a website or web link.', {'url': _s('Full URL or domain'), 'device': _device}, ['url']),
  _fn('open_app', 'Open an installed app by its name.',
      {'name': _s('App name as shown on the device, e.g. WhatsApp, Facebook, Camera, Notepad'), 'device': _device}, ['name']),
  _fn('phone_call', 'Call someone. Give a saved contact name or a number. Calls immediately when allowed.',
      {'who': _s('Contact name or phone number')}, ['who']),
  _fn('send_whatsapp', 'Send a WhatsApp message. Confirm the text with the person first unless they dictated it exactly.',
      {
        'to': _s('Contact name or phone number (with country code if known)'),
        'message': _s('The message text'),
      },
      ['to', 'message']),
  _fn('answer_call', 'Answer the phone call that is ringing now.'),
  _fn('reject_call', 'Reject / end the phone call that is ringing now.'),
  _fn('research', 'Look something up on the web and get an accurate answer as bullet points. '
      'Use deep=true when they say "deep research"/"ভালো করে খোঁজো"/a detailed report.', {
    'question': _s('The full question, with all details they gave'),
    'deep': {'type': 'BOOLEAN', 'description': 'true = thorough multi-source report'},
  }, ['question']),
  _fn('remember', 'Save a long-term memory: a fact about the person, or a RULE/correction about how to do things next time.', {
    'fact': _s('Short fact or rule, e.g. "Likes Arijit Singh songs" or "When asked for music, play it directly on YouTube"'),
    'kind': {'type': 'STRING', 'enum': ['personal', 'rule']},
  }, ['fact']),
  _fn('update_memory', 'Correct an existing memory when the person says something you remember is wrong or changed.',
      {'old': _s('Words from the memory to change'), 'new': _s('The corrected memory')}, ['old', 'new']),
  _fn('forget', 'Delete a memory when the person asks you to forget it.', {'fact': _s('Words from the memory to delete')}, ['fact']),
  _fn('recall', 'Search ALL earlier conversations (older than what you see) for something the person asks about.',
      {'query': _s('Search words: names, topics (Bangla and English if useful)')}, ['query']),
  _fn('read_screen', 'See what is on the phone screen now (texts and buttons). Use it to continue a task step by step.'),
  _fn('tap', 'Press a button or item on the phone screen by its text.', {'target': _s('Text of the button/item')}, ['target']),
  _fn('type_text', 'Type text into the input box on the phone screen.', {'text': _s('Text to type')}, ['text']),
  _fn('press_key', 'Press a system key on the phone.', {
    'key': {'type': 'STRING', 'enum': ['back', 'home', 'recents', 'notifications']},
  }, ['key']),
  _fn('scroll', 'Scroll the phone screen.', {
    'direction': {'type': 'STRING', 'enum': ['up', 'down']},
  }, ['direction']),
  _fn('media_control', 'Pause/play/next/previous the music or video that is playing, or change the volume.', {
    'action': {'type': 'STRING', 'enum': ['pause', 'play', 'stop', 'next', 'previous', 'volume_up', 'volume_down', 'mute', 'unmute']},
    'device': _device,
  }, ['action']),
  _fn('close_app', 'Close an app/window, e.g. the YouTube that is playing a song. Stops its sound too.',
      {'name': _s('App or window name, e.g. YouTube, Chrome, Notepad'), 'device': _device}, ['name']),
  // ---- PC (Windows) ----
  _fn('list_windows', 'PC: list the open windows (app + title). Use it to see what is open before closing/focusing.',
      {'device': _device}),
  _fn('focus_window', 'PC: bring a window to the front (by part of its title or app name).',
      {'name': _s('Part of the window title or app name'), 'device': _device}, ['name']),
  _fn('look_at_screen', 'PC: take a screenshot and look at it — what is open, buttons, errors. Use it to check your work.',
      {'question': _s('What you want to know about the screen'), 'device': _device}, ['question']),
  _fn('click_on', 'PC: click a button/field/link that you can see on the screen (found by its description).',
      {'target': _s('e.g. "the Send button", "the chat input box in Antigravity"'), 'double': {'type': 'BOOLEAN'}, 'device': _device},
      ['target']),
  _fn('type_on_pc', 'PC: type text into the window in front (any language), optionally press Enter.',
      {'text': _s('Text to type'), 'enter': {'type': 'BOOLEAN'}, 'device': _device}, ['text']),
  _fn('press_keys_pc', 'PC: press keys in the window in front. SendKeys notation: ^=Ctrl %=Alt +=Shift, {ENTER} {TAB} {ESC} {F4}. '
      'e.g. "^s" save, "^t" new tab, "%{F4}" close window.', {'keys': _s('Keys'), 'device': _device}, ['keys']),
  _fn('run_command', 'PC: run a PowerShell command and get its output (e.g. ipconfig, git status, dir, python --version). '
      'Anything that deletes, uninstalls, downloads or shuts down needs the person\'s OK first: ask, then call again with confirmed=true.', {
    'command': _s('PowerShell command'),
    'confirmed': {'type': 'BOOLEAN', 'description': 'true only after the person said yes to a risky command'},
    'device': _device,
  }, ['command']),
  _fn('open_terminal', 'PC: open a visible terminal (PowerShell) window, optionally running a command in it.',
      {'command': _s('Command to run in the new terminal (can be empty)'), 'confirmed': {'type': 'BOOLEAN'}, 'device': _device}),
  _fn('create_sheet', 'Make a spreadsheet/table (e.g. names, addresses, phone numbers). Saves an Excel-compatible file; '
      'with google=true it also opens a new Google Sheet and pastes the table there.', {
    'title': _s('File / sheet name'),
    'columns': {'type': 'ARRAY', 'items': {'type': 'STRING'}, 'description': 'Column headings'},
    'rows': {'type': 'ARRAY', 'items': {'type': 'STRING'}, 'description': 'One string per row, cells separated by " | "'},
    'folder': _s('Where to save (folder path or name like Desktop, Documents, Downloads); empty = Documents/Tommy'),
    'google': {'type': 'BOOLEAN', 'description': 'Also put it in a new Google Sheet'},
    'device': _device,
  }, ['title', 'columns', 'rows']),
  _fn('stop_listening', 'The person wants you to stop listening / go quiet until they press the button again.'),
];

Map<String, dynamic> ok([Map<String, dynamic> extra = const {}]) => {'ok': true, ...extra};
Map<String, dynamic> fail(String why, [Map<String, dynamic> extra = const {}]) => {'ok': false, 'error': why, ...extra};

Future<bool> openUrl(String url) async {
  try {
    return await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// First YouTube video for a search (no API key needed). Returns (id, title) or null.
Future<(String, String)?> findYoutubeVideo(String query) async {
  try {
    final r = await http.get(
      Uri.parse('https://www.youtube.com/results?search_query=${Uri.encodeQueryComponent(query)}&hl=en'),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36',
        'Accept-Language': 'en-US,en;q=0.8,bn;q=0.6',
      },
    ).timeout(const Duration(seconds: 8));
    final html = utf8.decode(r.bodyBytes, allowMalformed: true);
    final m = RegExp(r'"videoRenderer":\{"videoId":"([\w-]{11})".{0,1500}?"title":\{"runs":\[\{"text":"((?:[^"\\]|\\.)*)"')
        .firstMatch(html);
    if (m != null) return (m.group(1)!, _unescape(m.group(2)!));
    final id = RegExp(r'"videoId":"([\w-]{11})"').firstMatch(html)?.group(1);
    return id == null ? null : (id, '');
  } catch (_) {
    return null;
  }
}

String _unescape(String s) {
  try {
    return jsonDecode('"$s"') as String;
  } catch (_) {
    return s;
  }
}

/// Device actions (the ones that don't need Tommy's memory or brain).
Future<Map<String, dynamic>> runDeviceTool(String name, Map<String, dynamic> a) async {
  String arg(String k) => (a[k] ?? '').toString().trim();
  switch (name) {
    case 'play_youtube':
      final q = arg('query');
      final v = await findYoutubeVideo(q);
      if (v == null) {
        final opened = await openUrl('https://www.youtube.com/results?search_query=${Uri.encodeQueryComponent(q)}');
        return opened
            ? fail('Could not pick a video automatically; opened the search page instead. Ask which one to play.')
            : fail('YouTube could not be opened.');
      }
      final played = await openUrl('https://www.youtube.com/watch?v=${v.$1}');
      return played ? ok({'playing': v.$2.isEmpty ? q : v.$2}) : fail('YouTube could not be opened.');
    case 'search_youtube':
      return await openUrl('https://www.youtube.com/results?search_query=${Uri.encodeQueryComponent(arg('query'))}')
          ? ok()
          : fail('YouTube could not be opened.');
    case 'open_website':
      final u = arg('url');
      return await openUrl(u.startsWith('http') ? u : 'https://$u') ? ok() : fail('Could not open $u');
    case 'open_app':
      return await openAppByName(arg('name')) ? ok() : fail('App "${arg('name')}" was not found on this device. Ask the exact name.');
    case 'phone_call':
      final who = arg('who');
      var number = who.replaceAll(RegExp(r'[^0-9+]'), '');
      var shown = who;
      if (number.length < 3) {
        if (!Platform.isAndroid) return fail('Calls work from the phone. Tell them to ask on the phone (or use device "phone").');
        final c = await Native.findContact(who);
        if (c == null || (c['number'] ?? '').isEmpty) {
          return fail('No saved contact named "$who" (or contacts permission is off). Ask for the number or the exact contact name.');
        }
        number = c['number']!;
        shown = c['name'] ?? who;
      }
      if (Platform.isAndroid) {
        final r = await Native.callNumber(number);
        if (r == 'calling') return ok({'calling': shown});
        if (r == 'dialer') return ok({'note': 'Dialer opened with the number; they need to press the call button (call permission is off).'});
        return fail('Could not start the call.');
      }
      return await openUrl('tel:$number') ? ok() : fail('Calls work from the phone.');
    case 'send_whatsapp':
      final to = arg('to');
      final msg = arg('message');
      var number = to.replaceAll(RegExp(r'[^0-9]'), '');
      if (number.length < 6 && Platform.isAndroid) {
        final c = await Native.findContact(to);
        number = (c?['number'] ?? '').replaceAll(RegExp(r'[^0-9]'), '');
        if (number.isEmpty) return fail('No saved contact named "$to". Ask for the number.');
      }
      if (number.startsWith('0') && number.length == 11) number = '88$number'; // Bangladesh local → international
      final autoSend = Platform.isAndroid && await Native.armAutoSend();
      final opened = await openUrl('https://wa.me/$number?text=${Uri.encodeQueryComponent(msg)}');
      if (!opened) return fail('WhatsApp could not be opened.');
      return autoSend
          ? ok({'note': 'Message is being sent automatically.'})
          : ok({'note': 'WhatsApp opened with the message typed; they must press Send (turn on Tommy hands in Settings to send automatically).'});
    case 'answer_call':
      return await Native.answerCall() ? ok() : fail('Could not answer (needs the phone-call permission).');
    case 'reject_call':
      return await Native.endCall() ? ok() : fail('Could not reject (needs the phone-call permission).');
    case 'read_screen':
      if (!Platform.isAndroid) return fail('Screen reading works on the phone only.');
      final s = await Native.screen();
      return s == null ? fail('Tommy hands (accessibility) is off. Ask them to turn it on in Settings → Tommy hands.') : ok(s);
    case 'tap':
      if (!await Native.handsOn()) return fail('Tommy hands (accessibility) is off. Ask them to turn it on in Settings.');
      return await Native.tap(arg('target')) ? ok() : fail('No "${arg('target')}" on the screen. Use read_screen to see what is there.');
    case 'type_text':
      if (!await Native.handsOn()) return fail('Tommy hands (accessibility) is off.');
      return await Native.typeText(arg('text')) ? ok() : fail('No input box on the screen.');
    case 'press_key':
      if (!await Native.handsOn()) return fail('Tommy hands (accessibility) is off.');
      return await Native.press(arg('key')) ? ok() : fail('Could not press ${arg('key')}.');
    case 'scroll':
      if (!await Native.handsOn()) return fail('Tommy hands (accessibility) is off.');
      return await Native.scroll(arg('direction')) ? ok() : fail('Nothing to scroll.');
    case 'media_control':
      final act = arg('action');
      if (Platform.isWindows) return await Pc.media(act) ? ok() : fail('Unknown media action $act');
      return await Native.media(act) ? ok() : fail('Could not control the media.');
    case 'close_app':
      final n = arg('name');
      if (Platform.isWindows) {
        final closed = await Pc.closeWindow(n);
        return closed.isEmpty
            ? fail('No open window matches "$n". Use list_windows to see what is open.', {'open': await Pc.windows()})
            : ok({'closed': closed});
      }
      return await Native.closeApp(n) ? ok() : fail('"$n" is not installed.');
    case 'list_windows':
      if (!Pc.on) return fail('This works on the PC. On the phone use read_screen.');
      return ok({'windows': await Pc.windows()});
    case 'focus_window':
      if (!Pc.on) return fail('This works on the PC.');
      final t = await Pc.focusWindow(arg('name'));
      return t.isEmpty ? fail('No window matches "${arg('name')}".', {'open': await Pc.windows()}) : ok({'focused': t});
    case 'type_on_pc':
      if (!Pc.on) return fail('This works on the PC. On the phone use type_text.');
      return await Pc.typeText(arg('text'), enter: a['enter'] == true) ? ok() : fail('Could not type.');
    case 'press_keys_pc':
      if (!Pc.on) return fail('This works on the PC. On the phone use press_key.');
      return await Pc.pressKeys(arg('keys')) ? ok() : fail('Could not press the keys.');
    case 'run_command':
    case 'open_terminal':
      if (!Pc.on) return fail('Commands run on the PC. Use device "pc" if it is linked.');
      final cmd = arg('command');
      if (Pc.risky(cmd) && a['confirmed'] != true) {
        return fail('This command can delete/change/download things. Tell the person exactly what it does and ask first; '
            'if they agree, call again with confirmed=true.');
      }
      if (name == 'open_terminal') return await Pc.openTerminal(cmd) ? ok() : fail('Could not open the terminal.');
      final (code, out) = await Pc.run(cmd);
      final o = out.length > 3000 ? '${out.substring(0, 3000)}\n…(cut)' : out;
      return code == 0 ? ok({'output': o}) : fail('Command failed (exit $code)', {'output': o});
    case 'create_sheet':
      return createSheet(a);
  }
  return fail('Unknown action $name');
}

/// Saves a table as CSV (opens in Excel / Google Sheets; Bangla works) and optionally pastes it into a new Google Sheet.
Future<Map<String, dynamic>> createSheet(Map<String, dynamic> a) async {
  final title = (a['title'] ?? 'Tommy sheet').toString().trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  final cols = ((a['columns'] as List?) ?? const []).map((e) => e.toString()).toList();
  final rows = ((a['rows'] as List?) ?? const [])
      .map((r) => r is List ? r.map((e) => e.toString().trim()).toList() : r.toString().split('|').map((e) => e.trim()).toList())
      .toList();
  String csvCell(String v) => v.contains(RegExp(r'[",\n]')) ? '"${v.replaceAll('"', '""')}"' : v;
  final csv = '\uFEFF${[cols, ...rows].map((r) => r.map(csvCell).join(',')).join('\r\n')}\r\n';
  final tsv = [cols, ...rows].map((r) => r.join('\t')).join('\n');

  // where to save
  final folderArg = (a['folder'] ?? '').toString().trim();
  Directory dir;
  if (Platform.isWindows) {
    final home = Platform.environment['USERPROFILE'] ?? '';
    final known = {'desktop': '$home\\Desktop', 'documents': '$home\\Documents', 'downloads': '$home\\Downloads'};
    dir = Directory(folderArg.isEmpty
        ? '$home\\Documents\\Tommy'
        : (known[folderArg.toLowerCase()] ?? (folderArg.contains(':') ? folderArg : '$home\\$folderArg')));
  } else if (Platform.isAndroid) {
    final known = {'downloads': 'Download', 'download': 'Download', 'documents': 'Documents'};
    dir = Directory('/storage/emulated/0/${known[folderArg.toLowerCase()] ?? 'Documents'}/Tommy');
  } else {
    dir = await getApplicationDocumentsDirectory();
  }
  File file;
  try {
    await dir.create(recursive: true);
    file = File('${dir.path}${Platform.pathSeparator}$title.csv');
    await file.writeAsString(csv);
  } catch (_) {
    final d = await getApplicationDocumentsDirectory();
    file = File('${d.path}${Platform.pathSeparator}$title.csv');
    await file.writeAsString(csv);
  }
  if (Platform.isWindows && a['google'] != true) {
    await Process.start('cmd', ['/c', 'start', '', file.path], mode: ProcessStartMode.detached);
  }
  final result = <String, dynamic>{'saved': file.path, 'rows': rows.length};
  if (a['google'] == true) {
    // Real Google Sheets saving needs Google login (on hold) — for now: new sheet + paste
    await Clipboard.setData(ClipboardData(text: tsv));
    await openUrl('https://sheets.new');
    if (Platform.isWindows) {
      await Future.delayed(const Duration(seconds: 9));
      await Pc.pressKeys('^v');
      result['google'] = 'New Google Sheet opened and the table pasted. Rename it from the title at the top-left.';
    } else {
      result['google'] = 'New Google Sheet opened; the table is copied — long-press the first cell and Paste.';
    }
  }
  return ok(result);
}

Future<bool> openAppByName(String name) async {
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
  if (web.containsKey(n)) return openUrl(web[n]!);
  final target = known[n] ?? name;
  try {
    await Process.start('cmd', ['/c', 'start', '', target], mode: ProcessStartMode.detached);
    return true;
  } catch (_) {
    return false;
  }
}
