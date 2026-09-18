// Copyright (c) 2026 The Zoom Control Authors — SPDX-License-Identifier: MIT
import test from 'node:test';
import assert from 'node:assert/strict';
import sharp from 'sharp';
import { renderKey } from '../src/render.mjs';

const snapshot = (status = {}) => ({ appConnected: true, pending: false,
  status: { connected: true, phase: 'ready', stateCode: 0, ...status } });
const svg = (kind, settings, state) => decodeURIComponent(renderKey(kind, settings, state).split(',').slice(1).join(','));

test('all display modes produce rasterizable SVG for Mini and Mobile', async () => {
  const state = snapshot({ device: 'H6studio', stateCode: 1, state: 'REC', locator: '00:12:34',
    remain: '739:57:33', sampleRate: '48 kHz', meterL: 85, meterR: 35, battery: 4,
    powerSource: 'Battery', card: 2, recFileName: 'A&B <take>.WAV' });
  const images = ['record', 'stop', 'toggle', 'play', 'meters'].map((kind) => svg(kind, {}, state));
  for (const field of ['connection', 'elapsed', 'remaining', 'power', 'sampleRate', 'device',
    'firmware', 'filename', 'card', 'message']) images.push(svg('status', { field }, state));
  for (const image of images) {
    const { info } = await sharp(Buffer.from(image)).resize(72, 72).png().toBuffer({ resolveWithObject: true });
    assert.equal(info.width, 72);
  }
});

test('offline and unready keys never display cached metadata as current', () => {
  const stale = snapshot({ connected: false, phase: 'idle', remain: 'OLD VALUE', stateCode: 1 });
  assert.match(svg('status', { field: 'remaining' }, stale), /DISCONNECTED/);
  assert.doesNotMatch(svg('status', { field: 'remaining' }, stale), /OLD VALUE/);
  assert.match(svg('toggle', {}, { ...stale, appConnected: false }), /APP OFFLINE/);
  assert.match(svg('toggle', {}, { appConnected: true, status: null }), /WAITING/);
});

test('filename switches by transport state and safely escapes recorder text', () => {
  const state = snapshot({ stateCode: 1, recFileName: 'A&B<.WAV', playFileName: 'PLAY.WAV' });
  assert.match(svg('status', { field: 'filename' }, state), /A&amp;B&lt;.WAV/);
  assert.doesNotMatch(svg('status', { field: 'filename' }, state), /PLAY.WAV/);
  state.status.stateCode = 0;
  assert.match(svg('status', { field: 'filename' }, state), /PLAY.WAV/);
});

test('meters clamp levels and metadata avoids invented percentages or dBFS', () => {
  const image = svg('meters', {}, snapshot({ meterL: 999, meterR: -20 }));
  assert.doesNotMatch(image, /width="-/);
  assert.match(image, /relative/);
  assert.match(svg('status', { field: 'power' }, snapshot({ battery: 0 })), /—/);
  assert.match(svg('status', { field: 'power' }, snapshot({ battery: 3 })), /Medium/);
});
