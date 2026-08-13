import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ble_service.dart';
import 'ellie_language.dart';
import 'ellie_voice_controller.dart';

class EllieAssistantSheet extends StatefulWidget {
  const EllieAssistantSheet({
    super.key,
    required this.esp32BaseUri,
    required this.cloudBaseUri,
    required this.bleService,
    required this.getIdentityToken,
  });

  final Uri esp32BaseUri;
  final Uri? cloudBaseUri;
  final BleService bleService;
  final Future<String?> Function() getIdentityToken;

  @override
  State<EllieAssistantSheet> createState() => _EllieAssistantSheetState();
}

class _EllieAssistantSheetState extends State<EllieAssistantSheet> {
  static const String _languagePreferenceKey = 'ellie_language_mode';

  late final EllieVoiceController _controller;
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<_EllieMessage> _messages = <_EllieMessage>[
    const _EllieMessage(
      text: 'Hi, I’m Ellie. Say “Ellie” and your request, or type below.',
      language: EllieLanguage.english,
    ),
    const _EllieMessage(
      text: 'مرحباً، أنا إيلي. قولي «إيلي» ثم طلبك، أو اكتبي في الأسفل.',
      language: EllieLanguage.arabic,
    ),
  ];

  StreamSubscription<EllieVoiceEvent>? _subscription;
  EllieLanguageMode _languageMode = EllieLanguageMode.automatic;
  EllieVoiceEvent _event = const EllieVoiceEvent(
    phase: EllieVoicePhase.idle,
    language: EllieLanguage.english,
  );

  @override
  void initState() {
    super.initState();
    _controller = EllieVoiceController(
      esp32BaseUri: widget.esp32BaseUri,
      cloudBaseUri: widget.cloudBaseUri,
      getIdentityToken: widget.getIdentityToken,
      bleService: widget.bleService,
      outputMode: EllieOutputMode.both,
      requireWakeWord: true,
    );
    _subscription = _controller.events.listen(_handleEvent);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    final preferences = await SharedPreferences.getInstance();
    final savedMode = EllieLanguageTools.modeFromStorage(
      preferences.getString(_languagePreferenceKey),
    );
    if (!mounted) return;
    setState(() => _languageMode = savedMode);
    _controller.setLanguageMode(savedMode);
    await _controller.initialize();
  }

  void _handleEvent(EllieVoiceEvent event) {
    if (!mounted) return;
    setState(() {
      _event = event;
      if (event.phase == EllieVoicePhase.thinking &&
          event.transcript?.trim().isNotEmpty == true) {
        _appendMessage(_EllieMessage(
          text: event.transcript!.trim(),
          language: event.language,
          isUser: true,
        ));
      } else if (event.phase == EllieVoicePhase.speaking &&
          event.reply?.trim().isNotEmpty == true) {
        _appendMessage(_EllieMessage(
          text: event.reply!.trim(),
          language: event.language,
        ));
      } else if (event.phase == EllieVoicePhase.error) {
        _appendMessage(_EllieMessage(
          text: _friendlyError(event),
          language: event.language,
          isSystem: true,
        ));
      }
    });
    _scrollToLatest();
  }

  void _appendMessage(_EllieMessage message) {
    final last = _messages.isEmpty ? null : _messages.last;
    if (last != null &&
        last.text == message.text &&
        last.isUser == message.isUser &&
        last.isSystem == message.isSystem) {
      return;
    }
    _messages.add(message);
  }

  String _friendlyError(EllieVoiceEvent event) {
    final raw = event.error?.toString().trim();
    if (raw != null && raw.isNotEmpty) return raw;
    return EllieLanguageTools.pick(
      event.language,
      english: 'Ellie could not complete that request.',
      arabic: 'لم تتمكن إيلي من إكمال هذا الطلب.',
    );
  }

  void _scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _setLanguageMode(EllieLanguageMode mode) async {
    if (_controller.isListening) await _controller.stopListening();
    if (!mounted) return;
    setState(() => _languageMode = mode);
    _controller.setLanguageMode(mode);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_languagePreferenceKey, mode.storageValue);
  }

  Future<void> _toggleListening() async {
    if (_controller.isListening) {
      await _controller.stopListening();
    } else {
      await _controller.startListening();
    }
  }

  Future<void> _sendTypedMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _isBusy) return;
    _textController.clear();
    await _controller.handleTranscript(text, bypassWakeWord: true);
  }

  bool get _isBusy =>
      _event.phase == EllieVoicePhase.thinking ||
      _event.phase == EllieVoicePhase.speaking;

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    unawaited(_controller.dispose());
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final listening = _event.phase == EllieVoicePhase.listening;
    final height = MediaQuery.sizeOf(context).height * 0.88;

    return Container(
      height: height,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 28,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: <Widget>[
            const SizedBox(height: 10),
            Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: colors.onSurface.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            _buildHeader(context),
            _buildLanguageSelector(context),
            if (widget.cloudBaseUri == null) _buildOfflineNotice(context),
            Divider(height: 1, color: colors.outlineVariant),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
                itemCount: _messages.length,
                itemBuilder: (context, index) =>
                    _MessageBubble(message: _messages[index]),
              ),
            ),
            _buildStatus(context),
            _buildComposer(context, listening: listening),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text(
                'Ellie’s cloud voice is AI-generated · صوت إيلي السحابي مُولَّد بالذكاء الاصطناعي',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant.withValues(alpha: 0.72),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 10, 10),
      child: Row(
        children: <Widget>[
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: <Color>[colors.primary, colors.tertiary],
              ),
            ),
            child: const Icon(Icons.graphic_eq_rounded, color: Colors.white),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Ellie · إيلي',
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
                ),
                SizedBox(height: 2),
                Text(
                  'Smart-home assistant · مساعدة المنزل الذكي',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Close · إغلاق',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }

  Widget _buildLanguageSelector(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        children: EllieLanguageMode.values.map((mode) {
          final selected = mode == _languageMode;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: ChoiceChip(
                label: SizedBox(
                  width: double.infinity,
                  child: Text(
                    EllieLanguageTools.modeLabel(mode),
                    textAlign: TextAlign.center,
                  ),
                ),
                selected: selected,
                onSelected: (_) => unawaited(_setLanguageMode(mode)),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildOfflineNotice(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: colors.secondaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        'Offline home commands are ready. Deploy the Ellie backend and set ELLIE_BACKEND_URL for open conversation.\n'
        'أوامر المنزل المحلية جاهزة. يلزم رابط خادم إيلي للمحادثة المفتوحة.',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, color: colors.onSecondaryContainer),
      ),
    );
  }

  Widget _buildStatus(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: Padding(
        key: ValueKey<String>(_statusText),
        padding: const EdgeInsets.fromLTRB(18, 6, 18, 8),
        child: Text(
          _statusText,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
        ),
      ),
    );
  }

  String get _statusText {
    switch (_event.phase) {
      case EllieVoicePhase.listening:
        return _event.transcript?.trim().isNotEmpty == true
            ? _event.transcript!.trim()
            : (_event.language == EllieLanguage.arabic
                ? 'أستمع الآن… قولي «إيلي» ثم طلبك.'
                : 'Listening… say “Ellie” and your request.');
      case EllieVoicePhase.thinking:
        return _event.language == EllieLanguage.arabic
            ? 'إيلي تفكّر…'
            : 'Ellie is thinking…';
      case EllieVoicePhase.speaking:
        return _event.language == EllieLanguage.arabic
            ? 'إيلي تتحدث…'
            : 'Ellie is speaking…';
      case EllieVoicePhase.error:
        return _event.language == EllieLanguage.arabic
            ? 'تحتاج إيلي إلى انتباهك.'
            : 'Ellie needs your attention.';
      case EllieVoicePhase.idle:
        return _event.warning ??
            (_event.language == EllieLanguage.arabic
                ? 'اضغطي على الميكروفون للتحدث.'
                : 'Tap the microphone to talk.');
    }
  }

  Widget _buildComposer(BuildContext context, {required bool listening}) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        14,
        0,
        14,
        10 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Semantics(
            button: true,
            label: listening
                ? 'Stop listening · إيقاف الاستماع'
                : 'Talk to Ellie · تحدثي إلى إيلي',
            child: IconButton.filled(
              onPressed: _isBusy ? null : () => unawaited(_toggleListening()),
              style: IconButton.styleFrom(
                backgroundColor: listening ? colors.error : colors.primary,
                foregroundColor: Colors.white,
                minimumSize: const Size(50, 50),
              ),
              icon: Icon(
                listening ? Icons.stop_rounded : Icons.mic_rounded,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _textController,
              enabled: !_isBusy,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => unawaited(_sendTypedMessage()),
              decoration: InputDecoration(
                hintText: 'Message Ellie · اكتبي لإيلي',
                filled: true,
                fillColor: colors.surfaceContainerHighest.withValues(alpha: 0.55),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide.none,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Send · إرسال',
            onPressed: _isBusy ? null : () => unawaited(_sendTypedMessage()),
            icon: const Icon(Icons.send_rounded),
          ),
        ],
      ),
    );
  }
}

class _EllieMessage {
  const _EllieMessage({
    required this.text,
    required this.language,
    this.isUser = false,
    this.isSystem = false,
  });

  final String text;
  final EllieLanguage language;
  final bool isUser;
  final bool isSystem;
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final _EllieMessage message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final alignment = message.isUser ? Alignment.centerRight : Alignment.centerLeft;
    final bubbleColor = message.isSystem
        ? colors.errorContainer
        : message.isUser
            ? colors.primary
            : colors.surfaceContainerHighest;
    final textColor = message.isSystem
        ? colors.onErrorContainer
        : message.isUser
            ? colors.onPrimary
            : colors.onSurface;

    return Align(
      alignment: alignment,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.78,
        ),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(message.isUser ? 18 : 4),
            bottomRight: Radius.circular(message.isUser ? 4 : 18),
          ),
        ),
        child: Directionality(
          textDirection: message.language == EllieLanguage.arabic
              ? TextDirection.rtl
              : TextDirection.ltr,
          child: Text(
            message.text,
            style: TextStyle(color: textColor, height: 1.35),
          ),
        ),
      ),
    );
  }
}
