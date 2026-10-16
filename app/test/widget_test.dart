import 'package:flutter_test/flutter_test.dart';
import 'package:tommy/core/app_state.dart';
import 'package:tommy/core/gemini.dart';
import 'package:tommy/core/strings.dart';
import 'package:tommy/core/themes.dart';

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
}
