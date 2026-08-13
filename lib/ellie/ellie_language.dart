enum EllieLanguage { english, arabic }

enum EllieLanguageMode { automatic, english, arabic }

extension EllieLanguageCode on EllieLanguage {
  String get code => this == EllieLanguage.arabic ? 'ar' : 'en';

  String get localeFallback =>
      this == EllieLanguage.arabic ? 'ar-EG' : 'en-US';
}

extension EllieLanguageModeLabel on EllieLanguageMode {
  String get storageValue {
    switch (this) {
      case EllieLanguageMode.automatic:
        return 'auto';
      case EllieLanguageMode.english:
        return 'en';
      case EllieLanguageMode.arabic:
        return 'ar';
    }
  }
}

class EllieLanguageTools {
  EllieLanguageTools._();

  static final RegExp _arabicCharacters =
      RegExp(r'[\u0600-\u06ff\u0750-\u077f\u08a0-\u08ff]');
  static final RegExp _arabicDiacritics =
      RegExp(r'[\u0610-\u061a\u064b-\u065f\u0670\u06d6-\u06ed]');

  static EllieLanguage detect(String text) {
    return _arabicCharacters.hasMatch(text)
        ? EllieLanguage.arabic
        : EllieLanguage.english;
  }

  static bool hasWakeWord(String text) {
    final normalized = text
        .toLowerCase()
        .replaceAll(_arabicDiacritics, '')
        .replaceAll('أ', 'ا')
        .replaceAll('إ', 'ا')
        .replaceAll('آ', 'ا')
        .replaceAll('ى', 'ي');
    final words = normalized
        .split(RegExp(r'[\s,،.!?؟;؛:]+'))
        .where((word) => word.isNotEmpty);
    return words.any((word) => word == 'ellie' || word == 'ايلي');
  }

  static String pick(
    EllieLanguage language, {
    required String english,
    required String arabic,
  }) {
    return language == EllieLanguage.arabic ? arabic : english;
  }

  static String modeLabel(EllieLanguageMode mode) {
    switch (mode) {
      case EllieLanguageMode.automatic:
        return 'Auto';
      case EllieLanguageMode.english:
        return 'English';
      case EllieLanguageMode.arabic:
        return 'العربية';
    }
  }

  static EllieLanguageMode modeFromStorage(String? value) {
    switch (value) {
      case 'en':
        return EllieLanguageMode.english;
      case 'ar':
        return EllieLanguageMode.arabic;
      default:
        return EllieLanguageMode.automatic;
    }
  }
}
