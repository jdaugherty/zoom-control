// Copyright (c) 2026 The Zoom Control Authors — SPDX-License-Identifier: MIT
let socket, context, settings = {};
const field = document.getElementById('field');
const showTime = document.getElementById('show-time');

function update(value) {
  settings = value || {};
  field.value = settings.field || 'connection';
  showTime.checked = settings.showTime !== false;
}

function save(patch) {
  settings = { ...settings, ...patch };
  if (socket?.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify({ event: 'setSettings', context, payload: settings }));
  }
}

// Called by the Stream Deck desktop application when this inspector is opened.
window.connectElgatoStreamDeckSocket = (port, uuid, registerEvent, info, actionInfo) => {
  const action = JSON.parse(actionInfo);
  context = uuid;
  update(action.payload.settings);
  const kind = action.action.split('.').at(-1);
  document.getElementById('status-settings').hidden = kind !== 'status';
  document.getElementById('meter-settings').hidden = kind !== 'meters';
  document.getElementById('transport-settings').hidden = !['record', 'stop', 'toggle', 'play'].includes(kind);
  socket = new WebSocket(`ws://127.0.0.1:${port}`);
  socket.onopen = () => socket.send(JSON.stringify({ event: registerEvent, uuid }));
  socket.onmessage = ({ data }) => {
    const message = JSON.parse(data);
    if (message.event === 'didReceiveSettings') update(message.payload.settings);
  };
};
field.addEventListener('change', () => save({ field: field.value }));
showTime.addEventListener('change', () => save({ showTime: showTime.checked }));
