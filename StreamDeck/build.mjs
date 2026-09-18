// Copyright (c) 2026 The Zoom Control Authors — SPDX-License-Identifier: MIT
import { build, context } from 'esbuild';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const pluginDir = new URL('com.zoomcontrol.recorder.sdPlugin/', import.meta.url);
// Stream Deck requires PNG for the plugin-list icon; action images can remain SVG.
await sharp(fileURLToPath(new URL('imgs/plugin.svg', pluginDir)))
  .resize(256, 256).png().toFile(fileURLToPath(new URL('imgs/marketplace.png', pluginDir)));
await sharp(fileURLToPath(new URL('imgs/plugin.svg', pluginDir)))
  .resize(512, 512).png().toFile(fileURLToPath(new URL('imgs/marketplace@2x.png', pluginDir)));

const options = {
  absWorkingDir: fileURLToPath(new URL('.', import.meta.url)),
  entryPoints: ['src/plugin.mjs'],
  outfile: 'com.zoomcontrol.recorder.sdPlugin/bin/plugin.js',
  bundle: true,
  platform: 'node',
  format: 'esm',
  target: 'node20',
  // ws and SDK dependencies contain CommonJS requires of Node built-ins.
  banner: { js: 'import { createRequire } from "node:module"; const require = createRequire(import.meta.url);' },
  external: ['bufferutil', 'utf-8-validate'],
  logLevel: 'info',
};
if (process.argv.includes('--watch')) {
  const ctx = await context(options);
  await ctx.watch();
} else {
  await build(options);
}
