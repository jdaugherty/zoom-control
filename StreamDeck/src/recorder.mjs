// Copyright (c) 2026 The Zoom Control Authors — SPDX-License-Identifier: MIT
import { EventEmitter } from 'node:events';
import WebSocket from 'ws';

export const ENDPOINT = 'ws://127.0.0.1:47337';

// Only copy fields we understand. Missing optional fields clear the old snapshot.
export function parseStatus(message) {
  if (!message || message.type !== 'status' || typeof message.connected !== 'boolean' ||
      typeof message.phase !== 'string') return null;
  const status = { connected: message.connected && message.phase === 'ready', phase: message.phase };
  for (const key of ['device', 'model', 'firmware', 'state', 'locator', 'remain', 'sampleRate',
    'powerSource', 'recFileName', 'playFileName', 'popup', 'error']) {
    if (typeof message[key] === 'string') status[key] = message[key].slice(0, 1024);
  }
  for (const key of ['stateCode', 'battery', 'card', 'meterChannels', 'meterL', 'meterR']) {
    if (Number.isFinite(message[key])) status[key] = message[key];
  }
  return status;
}

export function transportRequest(operation, status) {
  if (!status?.connected) throw new Error('Recorder is not ready');
  const state = status.stateCode;
  if (!Number.isInteger(state) || state < 0 || state > 8) throw new Error('Recorder state is unknown');
  const recording = state === 1 || state === 2;
  if (operation === 'toggle') operation = recording ? 'stop' : 'record';
  if (operation === 'record') {
    // Explicit Record is idempotent for Multi Actions; never send a second REC to pause a take.
    if (recording) return null;
    return { command: { cmd: 'key', key: 'rec' }, expected: [1, 2] };
  }
  if (operation === 'stop') {
    if (state === 0) return null;
    return { command: { cmd: 'key', key: 'stop' }, expected: [0] };
  }
  if (operation === 'play') {
    return { command: { cmd: 'key', key: 'play' }, expected: state === 3 ? [4] : [3] };
  }
  throw new Error('Unknown transport action');
}

export class RecorderConnection extends EventEmitter {
  constructor({ url = ENDPOINT, retryMs = 1500, heartbeatMs = 2000, staleMs = 6500,
    commandTimeoutMs = 4000 } = {}) {
    super();
    Object.assign(this, { url, retryMs, heartbeatMs, staleMs, commandTimeoutMs });
    this.snapshot = { appConnected: false, status: null, pending: false };
    this.running = false;
    this.lastStatus = 0;
  }

  start() {
    if (this.running) return;
    this.running = true;
    this.connect();
  }

  publish(update) {
    this.snapshot = { ...this.snapshot, ...update };
    this.emit('change', this.snapshot);
  }

  connect() {
    if (!this.running) return;
    const socket = this.socket = new WebSocket(this.url, { handshakeTimeout: 3000, maxPayload: 64 * 1024 });
    socket.on('open', () => {
      if (socket !== this.socket) return;
      this.lastStatus = Date.now();
      this.publish({ appConnected: true, status: null });
      socket.send(JSON.stringify({ cmd: 'status' }));
      this.heartbeat = setInterval(() => {
        if (Date.now() - this.lastStatus > this.staleMs) {
          this.failPending(new Error('Recorder status feed timed out'));
          this.publish({ appConnected: false, status: null });
          socket.terminate();
        } else if (socket.readyState === WebSocket.OPEN) {
          socket.send(JSON.stringify({ cmd: 'status' }));
        }
      }, this.heartbeatMs);
    });
    socket.on('message', (data) => {
      if (socket !== this.socket) return;
      let message;
      try { message = JSON.parse(data.toString()); } catch { return; }
      const status = parseStatus(message);
      if (status) {
        this.lastStatus = Date.now();
        this.publish({ status });
        if (!status.connected) this.failPending(new Error('Recorder disconnected'));
        else if (this.pending?.expected.includes(status.stateCode)) this.finishPending();
      } else if (message?.type === 'error') {
        this.failPending(new Error(typeof message.message === 'string' ? message.message : 'Recorder command failed'));
      }
      // An ack only confirms API receipt, not that the recorder performed the operation.
    });
    socket.on('error', () => { /* close handles reconnect; never queue/replay a transport command */ });
    socket.on('close', () => {
      if (socket !== this.socket) return;
      clearInterval(this.heartbeat);
      this.failPending(new Error('Zoom Control app disconnected'));
      this.publish({ appConnected: false, status: null });
      if (this.running) this.retry = setTimeout(() => this.connect(), this.retryMs);
    });
  }

  async command(operation) {
    if (this.socket?.readyState !== WebSocket.OPEN || !this.snapshot.appConnected) {
      throw new Error('Open Zoom Control on this Mac first');
    }
    if (Date.now() - this.lastStatus > this.staleMs) throw new Error('Recorder status is stale');
    if (this.pending) throw new Error('Waiting for the recorder to confirm the previous command');
    const request = transportRequest(operation, this.snapshot.status);
    if (!request) return;
    return new Promise((resolve, reject) => {
      this.pending = { ...request, resolve, reject,
        timer: setTimeout(() => this.failPending(new Error('Recorder did not confirm the requested state')), this.commandTimeoutMs) };
      this.publish({ pending: true });
      this.socket.send(JSON.stringify(request.command), (error) => {
        if (error) this.failPending(error);
      });
    });
  }

  finishPending(error) {
    const pending = this.pending;
    if (!pending) return;
    this.pending = null;
    clearTimeout(pending.timer);
    this.publish({ pending: false });
    if (error) pending.reject(error); else pending.resolve();
  }

  failPending(error) { this.finishPending(error); }

  stop() {
    this.running = false;
    clearTimeout(this.retry);
    clearInterval(this.heartbeat);
    this.failPending(new Error('Plugin connection closed'));
    const socket = this.socket;
    this.socket = null;
    socket?.terminate();
    this.publish({ appConnected: false, status: null });
  }
}
