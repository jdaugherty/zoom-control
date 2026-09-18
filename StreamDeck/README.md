<!-- Copyright (c) 2026 The Zoom Control Authors — SPDX-License-Identifier: MIT -->

# Zoom Recorder Control for Stream Deck Mini and Mobile

A native Elgato plugin with recorder-confirmed transport state, live stereo meters, and configurable
metadata tiles. One plugin process shares one WebSocket connection across all visible keys on both
devices connected to the same Mac's Stream Deck application.

```text
H6studio + BTA-1 ← Bluetooth → Zoom Control.app ← local WebSocket → Stream Deck → Mini / Mobile
```

## Requirements

- macOS 13 or later.
- Elgato Stream Deck desktop software 6.9 or later, with the Mini and/or Mobile connected to it.
- Node.js 20.9.0 or later and npm to build the plugin (Node.js 24 LTS recommended).
- For real recorder control: the Zoom Control Mac app and a supported recorder in
  **Bluetooth → Control & Sync** mode. The repo documents H6studio + BTA-1 verification;
  other recorder models need testing.

The packaged plugin uses Stream Deck's bundled Node.js runtime. There is no separate plugin to
install inside the Mobile app; add its keys using the Mac's Stream Deck software.

## Build and install

From the repository's `StreamDeck/` directory:

```sh
npm ci
npm test
npm run pack
```

Double-click the generated `com.zoomcontrol.recorder.streamDeckPlugin` to install it in Stream Deck.
Find **Zoom Recorder Control** in the actions list and drag actions onto Mini or Mobile keys.

For local development, use `npm run build` followed by `npm run link` instead of installing the package.
Linking registers the local `.sdPlugin` directory with Stream Deck. `npm run watch` rebuilds JavaScript
as it changes; restart the plugin in Stream Deck after rebuilding. Rebuild after changing the source
icon. Re-run `npm run pack` to make a new installable artifact (move/remove an older artifact first
if the CLI refuses to overwrite it).

## Try it before building the Swift app

Run this in a terminal and keep it open:

```sh
npm run simulate
```

The simulator occupies the same loopback port as the real app and labels the device **SIMULATED H6**.
Installed plugin keys will show sample status and moving meters. Press Record/Stop/Play from either
device; both should update from the same feed.

| Terminal command | Purpose |
|---|---|
| `rec`, `stop`, `play` | Simulate transport changes originating on the recorder |
| `offline`, `online` | Simulate Bluetooth recorder disconnection/reconnection |
| `silent` | Toggle a stalled status feed to exercise stale-data detection |
| `battery` | Toggle low/full battery |
| `message` | Show/hide a recorder message |
| `quit` | Exit and release the API port |

In another terminal, `npm run test-api` performs a read-only check of three status snapshots. It works
against either the simulator or the real app and sends no transport commands.

## Connect the real recorder

Quit the simulator. From the **repository root**:

```sh
make run
```

This builds and opens Zoom Control.app. On the recorder, enter **Bluetooth → Control & Sync** and leave
it searching. Grant Bluetooth permission on the Mac when prompted. Once the app establishes a session,
the plugin reconnects automatically to `ws://127.0.0.1:47337`.

The app must run on the same Mac as Stream Deck. Mobile communicates with Stream Deck desktop;
it does not connect directly to the recorder API. The plugin never opens a competing Bluetooth session.

## Actions and layouts

| Action | Behavior |
|---|---|
| **Record / Stop** | REC when not recording; STOP when recording or record-paused |
| **Record** | Starts recording; does nothing if already recording or record-paused |
| **Stop** | Stops transport; does nothing if already stopped |
| **Play / Pause** | Sends the recorder's Play key and waits for playing/play-paused state |
| **Status Tile** | Display-only key; choose a metadata field in its settings |
| **Stereo Meter** | Display-only key with relative L/R level bars (~8 Hz) |

Transport keys display the reported state. Their footer shows record/play position by default;
uncheck **Show elapsed time** to show the device name instead. Record, Stop, and Record / Stop support
Multi Actions. Play/Pause remains unavailable there.

To toggle recording alongside other steps, add **Record / Stop** to a Stream Deck **Multi Action**.
Each execution starts recording when not recording, or stops when recording/record-paused, based on
the recorder's reported state. It also works inside either side of a **Multi Action Switch**.
For a switch with explicitly defined start and stop sides, use **Record** on the first side and
**Stop** on the second instead.

Stream Deck Multi Actions do not guarantee a wait for hardware confirmation; add appropriate delays
between dependent operations.

Suggested Mini layout:

| | | |
|---|---|---|
| Record / Stop | Stop | Play / Pause |
| Stereo Meter | Status Tile: Remaining | Status Tile: Power or Connection |

For Mobile, add more Status Tiles for position, filename, sample rate, device, firmware, card status,
and recorder messages. Each tile has independent settings.

**Leave custom key titles and images unset.** Elgato gives user overrides precedence over runtime
images. The plugin draws its text into SVG images so it scales with Mini and Mobile keys.

## What the data means

- Recording indication follows status received from the recorder, not a speculative button toggle.
- API `ack` means the server received a command; it is not recorder confirmation. Pending commands
  time out after four seconds and produce a Stream Deck alert. Details are written to plugin logs.
- Commands are never queued or replayed when reconnecting. A second transport request while one is
  pending is rejected. This also applies when pressing controls from the other device.
- **APP OFFLINE** means Zoom Control cannot be reached. **SEARCHING / DISCONNECTED / BLUETOOTH OFF**
  means the app is reachable but the recorder is not ready. Cached metadata is hidden in these states.
- The plugin requests a snapshot every two seconds as a liveness check. A feed silent for more than
  6.5 seconds is invalidated at the next check and reconnected. This detects an app/API stall, not a
  recorder that silently stops sending BLE notifications while the app still reports it ready.
- Position is record/play elapsed position, not SMPTE timecode. The plugin does not extrapolate it.
- Battery is a coarse Empty/Low/Medium/Full reading, not percentage. External power is shown separately.
- Meter values are 0–127 relative bars, not calibrated dBFS. Amber indicates a high relative reading,
  not a verified clipping event.
- Filename, card and popup fields depend on what the recorder supplies. Missing values display **—**;
  long strings are shortened to fit. A stopped recorder shows the current playback filename.
- Individual input meters, trim/gain, phantom power, scene/take editing and SMPTE timecode are not
  implemented by the current app API.

## Checks

```sh
npm test           # local WebSocket lifecycle/transport tests and SVG rendering checks
npm run test-host  # build and exercise the SDK against a simulated Stream Deck host
npm run validate   # build and Elgato manifest/assets validation
npm run pack       # validate and create installable .streamDeckPlugin
```

Tests do not require the Swift build or a recorder. The SDK-host check uses simulated Mini/Mobile
contexts and verifies messaging, not physical display appearance or Bluetooth behavior.

## Source layout

- `src/recorder.mjs`: shared connection, snapshots, heartbeat, command confirmation.
- `src/render.mjs`: pure SVG rendering of transport, metadata and meter keys.
- `src/plugin.mjs`: Elgato action lifecycle and per-key display updates.
- `com.zoomcontrol.recorder.sdPlugin/`: manifest, icon and settings UI; generated bundle under `bin/`.
- `tools/simulator.mjs`: interactive mock recorder API.
- `tools/api-test.mjs`: read-only real/simulated API probe.
- `tools/host-test.mjs`: built-plugin SDK integration check.
- `test/`: automated tests.
