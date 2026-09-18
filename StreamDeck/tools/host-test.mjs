// Copyright (c) 2026 The Zoom Control Authors — SPDX-License-Identifier: MIT
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';

// Bind the recorder port before starting the plugin so this test can never send to a real recorder.
const api = new WebSocketServer({ host: '127.0.0.1', port: 47337 });
try { await once(api, 'listening'); } catch (error) {
  console.error(`Cannot start isolated API fixture: ${error.message}. Quit Zoom Control / simulator first.`);
  process.exit(1);
}
const host = new WebSocketServer({ host: '127.0.0.1', port: 0 });
await once(host, 'listening');
const status = { type: 'status', phase: 'ready', connected: true, device: 'HOST TEST',
  state: 'STOP', stateCode: 0, locator: '00:00:00', remain: '08:00:00',
  battery: 3, powerSource: 'Battery', meterL: 64, meterR: 32 };
const received = [];
const commands = [];
let apiConnections = 0;
let peer;
function broadcast() {
  for (const socket of api.clients) socket.send(JSON.stringify(status));
}
api.on('connection', (socket) => {
  apiConnections++;
  socket.send(JSON.stringify(status));
  socket.on('message', (data) => {
    const command = JSON.parse(data);
    commands.push(command);
    if (command.key === 'rec') { status.state = 'REC'; status.stateCode = 1; }
    if (command.key === 'stop') { status.state = 'STOP'; status.stateCode = 0; }
    broadcast();
  });
});
host.on('connection', (socket) => {
  peer = socket;
  socket.on('message', (data) => received.push(JSON.parse(data)));
});
const pluginDir = fileURLToPath(new URL('../com.zoomcontrol.recorder.sdPlugin/', import.meta.url));
const child = spawn(process.execPath, ['bin/plugin.js', '-port', String(host.address().port),
  '-pluginUUID', 'test-plugin', '-registerEvent', 'registerPlugin', '-info', JSON.stringify({
    application: { version: '6.9.0', platform: 'mac', platformVersion: '13.0', language: 'en' },
    plugin: { uuid: 'com.zoomcontrol.recorder', version: '0.1.0.0' },
    devicePixelRatio: 2,
    devices: [
      { id: 'mini', name: 'Mini', type: 1, size: { columns: 3, rows: 2 } },
      { id: 'mobile', name: 'Mobile', type: 3, size: { columns: 5, rows: 3 } },
    ],
    colors: {},
  })], { cwd: pluginDir, stdio: ['ignore', 'pipe', 'pipe'] });
let output = '';
child.stdout.on('data', (data) => { output += data; });
child.stderr.on('data', (data) => { output += data; });
const exit = once(child, 'exit');
async function waitFor(condition) {
  const end = Date.now() + 5000;
  while (!condition()) {
    if (child.exitCode !== null || Date.now() > end) throw new Error(`Plugin host check timed out.\n${output}`);
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}
function event(name, context, kind, settings = {}, multiAction = false) {
  peer.send(JSON.stringify({ event: name, context, action: `com.zoomcontrol.recorder.${kind}`,
    device: context.startsWith('mobile') ? 'mobile' : 'mini',
    payload: { controller: 'Keypad', ...(multiAction ? {} : { coordinates: { column: 0, row: 0 } }),
      settings, state: 0, isInMultiAction: multiAction } }));
}
function imageContains(context, text) {
  const image = received.findLast((message) => message.event === 'setImage' && message.context === context);
  return image && decodeURIComponent(image.payload.image).includes(text);
}
try {
  await waitFor(() => received.some((message) => message.event === 'registerPlugin'));
  event('willAppear', 'mini-toggle', 'toggle');
  event('willAppear', 'mobile-toggle', 'toggle');
  event('willAppear', 'mini-remaining', 'status', { field: 'remaining' });
  event('willAppear', 'mobile-power', 'status', { field: 'power' });
  await waitFor(() => imageContains('mini-toggle', 'STOPPED') && imageContains('mobile-toggle', 'STOPPED'));
  await waitFor(() => imageContains('mini-remaining', '08:00:00') && imageContains('mobile-power', 'Medium'));
  assert.equal(apiConnections, 1, 'all keys/devices must share one API connection');
  event('keyDown', 'mini-toggle', 'toggle');
  await waitFor(() => imageContains('mini-toggle', '>REC<') && imageContains('mobile-toggle', '>REC<'));
  event('keyDown', 'mobile-toggle', 'toggle');
  await waitFor(() => imageContains('mini-toggle', 'STOPPED') && imageContains('mobile-toggle', 'STOPPED'));
  assert.deepEqual(commands.filter((c) => c.cmd === 'key').map((c) => c.key), ['rec', 'stop']);
  event('willAppear', 'mini-multi-toggle', 'toggle', {}, true);
  event('keyDown', 'mini-multi-toggle', 'toggle', {}, true);
  await waitFor(() => imageContains('mobile-toggle', '>REC<'));
  event('keyDown', 'mini-multi-toggle', 'toggle', {}, true);
  await waitFor(() => imageContains('mobile-toggle', 'STOPPED'));
  assert.deepEqual(commands.filter((c) => c.cmd === 'key').map((c) => c.key), ['rec', 'stop', 'rec', 'stop']);
  event('didReceiveSettings', 'mobile-power', 'status', { field: 'device' });
  await waitFor(() => imageContains('mobile-power', 'HOST TEST'));
  assert.ok(imageContains('mini-remaining', '08:00:00'), 'tile settings remain independent');
  event('willDisappear', 'mini-remaining', 'status');
  await new Promise((resolve) => setTimeout(resolve, 30));
  const before = received.filter((message) => message.context === 'mini-remaining').length;
  status.remain = '07:59:00';
  status.connected = false; status.phase = 'idle'; broadcast();
  await waitFor(() => imageContains('mobile-toggle', 'DISCONNECTED'));
  assert.equal(received.filter((message) => message.context === 'mini-remaining').length, before);
  event('keyDown', 'mobile-toggle', 'toggle');
  await waitFor(() => received.some((message) => message.event === 'showAlert' && message.context === 'mobile-toggle'));
  assert.equal(commands.filter((c) => c.cmd === 'key').length, 4);
  console.log('PASS: built plugin registers, shares one connection, synchronizes Mini/Mobile transport, toggles inside Multi Actions, updates per-key settings, releases hidden keys, and rejects offline commands.');
} finally {
  child.kill('SIGTERM');
  await exit;
  for (const server of [host, api]) {
    for (const socket of server.clients) socket.terminate();
    await new Promise((resolve) => server.close(resolve));
  }
}
