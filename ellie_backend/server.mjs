import { randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';

import cors from 'cors';
import 'dotenv/config';
import express from 'express';
import rateLimit from 'express-rate-limit';
import { applicationDefault, getApps, initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import helmet from 'helmet';
import OpenAI from 'openai';

const port = Number.parseInt(process.env.PORT ?? '8080', 10);
const model = process.env.ELLIE_MODEL ?? 'gpt-5.6';
const ttsModel = process.env.ELLIE_TTS_MODEL ?? 'gpt-4o-mini-tts';
const ttsVoice = process.env.ELLIE_TTS_VOICE ?? 'marin';
const production = process.env.NODE_ENV === 'production';
const allowedOrigins = (process.env.ELLIE_ALLOWED_ORIGINS ?? '')
  .split(',')
  .map((value) => value.trim())
  .filter(Boolean);
const speechTickets = new Map();
const speechTicketLifetimeMs = 75_000;
const maxSpeechTickets = 200;

let openai;

function getOpenAI() {
  if (!process.env.OPENAI_API_KEY) {
    throw new Error('OPENAI_API_KEY is not configured.');
  }
  openai ??= new OpenAI({
    apiKey: process.env.OPENAI_API_KEY,
    timeout: 22_000,
    maxRetries: 1,
  });
  return openai;
}

function languageFor(value, text = '') {
  if (value === 'ar' || value === 'en') return value;
  return /[\u0600-\u06ff\u0750-\u077f\u08a0-\u08ff]/u.test(text)
    ? 'ar'
    : 'en';
}

function sanitizeHistory(value) {
  if (!Array.isArray(value)) return [];
  return value
    .slice(-10)
    .filter(
      (item) =>
        item &&
        (item.role === 'user' || item.role === 'assistant') &&
        typeof item.content === 'string',
    )
    .map((item) => ({
      role: item.role,
      content: item.content.trim().slice(0, 1000),
    }))
    .filter((item) => item.content.length > 0);
}

function customerInstructions(language) {
  const languageInstruction = language === 'ar'
    ? 'Reply in natural Arabic. Match a clearly used Arabic dialect; otherwise use clear Modern Standard Arabic.'
    : 'Reply in natural English.';
  return [
    'You are Ellie, a warm and concise smart-home companion.',
    languageInstruction,
    'Use one or two short sentences suitable for text-to-speech.',
    'The ESP32 handles all hardware actions locally. Never claim that you changed a device, relay, room, lock, or appliance.',
    'If the user asks you to operate hardware, tell them to use a direct Ellie home command in the app.',
    'Do not request passwords, API keys, payment information, or other secrets.',
    'Use plain text without markdown.',
  ].join(' ');
}

function publicAudioBaseUrl() {
  const configured = process.env.ELLIE_PUBLIC_BASE_URL?.trim();
  if (!configured) throw new Error('ELLIE_PUBLIC_BASE_URL is not configured.');
  const parsed = new URL(configured);
  if (parsed.protocol !== 'https:') {
    throw new Error('ELLIE_PUBLIC_BASE_URL must use HTTPS.');
  }
  return parsed;
}

function purgeExpiredTickets(now = Date.now()) {
  for (const [id, ticket] of speechTickets.entries()) {
    if (ticket.expiresAt <= now) speechTickets.delete(id);
  }
  while (speechTickets.size > maxSpeechTickets) {
    const oldest = speechTickets.keys().next().value;
    if (!oldest) break;
    speechTickets.delete(oldest);
  }
}

async function verifyCustomer(request, response, next) {
  const authorization = request.get('authorization') ?? '';
  const match = /^Bearer\s+(.+)$/i.exec(authorization);
  if (!match) {
    return response.status(401).json({ error: 'Missing bearer token.' });
  }

  const token = match[1];
  const developmentToken = process.env.ELLIE_DEV_TOKEN;
  if (!production && developmentToken && token === developmentToken) {
    request.customer = { uid: 'local-development' };
    return next();
  }

  try {
    if (getApps().length === 0) {
      initializeApp({ credential: applicationDefault() });
    }
    request.customer = await getAuth().verifyIdToken(token, true);
    return next();
  } catch {
    return response.status(401).json({
      error: 'Invalid or expired identity token.',
    });
  }
}

export const app = express();

app.disable('x-powered-by');
app.set('trust proxy', 1);
app.use(helmet());
app.use(express.json({ limit: '16kb' }));
app.use(
  cors({
    origin(origin, callback) {
      // Native Flutter HTTP requests do not include a browser Origin header.
      if (!origin) return callback(null, true);
      const localDevelopment =
        !production && /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin);
      if (localDevelopment || allowedOrigins.includes(origin)) {
        return callback(null, true);
      }
      return callback(new Error('Origin is not allowed.'));
    },
  }),
);
app.use(
  '/v1/ellie',
  rateLimit({
    windowMs: 60_000,
    limit: 30,
    standardHeaders: 'draft-8',
    legacyHeaders: false,
  }),
);

app.get('/health', (_request, response) => {
  response.json({ ok: true, service: 'ellie-bilingual' });
});

app.post('/v1/ellie/chat', verifyCustomer, async (request, response) => {
  const message = typeof request.body?.message === 'string'
    ? request.body.message.trim()
    : '';
  const conversationId = typeof request.body?.conversationId === 'string'
    ? request.body.conversationId.slice(0, 128)
    : '';

  if (message.length === 0 || message.length > 600) {
    return response.status(400).json({
      error: 'Message must contain 1 to 600 characters.',
    });
  }

  const language = languageFor(request.body?.language, message);
  const history = sanitizeHistory(request.body?.history);
  const input = [...history, { role: 'user', content: message }];

  try {
    const aiResponse = await getOpenAI().responses.create({
      model,
      store: false,
      max_output_tokens: 600,
      instructions: customerInstructions(language),
      input,
    });

    const reply = aiResponse.output_text.trim().slice(0, 700);
    if (!reply) throw new Error('The model returned no text.');
    return response.json({ reply, language, conversationId });
  } catch (error) {
    console.error('Ellie model request failed', {
      name: error?.name,
      message: error?.message,
      customerUid: request.customer?.uid,
    });
    return response.status(503).json({
      error: 'Ellie conversation is temporarily unavailable.',
    });
  }
});

app.post(
  '/v1/ellie/speech-ticket',
  verifyCustomer,
  async (request, response) => {
    const text = typeof request.body?.text === 'string'
      ? request.body.text.trim()
      : '';
    if (text.length === 0 || text.length > 220) {
      return response.status(400).json({
        error: 'Speech text must contain 1 to 220 characters.',
      });
    }

    try {
      const language = languageFor(request.body?.language, text);
      const publicBase = publicAudioBaseUrl();
      purgeExpiredTickets();
      const id = randomUUID().replaceAll('-', '');
      const expiresAt = Date.now() + speechTicketLifetimeMs;
      speechTickets.set(id, {
        text,
        language,
        customerUid: request.customer?.uid,
        expiresAt,
      });
      const audioUrl = new URL(`/v1/ellie/audio/${id}`, publicBase);
      return response.json({
        audioUrl: audioUrl.toString(),
        expiresInSeconds: Math.floor(speechTicketLifetimeMs / 1000),
      });
    } catch (error) {
      console.error('Ellie speech ticket failed', {
        name: error?.name,
        message: error?.message,
      });
      return response.status(503).json({ error: 'Cloud speech is unavailable.' });
    }
  },
);

// This URL is intentionally one-time, random, short-lived, and contains no
// customer credential. It lets the ESP32 fetch audio without storing a Firebase
// token or OpenAI API key in firmware.
app.get('/v1/ellie/audio/:ticket', async (request, response) => {
  const id = request.params.ticket;
  if (!/^[a-f0-9]{32}$/.test(id)) {
    return response.status(404).end();
  }
  purgeExpiredTickets();
  const ticket = speechTickets.get(id);
  if (!ticket || ticket.expiresAt <= Date.now()) {
    speechTickets.delete(id);
    return response.status(404).end();
  }
  // Consume before generation so a ticket cannot be replayed concurrently.
  speechTickets.delete(id);

  try {
    const speech = await getOpenAI().audio.speech.create({
      model: ttsModel,
      voice: ttsVoice,
      input: ticket.text,
      instructions: ticket.language === 'ar'
        ? 'Speak in clear, warm, natural Arabic. Preserve the written dialect when possible.'
        : 'Speak in warm, clear, concise English.',
      response_format: 'mp3',
    });
    const audio = Buffer.from(await speech.arrayBuffer());
    response.set({
      'Content-Type': 'audio/mpeg',
      'Content-Length': String(audio.length),
      'Cache-Control': 'no-store, max-age=0',
      'X-Content-Type-Options': 'nosniff',
    });
    return response.status(200).send(audio);
  } catch (error) {
    console.error('Ellie speech generation failed', {
      name: error?.name,
      message: error?.message,
      customerUid: ticket.customerUid,
    });
    return response.status(503).json({ error: 'Speech generation failed.' });
  }
});

app.use((error, _request, response, _next) => {
  console.error('Ellie request failed', {
    name: error?.name,
    message: error?.message,
  });
  response.status(400).json({ error: 'Request rejected.' });
});

export function startServer(listenPort = port) {
  return app.listen(listenPort, () => {
    console.log(`Ellie backend listening on port ${listenPort}`);
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  startServer();
}
