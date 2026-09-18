// Copyright (c) 2026 The Zoom Control Authors — SPDX-License-Identifier: MIT
const escape = (value) => String(value).replace(/[&<>"']/g, (c) => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;',
})[c]);
const short = (value, length = 16) => {
  const chars = Array.from(value || '—');
  return chars.length > length ? chars.slice(0, length - 1).join('') + '…' : chars.join('');
};
const text = (value, y, size = 19, color = '#f4f6fa') =>
  `<text x="72" y="${y}" text-anchor="middle" font-family="Arial,Helvetica,sans-serif" font-size="${size}" font-weight="bold" fill="${color}">${escape(value)}</text>`;

function tile(title, value, footer = '', color = '#769bbd') {
  return `<rect x="4" y="4" width="136" height="136" rx="15" fill="#111923" stroke="${color}" stroke-width="4"/>` +
    text(short(title, 18), 31, 15, color) + text(short(value), 80, String(value).length > 10 ? 15 : 22) +
    text(short(footer, 19), 118, 13, '#b4c0cd');
}

function power(s) {
  if (s.battery >= 1 && s.battery <= 4) return ['Empty', 'Low', 'Medium', 'Full'][s.battery - 1];
  return '—';
}

export function renderKey(kind, settings, snapshot) {
  const s = snapshot.status;
  let body;
  if (!snapshot.appConnected) {
    body = tile('ZOOM CONTROL', 'APP OFFLINE', 'Open the Mac app', '#7e8996');
  } else if (!s) {
    body = tile('ZOOM CONTROL', 'WAITING', 'Reading status', '#dcb355');
  } else if (!s.connected) {
    const phases = { idle: 'DISCONNECTED', scanning: 'SEARCHING', connecting: 'CONNECTING',
      handshaking: 'CONNECTING', bluetoothOff: 'BLUETOOTH OFF', unauthorized: 'NO PERMISSION', failed: 'ERROR' };
    body = tile('RECORDER', phases[s.phase] || 'NOT READY', s.error || s.device || 'Control & Sync', '#dcb355');
  } else if (kind === 'meters') {
    const bar = (label, raw, y) => {
      const fraction = Math.max(0, Math.min(127, raw || 0)) / 127;
      const color = fraction > 0.9 ? '#ffb453' : '#4ade9b';
      return `<text x="12" y="${y + 14}" font-family="Arial" font-size="15" fill="#f4f6fa">${label}</text>` +
        `<rect x="30" y="${y}" width="101" height="20" rx="3" fill="#293748"/>` +
        `<rect x="30" y="${y}" width="${Math.round(fraction * 101)}" height="20" rx="3" fill="${color}"/>`;
    };
    body = tile('LEVELS', '', s.meterChannels === 1 ? 'MONO · relative' : 'STEREO · relative') +
      bar('L', s.meterL, 48) + (s.meterChannels === 1 ? '' : bar('R', s.meterR, 82));
  } else if (kind === 'status') {
    const fields = {
      connection: ['RECORDER', 'READY', s.device, '#4ade9b'],
      elapsed: ['POSITION', s.locator || '—', s.state],
      remaining: ['REMAINING', s.remain || '—', s.sampleRate],
      power: ['POWER', s.powerSource?.startsWith('External') ? 'EXTERNAL' : power(s), s.powerSource],
      sampleRate: ['SAMPLE RATE', s.sampleRate || '—', s.device],
      device: ['DEVICE', s.device || '—', s.model],
      firmware: ['FIRMWARE', s.firmware || '—', s.model],
      filename: ['CURRENT FILE', [1, 2].includes(s.stateCode) ? s.recFileName || '—' : s.playFileName || '—', s.state],
      card: ['CARD', ({ 0: 'NO CARD', 1: 'OK', 2: 'NOT PLAYABLE' })[s.card] || '—', 'Recorder status'],
      message: ['MESSAGE', s.popup || 'No message', s.device],
    };
    body = tile(...(fields[settings.field] || fields.connection));
  } else {
    const recording = [1, 2].includes(s.stateCode);
    const label = ({ toggle: 'REC / STOP', record: 'RECORD', stop: 'STOP', play: 'PLAY / PAUSE' })[kind];
    const stateLabel = ({ 0: 'STOPPED', 1: 'REC', 2: 'REC PAUSED', 3: 'PLAYING', 4: 'PLAY PAUSED',
      5: 'REW', 6: 'FF', 7: 'PREV', 8: 'NEXT' })[s.stateCode] || 'UNKNOWN';
    body = tile(label, stateLabel, snapshot.pending ? 'Waiting for recorder' :
      settings.showTime === false ? s.device : s.locator || '—', recording ? '#ff5264' : '#769bbd');
  }
  return `data:image/svg+xml,${encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144" viewBox="0 0 144 144"><rect width="144" height="144" fill="#0b1018"/>${body}</svg>`)}`;
}
