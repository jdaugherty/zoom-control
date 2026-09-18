// Copyright (c) 2026 The Zoom Control Authors — SPDX-License-Identifier: MIT
import { WebSocketServer, WebSocket } from 'ws';
import { createInterface } from 'node:readline';

const server = new WebSocketServer({ host: '127.0.0.1', port: 47337 });
let position = 0;
let remaining = 8 * 3600;
let take = 1;
let suppressStatus = false;
const status = {
  type: 'status', phase: 'ready', connected: true,
  device: 'SIMULATED H6', model: 'Simulator', firmware: 'demo',
  state: 'STOP', stateCode: 0, sampleRate: '48 kHz', battery: 4,
  powerSource: 'Battery', card: 1, meterChannels: 2, meterL: 0, meterR: 0,
  playFileName: 'DEMO0001.WAV',
};
const time = (seconds) => [Math.floor(seconds / 3600), Math.floor(seconds / 60) % 60, seconds % 60]
  .map((n) => String(n).padStart(2, '0')).join(':');

function send(socket, message) {
  if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
}
function broadcast() {
  if (suppressStatus) return;
  status.locator = time(position);
  status.remain = time(remaining);
  for (const socket of server.clients) send(socket, status);
}
function key(key) {
  if (!status.connected) return;
  if (key === 'rec') {
    position = 0;
    status.recFileName = `DEMO${String(take++).padStart(4, '0')}.WAV`;
    status.stateCode = 1; status.state = 'REC';
  } else if (key === 'stop') {
    if (status.stateCode === 1) status.playFileName = status.recFileName;
    status.stateCode = 0; status.state = 'STOP';
  } else if (key === 'play') {
    status.stateCode = status.stateCode === 3 ? 4 : 3;
    status.state = status.stateCode === 3 ? 'PLAY' : 'PLAY_PAUSE';
  }
  broadcast();
}
server.on('connection', (socket) => {
  broadcast();
  socket.on('error', (error) => console.error(error.message));
  socket.on('message', (data) => {
    let message;
    try { message = JSON.parse(data); } catch { return; }
    if (message.cmd === 'status') broadcast();
    else if (message.cmd === 'key') key(message.key);
    else if (message.cmd === 'toggleRecord') key([1, 2].includes(status.stateCode) ? 'stop' : 'rec');
    send(socket, { type: 'ack', cmd: message.cmd });
  });
});
server.on('error', (error) => {
  console.error(error.code === 'EADDRINUSE' ? 'Port 47337 is occupied. Quit Zoom Control or the other simulator first.' : error.message);
  process.exit(1);
});
const meters = setInterval(() => {
  status.meterL = status.connected ? Math.round(60 + 40 * Math.sin(Date.now() / 450)) : 0;
  status.meterR = status.connected ? Math.round(50 + 35 * Math.sin(Date.now() / 620)) : 0;
  broadcast();
}, 125);
const clock = setInterval(() => {
  if (status.connected && [1, 3].includes(status.stateCode)) position++;
  if (status.connected && status.stateCode === 1) remaining = Math.max(0, remaining - 1);
}, 1000);
const input = createInterface({ input: process.stdin, output: process.stdout });
input.on('line', (line) => {
  switch (line.trim()) {
    case 'rec': case 'stop': case 'play': key(line.trim()); break;
    case 'offline': status.connected = false; status.phase = 'idle'; break;
    case 'online': status.connected = true; status.phase = 'ready'; break;
    case 'silent': suppressStatus = !suppressStatus; break;
    case 'battery': status.battery = status.battery === 1 ? 4 : 1; break;
    case 'message': status.popup = status.popup ? undefined : 'Demo recorder message'; break;
    case 'quit': shutdown(); break;
    default: console.log('Commands: rec, stop, play, offline, online, silent, battery, message, quit');
  }
  broadcast();
});
function shutdown() {
  clearInterval(meters); clearInterval(clock); input.close();
  for (const socket of server.clients) socket.terminate();
  server.close();
}
process.once('SIGINT', shutdown);
process.once('SIGTERM', shutdown);
server.on('listening', () => console.log('Simulated recorder on ws://127.0.0.1:47337\nCommands: rec, stop, play, offline, online, silent, battery, message, quit'));
