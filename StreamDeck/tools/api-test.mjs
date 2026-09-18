// Copyright (c) 2026 The Zoom Control Authors — SPDX-License-Identifier: MIT
import { RecorderConnection } from '../src/recorder.mjs';

// Read-only probe: works with either the simulator or the running Mac app.
const recorder = new RecorderConnection();
let count = 0;
const timeout = setTimeout(() => {
  console.error('No valid status received within 10 seconds. Open Zoom Control or run npm run simulate.');
  recorder.stop(); process.exitCode = 1;
}, 10_000);
recorder.on('change', ({ status }) => {
  if (!status) return;
  if (count++ === 0) console.log(JSON.stringify(status, null, 2));
  if (count >= 3) {
    clearTimeout(timeout);
    console.log('Received three valid status snapshots. No transport commands sent.');
    recorder.stop();
  }
});
recorder.start();
