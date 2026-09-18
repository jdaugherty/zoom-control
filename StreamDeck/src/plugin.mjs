// Copyright (c) 2026 The Zoom Control Authors — SPDX-License-Identifier: MIT
import streamDeck, { SingletonAction } from '@elgato/streamdeck';
import { RecorderConnection } from './recorder.mjs';
import { renderKey } from './render.mjs';

const recorder = new RecorderConnection();

class RecorderAction extends SingletonAction {
  constructor(kind) {
    super();
    this.kind = kind;
    this.manifestId = `com.zoomcontrol.recorder.${kind}`;
    this.visible = new Map();
    recorder.on('change', () => {
      for (const view of this.visible.values()) this.render(view);
    });
  }

  onWillAppear(ev) {
    if (!ev.action.isKey()) return;
    const view = { action: ev.action, settings: ev.payload.settings, active: true };
    this.visible.set(ev.action.id, view);
    // Text is drawn into SVG so it stays readable on both Mini and Mobile.
    ev.action.setTitle('').catch((error) => streamDeck.logger.error(error));
    this.render(view);
  }

  onWillDisappear(ev) {
    const view = this.visible.get(ev.action.id);
    if (view) view.active = false;
    this.visible.delete(ev.action.id);
  }

  onDidReceiveSettings(ev) {
    const view = this.visible.get(ev.action.id);
    if (!view) return;
    view.settings = ev.payload.settings;
    this.render(view);
  }

  async render(view) {
    view.next = renderKey(this.kind, view.settings, recorder.snapshot);
    if (view.rendering) return;
    view.rendering = true;
    try {
      // Keep only the most recent frame if Stream Deck is slower than the incoming meters.
      while (view.active && view.next !== view.last) {
        const image = view.next;
        await view.action.setImage(image);
        view.last = image;
      }
    } catch (error) {
      streamDeck.logger.error('Key display update failed', error);
    } finally {
      view.rendering = false;
    }
  }

  async onKeyDown(ev) {
    if (this.kind === 'status' || this.kind === 'meters') return;
    try {
      await recorder.command(this.kind);
    } catch (error) {
      streamDeck.logger.warn(error.message);
      await ev.action.showAlert();
    }
  }
}

for (const kind of ['record', 'stop', 'toggle', 'play', 'status', 'meters']) {
  streamDeck.actions.registerAction(new RecorderAction(kind));
}
await streamDeck.connect();
recorder.start();
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.once(signal, () => { recorder.stop(); process.exit(0); });
}
