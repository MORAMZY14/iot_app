# IoT Smart Home with Ellie

This Flutter project now includes **Ellie / إيلي**, a bilingual English and
Arabic smart-home assistant.

## Included behavior

- Tap the Ellie waveform button in the dashboard app bar to open the assistant.
- Speak short commands with the phone microphone or type a message.
- Choose **Auto**, **English**, or **العربية** recognition.
- Say “Ellie” or “إيلي” before the first voice request. The conversation stays
  active for 30 seconds after that.
- Deterministic home commands are processed locally by the ESP32 over Wi-Fi,
  with the app's existing BLE service as a fallback.
- Open-ended conversation uses the authenticated backend in `ellie_backend/`.
- Replies use the matching English or Arabic phone TTS voice.
- English ESP32 speech works offline. Arabic ESP32 speech uses a short-lived,
  one-time cloud-audio ticket; no OpenAI or Firebase key is stored in firmware.
- The cloud model is not given any tool or endpoint that can operate relays.

The microphone is push-to-talk. The underlying phone recognizer is intended for
commands and short phrases, not an always-on background wake-word service.

## 1. Fetch Flutter packages

Use a current Flutter installation, then run:

```bash
flutter pub get
```

The added packages are `speech_to_text` 7.4.0 and `flutter_tts` 4.2.5. This
project targets iOS 15.0 consistently in the Podfile, Runner project, and
Flutter framework metadata. On iOS, regenerate configuration and install pods:

```bash
flutter clean
flutter pub get
flutter build ios --config-only
cd ios
pod install --repo-update
```

The included GitHub Actions workflow creates `iot.ipa` without code signing,
matching the external re-signing flow used by the original project. It pins
Flutter 3.44.2, preserves the checked-in Podfile, validates the Firebase bundle
ID, and checks the built Runner/Flutter/App frameworks before packaging. The
iOS target temporarily keeps the original, known-working AppDelegate lifecycle;
automatic UIScene migration is disabled until all native plugins in this app
can be tested together after migration. The resulting IPA must still be signed
by the same valid certificate/provisioning process used for the working build.

Install English and Arabic speech-recognition/TTS voices in the phone's system
settings for reliable offline phone commands. Auto mode starts with the phone's
English/Arabic locale and remembers the language detected in the latest turn;
the explicit language buttons are best when switching languages.

## 2. Flash the matching ESP32 firmware

Flash `ESP32_SmartHome_Ellie_Bilingual.ino`. It keeps the existing smart-home
APIs and adds:

- `POST /api/ellie` — bilingual local intent parsing
- `POST /api/ellie/speak` — offline English speaker queue
- `POST /api/ellie/audio` — one-time HTTPS MP3 playback for Arabic
- `GET /api/ellie/capabilities`

The MAX98357A defaults are BCLK GPIO 26, LRC/WS GPIO 25, and DIN GPIO 27.
Install the Arduino libraries already used by the original firmware plus
NimBLE-Arduino, ArduinoJson, DHT sensor library, and ESP8266Audio.

`ESP8266Audio` is GPL-3.0. Review its obligations before commercial firmware
distribution. The cloud-audio downloader currently uses `setInsecure()` for a
one-time credential-free URL, matching the existing Firebase TLS approach in
the supplied firmware. For a production appliance, pin your backend root CA
with `setCACert()`.

## 3. Deploy the secure Ellie backend

```bash
cd ellie_backend
npm install
cp .env.example .env
# Configure the environment in your deployment platform, then:
npm test
npm start
```

Required production values:

- `OPENAI_API_KEY` — server only; never add it to Flutter or ESP32 code
- `ELLIE_PUBLIC_BASE_URL` — the public HTTPS origin of this backend
- Firebase Admin application-default credentials for the same Firebase project
- `ELLIE_ALLOWED_ORIGINS` when Flutter Web is deployed

`ELLIE_DEV_TOKEN` is accepted only when `NODE_ENV` is not `production`.

The backend uses the OpenAI Responses API for conversation and
`gpt-4o-mini-tts` for ESP32 Arabic speech. End users must be told that this
cloud voice is AI-generated; the Ellie sheet includes that disclosure.

## 4. Point Flutter at the backend

Do not hard-code a secret. Pass only the public backend URL:

```bash
flutter run \
  --dart-define=ELLIE_BACKEND_URL=https://ellie.example.com
```

Without this value, bilingual offline home commands and phone TTS still work;
open conversation and Arabic ESP32 speech remain unavailable.

## Commands to test

English:

- “Ellie, turn on the kitchen light.”
- “Ellie, what is the temperature?”
- “Ellie, tell me a short story.”

Arabic / Egyptian Arabic:

- “إيلي، شغلي نور المطبخ.”
- “إيلي، اطفي كل الأنوار.”
- “إيلي، درجة الحرارة كام؟”
- “إيلي، احكيلي قصة قصيرة.”
