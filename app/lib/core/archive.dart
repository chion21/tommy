import 'dart:convert';
import 'dart:io';

import 'store.dart';

/// Long-term conversation memory, per user:
///  • archive.jsonl  — every turn ever said (kept on the device)
///  • summaries.json — the conversations turned into short bullet points by the brain
/// Recent summaries go into every conversation; older ones are searched when the person asks about the past.
class ChatArchive {
  final Store store;
  final String uid;
  ChatArchive(this.store, this.uid);

  static const _sessionGap = Duration(minutes: 20); // a pause this long ends a "conversation"
  static const _maxTurnsPerSummary = 30;

  Future<File> _file(String name) async => File('${(await store.userDir(uid)).path}${Platform.pathSeparator}$name');

  // ---------- full archive ----------
  Future<void> add(String role, String text) async {
    if (text.trim().isEmpty) return;
    final f = await _file('archive.jsonl');
    final line = jsonEncode({'ts': DateTime.now().toIso8601String(), 'role': role, 'text': text.trim()});
    await f.writeAsString('$line\n', mode: FileMode.append, flush: true);
  }

  Future<List<Map<String, dynamic>>> turns() async {
    final f = await _file('archive.jsonl');
    if (!await f.exists()) return [];
    final out = <Map<String, dynamic>>[];
    for (final l in await f.readAsLines()) {
      if (l.trim().isEmpty) continue;
      try {
        out.add(jsonDecode(l) as Map<String, dynamic>);
      } catch (_) {}
    }
    return out;
  }

  // ---------- point summaries ----------
  Future<List<Map<String, dynamic>>> summaries() async {
    final j = await store.readJson(uid, 'summaries.json');
    return ((j['items'] as List?) ?? []).cast<Map<String, dynamic>>();
  }

  Future<void> _saveSummaries(List<Map<String, dynamic>> items, String doneUntil) =>
      store.writeJson(uid, 'summaries.json', {'items': items, 'done_until': doneUntil});

  /// Finished conversations that still need to be turned into points:
  /// returns (turns, until-timestamp) of the oldest one, or null.
  Future<(List<Map<String, dynamic>>, String)?> nextToSummarise({bool includeCurrent = false}) async {
    final j = await store.readJson(uid, 'summaries.json');
    final doneUntil = (j['done_until'] ?? '') as String;
    final all = (await turns()).where((t) => (t['ts'] as String).compareTo(doneUntil) > 0).toList();
    if (all.isEmpty) return null;
    final chunk = <Map<String, dynamic>>[];
    DateTime? prev;
    for (final t in all) {
      final ts = DateTime.parse(t['ts'] as String);
      if (prev != null && ts.difference(prev) > _sessionGap) break; // conversation ended here
      chunk.add(t);
      prev = ts;
      if (chunk.length >= _maxTurnsPerSummary) break;
    }
    final finished = chunk.length < all.length || chunk.length >= _maxTurnsPerSummary ||
        (prev != null && DateTime.now().difference(prev) > _sessionGap) || includeCurrent;
    if (!finished || chunk.length < 2) return null;
    return (chunk, chunk.last['ts'] as String);
  }

  Future<void> addSummary(List<Map<String, dynamic>> chunk, String until, List<String> points) async {
    final items = await summaries();
    if (points.isNotEmpty) {
      items.add({'from': chunk.first['ts'], 'to': until, 'points': points});
    }
    await _saveSummaries(items, until);
  }

  /// Recent points for every conversation (kept short so each call stays cheap).
  Future<List<String>> recentPoints({int maxChars = 1800}) async {
    final out = <String>[];
    var used = 0;
    for (final s in (await summaries()).reversed) {
      final day = (s['from'] as String).substring(0, 10);
      for (final p in (s['points'] as List).cast<String>()) {
        final line = '[$day] $p';
        if (used + line.length > maxChars) return out.reversed.toList();
        out.add(line);
        used += line.length;
      }
    }
    return out.reversed.toList();
  }

  /// Keyword search over summaries and the full archive (works for Bangla, English, Hindi).
  Future<List<String>> search(String query, {int limit = 12}) async {
    final words = _words(query);
    if (words.isEmpty) return [];
    final scored = <(double, String)>[];
    double score(String text) {
      final t = _words(text);
      var s = 0.0;
      for (final w in words) {
        if (t.contains(w)) {
          s += 1;
        } else if (w.length >= 3 && t.any((x) => x.startsWith(w) || w.startsWith(x) && x.length >= 3)) {
          s += 0.5; // Bangla suffixes: "রিয়ার" ~ "রিয়া"
        }
      }
      return s;
    }

    for (final s in await summaries()) {
      final day = (s['from'] as String).substring(0, 10);
      for (final p in (s['points'] as List).cast<String>()) {
        final sc = score(p);
        if (sc > 0) scored.add((sc + 0.3, '[$day, summary] $p'));
      }
    }
    for (final t in await turns()) {
      final sc = score(t['text'] as String);
      if (sc > 0) {
        final who = t['role'] == 'user' ? 'they said' : 'you said';
        scored.add((sc, '[${(t['ts'] as String).substring(0, 16).replaceFirst('T', ' ')}, $who] ${t['text']}'));
      }
    }
    scored.sort((a, b) => b.$1.compareTo(a.$1));
    return scored.take(limit).map((e) => e.$2).toList();
  }

  Future<void> deleteAll() async {
    for (final n in ['archive.jsonl', 'summaries.json']) {
      final f = await _file(n);
      if (await f.exists()) await f.delete();
    }
  }

  static const _stop = {
    'আমি', 'তুমি', 'আমার', 'তোমার', 'কি', 'কী', 'কে', 'এই', 'ওই', 'সেই', 'আর', 'ও', 'না', 'হ্যাঁ', 'তো', 'যে', 'কথা',
    'বলেছিলাম', 'বলেছিলে', 'বলো', 'বল', 'মনে', 'আছে', 'ছিল', 'করে', 'the', 'a', 'an', 'is', 'was', 'i', 'you', 'what',
    'did', 'do', 'about', 'that', 'my', 'me', 'remember', 'tell', 'said',
  };

  static Set<String> _words(String s) => s
      .toLowerCase()
      .split(RegExp(r'[\s,.;:!?।"“”()\[\]{}]+'))
      .where((w) => w.length >= 2 && !_stop.contains(w))
      .toSet();
}
