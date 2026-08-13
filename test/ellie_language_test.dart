import 'package:flutter_test/flutter_test.dart';
import 'package:iot/ellie/ellie_language.dart';

void main() {
  group('Ellie language handling', () {
    test('detects Arabic and English text', () {
      expect(
        EllieLanguageTools.detect('شغلي نور الصالة'),
        EllieLanguage.arabic,
      );
      expect(
        EllieLanguageTools.detect('Turn on the living room light'),
        EllieLanguage.english,
      );
    });

    test('accepts both wake-name spellings', () {
      expect(EllieLanguageTools.hasWakeWord('Hey Ellie, turn it on'), isTrue);
      expect(EllieLanguageTools.hasWakeWord('إيلي، شغلي النور'), isTrue);
      expect(EllieLanguageTools.hasWakeWord('ايلي اطفي المروحة'), isTrue);
      expect(EllieLanguageTools.hasWakeWord('turn it on'), isFalse);
    });
  });
}
