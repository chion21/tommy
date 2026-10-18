import 'package:flutter_test/flutter_test.dart';
import 'dart:typed_data';

import 'package:tommy/core/app_state.dart';
import 'package:tommy/core/brain.dart';
import 'package:tommy/core/persona.dart';
import 'package:tommy/core/gemini.dart';
import 'package:tommy/core/strings.dart';
import 'package:tommy/core/themes.dart';
import 'package:tommy/core/tools.dart';
import 'package:tommy/core/voice.dart';

void main() {
  test('strings exist in all three languages', () {
    for (final lang in ['bn', 'en', 'hi']) {
      expect(tr(lang, 'ask', vars: {'name': 'রিয়া'}).contains('রিয়া'), isTrue);
      expect(trError(lang, 'EMAIL_EXISTS'), isNot('EMAIL_EXISTS'));
    }
  });

  test('six colours, five girls and five boys', () {
    expect(tommyThemes.length, 6);
    expect(characters.where((c) => c.female).length, 5);
    expect(characters.where((c) => !c.female).length, 5);
  });

  test('sensitive text is blocked from memory', () {
    expect(isSensitive('my card 4111 1111 1111 1111'), isTrue);
    expect(isSensitive('আমার পাসওয়ার্ড 1234'), isTrue);
    expect(isSensitive('আমাকে ভাইয়া বলে ডাকবে'), isFalse);
  });

  test('obviously wrong keys are rejected without a network call', () async {
    expect(await checkGeminiKey('abc'), KeyCheck.invalid);
    expect(maskKey('AIzaSyABCDEFGHIJKLMNOPQRSTUVWXYZ'), startsWith('AIza'));
  });

  test('persona prompts carry name, role and boundaries', () {
    for (final p in personas) {
      final s = buildSystemPrompt(name: 'রিয়া', female: true, persona: p, userName: 'রাকিব', callMe: 'স্যার',
          speechLanguage: 'auto', memories: const ['likes tea'], handsFree: true, platform: 'android', now: DateTime(2026));
      expect(s.contains('রিয়া'), isTrue);
      expect(s.contains('likes tea'), isTrue);
      if (isPartner(p)) expect(s.contains('no sexual or explicit content'), isTrue);
      final l = buildSystemPrompt(name: 'টমি', female: true, persona: p, userName: '', callMe: 'স্যার',
          speechLanguage: 'bn', memories: const [], rules: const ['play songs directly'], handsFree: true,
          platform: 'android', now: DateTime(2026), live: true);
      expect(l.contains('play_youtube'), isTrue);
      expect(l.contains('play songs directly'), isTrue);
    }
  });

  test('wav header is valid', () {
    final w = wavFromPcm16(Uint8List(48000), 24000);
    expect(String.fromCharCodes(w.sublist(0, 4)), 'RIFF');
    expect(w.length, 48000 + 44);
  });

  test('licence format', () {
    expect(licenseFormat.hasMatch('TOMMY-ABCD-EFGH-JKLM'), isTrue);
    expect(licenseFormat.hasMatch('TOMMY-1234'), isFalse);
  });

  test('tool declarations are well formed', () {
    final names = toolDeclarations.map((d) => d['name']).toList();
    expect(names.toSet().length, names.length);
    expect(names, containsAll(['play_youtube', 'research', 'remember', 'update_memory', 'tap']));
  });

  test('old partner role maps to girlfriend/boyfriend', () {
    expect(normalizePersona('partner', true), 'girlfriend');
    expect(normalizePersona('partner', false), 'boyfriend');
  });

  test('loudness of silence is very low', () {
    expect(LiveMic.dbfs(Uint8List(3200)), lessThan(-90));
  });
}
