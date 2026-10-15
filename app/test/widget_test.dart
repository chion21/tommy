import 'package:flutter_test/flutter_test.dart';
import 'package:tommy/core/strings.dart';
import 'package:tommy/core/themes.dart';

void main() {
  test('strings exist in all three languages', () {
    for (final lang in ['bn', 'en', 'hi']) {
      expect(tr(lang, 'ask', vars: {'name': 'রিয়া'}).contains('রিয়া'), isTrue);
    }
  });

  test('six themes with unique ids', () {
    expect(tommyThemes.length, 6);
    expect(tommyThemes.map((t) => t.id).toSet().length, 6);
  });
}
