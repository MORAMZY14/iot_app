import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';

process.env.ELLIE_DEV_TOKEN = 'ellie-test-token';
process.env.ELLIE_PUBLIC_BASE_URL = 'https://ellie.example.com';

const { startServer } = await import('../server.mjs');
let server;
let baseUrl;

before(async () => {
  server = startServer(0);
  await new Promise((resolve) => server.once('listening', resolve));
  const address = server.address();
  baseUrl = `http://127.0.0.1:${address.port}`;
});

after(async () => {
  await new Promise((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
});

test('health endpoint is available', async () => {
  const response = await fetch(`${baseUrl}/health`);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    ok: true,
    service: 'ellie-bilingual',
  });
});

test('conversation requires a customer token', async () => {
  const response = await fetch(`${baseUrl}/v1/ellie/chat`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ message: 'Hello Ellie' }),
  });
  assert.equal(response.status, 401);
});

test('authenticated customers can create one-time speech tickets', async () => {
  const response = await fetch(`${baseUrl}/v1/ellie/speech-ticket`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: 'Bearer ellie-test-token',
    },
    body: JSON.stringify({ text: 'مرحباً، أنا إيلي.', language: 'ar' }),
  });
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.match(body.audioUrl, /^https:\/\/ellie\.example\.com\/v1\/ellie\/audio\/[a-f0-9]{32}$/);
  assert.equal(body.expiresInSeconds, 75);
});
