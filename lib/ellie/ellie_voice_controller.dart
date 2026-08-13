import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../ble_service.dart';
import 'ellie_language.dart';

enum EllieOutputMode { phone, esp32, both }

enum EllieVoicePhase { idle, listening, thinking, speaking, error }

class EllieVoiceEvent {
  const EllieVoiceEvent({
    required this.phase,
    required this.language,
    this.transcript,
    this.reply,
    this.error,
    this.warning,
  });

  final EllieVoicePhase phase;
  final EllieLanguage language;
  final String? transcript;
  final String? reply;
  final Object? error;
  final String? warning;
}

class EllieLocalReply {
  const EllieLocalReply({
    required this.handled,
    required this.needsCloud,
    required this.speakerQueued,
    this.reply,
    this.offlineReply,
  });

  factory EllieLocalReply.fromJson(Map<String, dynamic> json) {
    return EllieLocalReply(
      handled: json['handled'] == true,
      needsCloud: json['needsCloud'] == true,
      speakerQueued: json['speakerQueued'] == true,
      reply: json['reply']?.toString(),
      offlineReply: json['offlineReply']?.toString(),
    );
  }

  final bool handled;
  final bool needsCloud;
  final bool speakerQueued;
  final String? reply;
  final String? offlineReply;
}

class _CloudReply {
  const _CloudReply(this.text, this.language);

  final String text;
  final EllieLanguage language;
}

/// Coordinates bilingual short microphone sessions, deterministic local home
/// control, authenticated cloud conversation, and phone/ESP32 speech output.
/// The cloud model never receives a function or endpoint that can operate a
/// relay; hardware actions are accepted only by the ESP32's local parser.
class EllieVoiceController {
  EllieVoiceController({
    required this.esp32BaseUri,
    required this.cloudBaseUri,
    required this.getIdentityToken,
    this.bleService,
    this.outputMode = EllieOutputMode.both,
    this.requireWakeWord = true,
    this.preferOnDeviceRecognition = true,
    this.allowNetworkRecognitionFallback = true,
    this.conversationWindow = const Duration(seconds: 30),
    EllieLanguageMode languageMode = EllieLanguageMode.automatic,
    http.Client? httpClient,
    SpeechToText? speechToText,
    FlutterTts? flutterTts,
  })  : _languageMode = languageMode,
        _http = httpClient ?? http.Client(),
        _speech = speechToText ?? SpeechToText(),
        _tts = flutterTts ?? FlutterTts(),
        _conversationId = _newConversationId();

  final Uri esp32BaseUri;
  final Uri? cloudBaseUri;
  final Future<String?> Function() getIdentityToken;
  final BleService? bleService;
  final EllieOutputMode outputMode;
  final bool requireWakeWord;
  final bool preferOnDeviceRecognition;
  final bool allowNetworkRecognitionFallback;
  final Duration conversationWindow;

  final http.Client _http;
  final SpeechToText _speech;
  final FlutterTts _tts;
  final String _conversationId;
  final StreamController<EllieVoiceEvent> _events =
      StreamController<EllieVoiceEvent>.broadcast();
  final List<Map<String, String>> _chatHistory = <Map<String, String>>[];

  EllieLanguageMode _languageMode;
  EllieLanguage _lastDetectedLanguage = EllieLanguage.english;
  EllieLanguage _systemLanguage = EllieLanguage.english;
  EllieLanguage _activeRecognitionLanguage = EllieLanguage.english;
  List<String> _speechLocales = const <String>[];
  List<String> _ttsLanguages = const <String>[];
  bool _initialized = false;
  bool _speechAvailable = false;
  bool _submittedCurrentSpeech = false;
  bool _disposed = false;
  String _lastTranscript = '';
  DateTime _conversationActiveUntil = DateTime.fromMillisecondsSinceEpoch(0);

  Stream<EllieVoiceEvent> get events => _events.stream;
  bool get isListening => _speech.isListening;
  EllieLanguageMode get languageMode => _languageMode;

  bool get _phoneSpeechEnabled =>
      outputMode == EllieOutputMode.phone || outputMode == EllieOutputMode.both;
  bool get _esp32SpeechEnabled =>
      outputMode == EllieOutputMode.esp32 || outputMode == EllieOutputMode.both;

  static String _newConversationId() {
    final random = Random.secure().nextInt(0x7fffffff).toRadixString(16);
    return '${DateTime.now().microsecondsSinceEpoch}-$random';
  }

  void setLanguageMode(EllieLanguageMode mode) {
    _languageMode = mode;
    final language = _languageForMode();
    _emit(EllieVoiceEvent(
      phase: EllieVoicePhase.idle,
      language: language,
    ));
  }

  Future<bool> initialize() async {
    if (_initialized) return _speechAvailable;

    try {
      _speechAvailable = await _speech.initialize(
        onStatus: _onSpeechStatus,
        onError: (error) => _emit(EllieVoiceEvent(
          phase: EllieVoicePhase.error,
          language: _activeRecognitionLanguage,
          error: error,
        )),
      );

      if (_speechAvailable) {
        final locales = await _speech.locales();
        _speechLocales = locales.map((locale) => locale.localeId).toList();
        final systemLocale = await _speech.systemLocale();
        if (systemLocale != null) {
          _systemLanguage = _languageFromLocale(systemLocale.localeId);
          _lastDetectedLanguage = _systemLanguage;
        }
      }

      final dynamic rawTtsLanguages = await _tts.getLanguages;
      if (rawTtsLanguages is Iterable) {
        _ttsLanguages = rawTtsLanguages.map((value) => '$value').toList();
      }
      await _tts.awaitSpeakCompletion(true);
      await _tts.setSpeechRate(0.46);
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);

      _initialized = true;
      _emit(EllieVoiceEvent(
        phase: EllieVoicePhase.idle,
        language: _languageForMode(),
      ));
      return _speechAvailable;
    } catch (error) {
      _speechAvailable = false;
      _initialized = false;
      _emit(EllieVoiceEvent(
        phase: EllieVoicePhase.error,
        language: _languageForMode(),
        error: error,
      ));
      return false;
    }
  }

  Future<void> startListening() async {
    if (!await initialize()) {
      final language = _languageForMode();
      _emit(EllieVoiceEvent(
        phase: EllieVoicePhase.error,
        language: language,
        error: EllieLanguageTools.pick(
          language,
          english: 'Speech recognition is unavailable or permission was denied.',
          arabic: 'التعرّف على الكلام غير متاح أو لم يتم السماح بالميكروفون.',
        ),
      ));
      return;
    }

    await _tts.stop();
    _lastTranscript = '';
    _submittedCurrentSpeech = false;
    _activeRecognitionLanguage = _languageForMode();
    final localeId = _bestSpeechLocale(_activeRecognitionLanguage);

    _emit(EllieVoiceEvent(
      phase: EllieVoicePhase.listening,
      language: _activeRecognitionLanguage,
    ));

    try {
      await _listen(localeId: localeId, onDevice: preferOnDeviceRecognition);
    } catch (firstError) {
      if (preferOnDeviceRecognition && allowNetworkRecognitionFallback) {
        try {
          await _listen(localeId: localeId, onDevice: false);
          return;
        } catch (_) {
          // Emit the original on-device failure below; it is usually more
          // actionable (for example, a missing offline language pack).
        }
      }
      _emit(EllieVoiceEvent(
        phase: EllieVoicePhase.error,
        language: _activeRecognitionLanguage,
        error: firstError,
      ));
    }
  }

  Future<void> _listen({required String? localeId, required bool onDevice}) async {
    await _speech.listen(
      onResult: _onSpeechResult,
      localeId: localeId,
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 3),
      partialResults: true,
      cancelOnError: true,
      onDevice: onDevice,
    );
  }

  Future<void> stopListening() async {
    await _speech.stop();
    if (!_submittedCurrentSpeech && _lastTranscript.trim().isNotEmpty) {
      await _submitCurrentSpeech();
    }
  }

  Future<void> handleTranscript(
    String transcript, {
    bool bypassWakeWord = false,
  }) async {
    final text = transcript.trim();
    if (text.isEmpty || _disposed) return;

    await _speech.stop();
    final language = EllieLanguageTools.detect(text);
    _lastDetectedLanguage = language;
    final hasWakeWord = EllieLanguageTools.hasWakeWord(text);
    final conversationIsActive =
        DateTime.now().isBefore(_conversationActiveUntil);

    if (!bypassWakeWord &&
        requireWakeWord &&
        !hasWakeWord &&
        !conversationIsActive) {
      await _deliverReply(
        EllieLanguageTools.pick(
          language,
          english: 'Say Ellie first, then your request.',
          arabic: 'قولي إيلي أولاً، ثم اطلبي ما تريدين.',
        ),
        language: language,
        esp32AlreadyQueued: false,
        tryEsp32: false,
      );
      return;
    }

    if (hasWakeWord || conversationIsActive || bypassWakeWord) {
      _conversationActiveUntil = DateTime.now().add(conversationWindow);
    }

    _emit(EllieVoiceEvent(
      phase: EllieVoicePhase.thinking,
      language: language,
      transcript: text,
    ));

    EllieLocalReply? local;
    try {
      local = await _sendLocalIntent(text, language);
    } catch (_) {
      local = null;
    }

    if (local?.handled == true && (local?.reply?.trim().isNotEmpty ?? false)) {
      await _deliverReply(
        local!.reply!.trim(),
        language: language,
        esp32AlreadyQueued: local.speakerQueued,
      );
      return;
    }

    if (_looksLikeHardwareCommand(text) &&
        (local == null || local.needsCloud)) {
      await _deliverReply(
        EllieLanguageTools.pick(
          language,
          english:
              "I couldn't safely match that home command, so I didn't change anything.",
          arabic: 'لم أتمكن من تحديد أمر المنزل بأمان، لذلك لم أغيّر أي شيء.',
        ),
        language: language,
        esp32AlreadyQueued: false,
        tryEsp32: false,
      );
      return;
    }

    try {
      final cloudReply = await _sendCloudChat(text, language);
      await _deliverReply(
        cloudReply.text,
        language: cloudReply.language,
        esp32AlreadyQueued: false,
      );
    } catch (_) {
      final fallback = local?.offlineReply?.trim();
      await _deliverReply(
        fallback?.isNotEmpty == true
            ? fallback!
            : EllieLanguageTools.pick(
                language,
                english:
                    "I'm offline right now, but local home commands still work when the controller is reachable.",
                arabic:
                    'أنا غير متصلة بالإنترنت الآن، لكن أوامر المنزل المحلية ستعمل عند الوصول إلى وحدة التحكم.',
              ),
        language: language,
        esp32AlreadyQueued: false,
        tryEsp32: false,
      );
    }
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    _lastTranscript = result.recognizedWords;
    _emit(EllieVoiceEvent(
      phase: EllieVoicePhase.listening,
      language: _activeRecognitionLanguage,
      transcript: _lastTranscript,
    ));
    if (result.finalResult) unawaited(_submitCurrentSpeech());
  }

  void _onSpeechStatus(String status) {
    if ((status == SpeechToText.doneStatus ||
            status == SpeechToText.notListeningStatus) &&
        !_submittedCurrentSpeech &&
        _lastTranscript.trim().isNotEmpty) {
      unawaited(_submitCurrentSpeech());
    }
  }

  Future<void> _submitCurrentSpeech() async {
    if (_submittedCurrentSpeech) return;
    _submittedCurrentSpeech = true;
    try {
      await handleTranscript(_lastTranscript);
    } catch (error) {
      _emit(EllieVoiceEvent(
        phase: EllieVoicePhase.error,
        language: _activeRecognitionLanguage,
        error: error,
      ));
    }
  }

  Future<EllieLocalReply> _sendLocalIntent(
    String text,
    EllieLanguage language,
  ) async {
    // The ESP8266SAM fallback voice is English-only. Arabic responses are
    // returned as text first, then routed through cloud TTS for the ESP32.
    final speakLocally =
        _esp32SpeechEnabled && language == EllieLanguage.english;
    final payload = <String, dynamic>{
      'text': text,
      'language': language.code,
      'speak': speakLocally,
    };

    try {
      final response = await _http
          .post(
            esp32BaseUri.resolve('/api/ellie'),
            headers: const <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(milliseconds: 2500));
      if (response.statusCode != 200) {
        throw StateError('ESP32 returned ${response.statusCode}');
      }
      return EllieLocalReply.fromJson(_decodeObject(response.body));
    } catch (_) {
      final ble = bleService;
      if (ble == null || !ble.isConnected) rethrow;
      final response = await ble.sendEllieText(text, speak: speakLocally);
      return EllieLocalReply.fromJson(response);
    }
  }

  Future<_CloudReply> _sendCloudChat(
    String message,
    EllieLanguage language,
  ) async {
    final baseUri = cloudBaseUri;
    if (baseUri == null) {
      throw StateError('ELLIE_BACKEND_URL is not configured.');
    }
    final token = await getIdentityToken();
    if (token == null || token.isEmpty) {
      throw StateError('No customer identity token is available.');
    }

    final response = await _http
        .post(
          baseUri.resolve('/v1/ellie/chat'),
          headers: <String, String>{
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode(<String, dynamic>{
            'conversationId': _conversationId,
            'language': language.code,
            'message': message,
            'history': _chatHistory,
          }),
        )
        .timeout(const Duration(seconds: 25));

    if (response.statusCode != 200) {
      throw StateError('Ellie backend returned ${response.statusCode}');
    }
    final body = _decodeObject(response.body);
    final reply = (body['reply']?.toString() ?? '').trim();
    if (reply.isEmpty) throw StateError('Ellie backend returned an empty reply.');
    final replyLanguage = body['language'] == 'ar'
        ? EllieLanguage.arabic
        : body['language'] == 'en'
            ? EllieLanguage.english
            : EllieLanguageTools.detect(reply);

    _chatHistory.add(<String, String>{'role': 'user', 'content': message});
    _chatHistory.add(<String, String>{'role': 'assistant', 'content': reply});
    while (_chatHistory.length > 10) {
      _chatHistory.removeAt(0);
    }
    return _CloudReply(reply, replyLanguage);
  }

  Future<void> _deliverReply(
    String reply, {
    required EllieLanguage language,
    required bool esp32AlreadyQueued,
    bool tryEsp32 = true,
  }) async {
    _emit(EllieVoiceEvent(
      phase: EllieVoicePhase.speaking,
      language: language,
      reply: reply,
    ));
    await _speech.stop();

    final tasks = <Future<void>>[];
    if (_phoneSpeechEnabled) {
      tasks.add(_speakOnPhone(reply, language));
    }
    if (_esp32SpeechEnabled && !esp32AlreadyQueued && tryEsp32) {
      tasks.add(_speakOnEsp32(reply, language));
    }

    String? warning;
    for (final task in tasks) {
      try {
        await task;
      } catch (_) {
        warning = EllieLanguageTools.pick(
          language,
          english: 'One voice output was unavailable.',
          arabic: 'تعذّر تشغيل أحد مخارج الصوت.',
        );
      }
    }
    _emit(EllieVoiceEvent(
      phase: EllieVoicePhase.idle,
      language: language,
      reply: reply,
      warning: warning,
    ));
  }

  Future<void> _speakOnPhone(String text, EllieLanguage language) async {
    await _tts.stop();
    final locale = _bestTtsLocale(language);
    await _tts.setLanguage(locale);
    await _tts.setSpeechRate(language == EllieLanguage.arabic ? 0.42 : 0.46);
    await _tts.speak(text);
  }

  Future<void> _speakOnEsp32(
    String text,
    EllieLanguage language,
  ) async {
    final clipped = text.length <= 220 ? text : text.substring(0, 220);
    if (language == EllieLanguage.arabic) {
      await _queueCloudAudioOnEsp32(clipped, language);
      return;
    }

    try {
      final response = await _http
          .post(
            esp32BaseUri.resolve('/api/ellie/speak'),
            headers: const <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(<String, dynamic>{'text': clipped}),
          )
          .timeout(const Duration(milliseconds: 2500));
      if (response.statusCode >= 200 && response.statusCode < 300) return;
      throw StateError('ESP32 speaker returned ${response.statusCode}');
    } catch (_) {
      final ble = bleService;
      if (ble == null || !ble.isConnected) rethrow;
      final queued = await ble.queueEllieSpeech(clipped);
      if (!queued) throw StateError('ESP32 rejected the speech request.');
    }
  }

  Future<void> _queueCloudAudioOnEsp32(
    String text,
    EllieLanguage language,
  ) async {
    final baseUri = cloudBaseUri;
    if (baseUri == null) {
      throw StateError('Cloud TTS is not configured.');
    }
    final token = await getIdentityToken();
    if (token == null || token.isEmpty) {
      throw StateError('No customer identity token is available.');
    }

    final ticketResponse = await _http
        .post(
          baseUri.resolve('/v1/ellie/speech-ticket'),
          headers: <String, String>{
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode(<String, dynamic>{
            'text': text,
            'language': language.code,
          }),
        )
        .timeout(const Duration(seconds: 12));
    if (ticketResponse.statusCode != 200) {
      throw StateError('Cloud TTS ticket failed.');
    }
    final ticket = _decodeObject(ticketResponse.body);
    final audioUrl = Uri.tryParse(ticket['audioUrl']?.toString() ?? '');
    if (audioUrl == null || audioUrl.scheme != 'https') {
      throw StateError('Cloud TTS returned an invalid audio URL.');
    }

    final espResponse = await _http
        .post(
          esp32BaseUri.resolve('/api/ellie/audio'),
          headers: const <String, String>{'Content-Type': 'application/json'},
          body: jsonEncode(<String, dynamic>{'url': audioUrl.toString()}),
        )
        .timeout(const Duration(milliseconds: 3500));
    if (espResponse.statusCode < 200 || espResponse.statusCode >= 300) {
      throw StateError('ESP32 rejected cloud audio.');
    }
  }

  bool _looksLikeHardwareCommand(String text) {
    final normalized = text.toLowerCase();
    final englishAction =
        RegExp(r'\b(turn|switch|power|activate|deactivate)\b')
            .hasMatch(normalized);
    final englishTarget = RegExp(
      r'\b(light|lamp|fan|switch|socket|outlet|plug|device|room|television|tv)\b',
    ).hasMatch(normalized);
    if (englishAction && englishTarget) return true;

    return RegExp(
      r'(شغل|شغلي|افتح|افتحي|اطف|اطفي|اقفل|اقفلي|اغلق|تشغيل|اطفاء)',
    ).hasMatch(normalized);
  }

  EllieLanguage _languageForMode() {
    switch (_languageMode) {
      case EllieLanguageMode.english:
        return EllieLanguage.english;
      case EllieLanguageMode.arabic:
        return EllieLanguage.arabic;
      case EllieLanguageMode.automatic:
        return _lastDetectedLanguage;
    }
  }

  EllieLanguage _languageFromLocale(String locale) {
    return locale.toLowerCase().startsWith('ar')
        ? EllieLanguage.arabic
        : EllieLanguage.english;
  }

  String? _bestSpeechLocale(EllieLanguage language) {
    if (_speechLocales.isEmpty) return language.localeFallback;
    return _bestLocale(
      _speechLocales,
      language == EllieLanguage.arabic
          ? const <String>['ar-EG', 'ar-SA', 'ar']
          : const <String>['en-US', 'en-GB', 'en'],
    );
  }

  String _bestTtsLocale(EllieLanguage language) {
    if (_ttsLanguages.isEmpty) return language.localeFallback;
    return _bestLocale(
          _ttsLanguages,
          language == EllieLanguage.arabic
              ? const <String>['ar-EG', 'ar-SA', 'ar']
              : const <String>['en-US', 'en-GB', 'en'],
        ) ??
        language.localeFallback;
  }

  String? _bestLocale(List<String> installed, List<String> preferred) {
    String normalize(String value) => value.toLowerCase().replaceAll('_', '-');

    for (final requested in preferred) {
      final normalizedRequested = normalize(requested);
      for (final candidate in installed) {
        if (normalize(candidate) == normalizedRequested) return candidate;
      }
    }
    final prefix = preferred.last.toLowerCase();
    for (final candidate in installed) {
      if (normalize(candidate).startsWith(prefix)) return candidate;
    }
    return null;
  }

  Map<String, dynamic> _decodeObject(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) throw const FormatException('Expected a JSON object.');
    return decoded.cast<String, dynamic>();
  }

  void _emit(EllieVoiceEvent event) {
    if (!_disposed) _events.add(event);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _speech.cancel();
    await _tts.stop();
    _http.close();
    await _events.close();
  }
}
