// Copyright (c) 2026 The Zoom Control Authors — SPDX-License-Identifier: MIT
import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { WebSocketServer } from 'ws';
import { RecorderConnection, parseStatus, transportRequest } from '../src/recorder.mjs';

const status = (stateCode = 0, extra = {}) => ({ type: 'status', connected: true, phase: 'ready', stateCode, ...extra });
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function waitFor(predicate, timeout = 2000) {
  const end = Date.now() + timeout;
  while (!predicate()) {
    if (Date.now() > end) throw new Error('Timed out waiting for test condition');
    await delay(5);
  }
}
async function fixture(t, options = {}) {
  const server = new WebSocketServer({ host: '127.0.0.1', port: 0 });
  await once(server, 'listening');
  const client = new RecorderConnection({ url: `ws://127.0.0.1:${server.address().port}`,
    heartbeatMs: 10000, retryMs: 20, commandTimeoutMs: 100, ...options });
  const peers = [];
  const commands = [];
  server.on('connection', (socket) => {
    peers.push(socket);
    socket.on('message', (data) => commands.push(JSON.parse(data)));
    socket.send(JSON.stringify(status()));
  });
  t.after(async () => {
    client.stop();
    for (const socket of server.clients) socket.terminate();
    await new Promise((resolve) => server.close(resolve));
  });
  client.start();
  await waitFor(() => client.snapshot.status?.connected);
  return { client, peers, commands };
}

test('status validates types, bounds text, and does not carry missing fields forward', () => {
  assert.equal(parseStatus({ type: 'ack' }), null);
  assert.equal(parseStatus({ type: 'status', connected: 'true', phase: 'ready' }), null);
  assert.equal(parseStatus(status(0, { phase: 'scanning' })).connected, false);
  const value = parseStatus(status(0, { popup: 'x'.repeat(2000), meterL: '127' }));
  assert.equal(value.popup.length, 1024);
  assert.equal(value.meterL, undefined);
  assert.equal(parseStatus(status()).popup, undefined);
});

test('explicit transport is idempotent and handles recording/playback pause states', () => {
  assert.equal(transportRequest('record', status(1)), null);
  assert.equal(transportRequest('record', status(2)), null);
  assert.equal(transportRequest('stop', status(0)), null);
  assert.equal(transportRequest('toggle', status(2)).command.key, 'stop');
  assert.equal(transportRequest('toggle', status(0)).command.key, 'rec');
  assert.deepEqual(transportRequest('play', status(3)).expected, [4]);
  assert.deepEqual(transportRequest('play', status(4)).expected, [3]);
  assert.throws(() => transportRequest('record', { connected: false }), /not ready/);
  assert.throws(() => transportRequest('record', { connected: true }), /unknown/);
});

test('ack alone never confirms recording; concurrent commands are rejected', async (t) => {
  const { client, peers, commands } = await fixture(t, { commandTimeoutMs: 1000 });
  const result = client.command('record');
  await waitFor(() => commands.some((c) => c.key === 'rec'));
  peers[0].send(JSON.stringify({ type: 'ack', cmd: 'key' }));
  await delay(20);
  assert.equal(client.snapshot.pending, true);
  await assert.rejects(client.command('stop'), /previous command/);
  peers[0].send(JSON.stringify(status(1)));
  await result;
  assert.equal(client.snapshot.pending, false);
});

test('unconfirmed command times out and is not replayed after reconnect', async (t) => {
  const { client, peers, commands } = await fixture(t);
  await assert.rejects(client.command('record'), /did not confirm/);
  peers[0].terminate();
  await waitFor(() => peers.length === 2 && client.snapshot.status?.connected);
  assert.equal(commands.filter((c) => c.key === 'rec').length, 1);
});

test('recorder disconnect clears command and renderer receives unavailable status', async (t) => {
  const { client, peers } = await fixture(t);
  const result = assert.rejects(client.command('record'), /disconnected/);
  peers[0].send(JSON.stringify(status(0, { connected: false, phase: 'idle', remain: 'OLD VALUE' })));
  await result;
  assert.equal(client.snapshot.status.connected, false);
  peers[0].terminate();
  await waitFor(() => !client.snapshot.appConnected);
  assert.equal(client.snapshot.status, null);
});

test('silent status feed is invalidated and connection is retried', async (t) => {
  const { client, peers } = await fixture(t, { heartbeatMs: 10, staleMs: 30, retryMs: 100 });
  await waitFor(() => !client.snapshot.appConnected);
  assert.equal(client.snapshot.status, null);
  await waitFor(() => peers.length >= 2);
});

test('malformed messages are ignored, API errors reject pending command', async (t) => {
  const { client, peers } = await fixture(t);
  const result = assert.rejects(client.command('record'), /example failure/);
  peers[0].send('not json');
  peers[0].send('null');
  peers[0].send(JSON.stringify({ type: 'error', message: 'example failure' }));
  await result;
});
