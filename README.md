<!-- Copyright (c) 2026 The Zoom Control Authors — SPDX-License-Identifier: MIT -->

# Zoom Control — control a Zoom H6studio (BTA-1) from a Mac

A native macOS app + command-line tool that talk to a Zoom H6studio (and, untested, the other
essential/studio-series recorders) through the **BTA-1 Bluetooth adapter**, using the same protocol as
Zoom's *Handy Control & Sync* phone app. No Xcode required — it builds with the Swift toolchain that
ships with the Command Line Tools.

```
make app        # build dist/ZoomControl.app
make run        # build + open the app
make build      # build the CLI too: .build/release/zoomctl
```

## What works (verified on H6studio fw v_3.0.9.504, 2026-09-17)

- Discover the recorder, open a control session (the recorder must be in **Bluetooth › Control & Sync**
  mode and showing *Searching*).
- REC / STOP / PLAY-PAUSE transport keys.
- Live status: transport state, locator time while recording, remaining card time, sample rate,
  power source / battery, stereo level meters (~8 Hz), device name, model and firmware.
- Set the recorder's clock from the Mac.
- Menu bar extra with quick REC / STOP / PLAY.
- A local WebSocket API (`ws://127.0.0.1:47337`) so scripts and, later, a Stream Deck plugin can drive
  the recorder through the app's live session.

## Using it

1. On the H6studio choose **Bluetooth → Control & Sync**. It shows *Searching*.
2. `make run`. The app scans and (with *Connect automatically* on) opens the session by itself.
3. Press REC / STOP / PLAY in the window, in the menu bar, or with ⌘R / ⌘. / ⌘P.

### From the command line (Stream Deck "Run command" friendly)

While the app is running, these go through the app's session and return immediately:

```
.build/release/zoomctl rec        # start recording
.build/release/zoomctl stop
.build/release/zoomctl play       # play / pause
.build/release/zoomctl toggle     # REC if stopped, STOP if recording
.build/release/zoomctl status     # one line, e.g. "H6studio: REC · time 00:00:04 · remaining 739:57:33 · 48 kHz …"
.build/release/zoomctl status --json
.build/release/zoomctl clock      # set recorder date/time from the Mac
```

If the app is **not** running, `rec|stop|play|clock|status` fall back to a direct Bluetooth session
(slower: connect + 14-step handshake ≈ 4 s). Exit code 0 on success, 3 if no recorder is connected.

### Direct-Bluetooth / protocol exploration modes

```
zoomctl session --idle 20         # handshake, then print every status packet for 20 s
zoomctl key rec|play|stop         # single key press
zoomctl settime
zoomctl raw a2 01 00              # send arbitrary bytes after the handshake
zoomctl repl                      # interactive: rec | play | stop | time | meters | <hex> | q
zoomctl dump                      # connect and only listen (no handshake)
blescan --filter h6studio --connect --seconds 20   # generic GATT dump of any BLE device
```

### Local API (for automation)

Connect a WebSocket client to `ws://127.0.0.1:47337`. You receive `{"type":"status",…}` on connect and
on every change (≤10/s). Send `{"cmd":"key","key":"rec"}`, `{"cmd":"toggleRecord"}`, `{"cmd":"status"}`,
`{"cmd":"setClock"}`, `{"cmd":"connect"}`, `{"cmd":"disconnect"}`; each is answered with an `ack`.
See `Sources/ZoomKit/ControlServer.swift`.

## Layout

| Path | What |
|---|---|
| `Sources/ZoomKit/ZoomProtocol.swift` | Command bytes, handshake, packet builders/parsers |
| `Sources/ZoomKit/ZoomRecorderClient.swift` | CoreBluetooth client, session state machine, published status |
| `Sources/ZoomKit/ControlServer.swift` | Local WebSocket API |
| `Sources/ZoomControl/` | SwiftUI app (window + menu bar extra) |
| `Sources/zoomctl/` | CLI (remote via app API, or direct Bluetooth) |
| `Sources/blescan/` | Generic BLE scanner / GATT dumper |
| `Resources/Info.plist` | App bundle plist (Bluetooth usage description) |
| `PROTOCOL.md` | The recovered protocol, in detail |
| `StreamDeck/` | Placeholder for the future Stream Deck plugin (see PROTOCOL.md / README notes) |

## Gotchas learned the hard way

- The recorder only answers while it is in *Searching* state. If a session is dropped without the
  `Disconnect` (`B7 00`) packet, the recorder can get stuck and needs Control & Sync re-entered; the app
  and CLI always send `Disconnect` first, and the app waits 8 s before auto-retrying after a failure.
- Key presses (`KeyOnEdge`/`KeyOffEdge`) are **not** acknowledged; don't wait for an ACK.
- The first Bluetooth use from a new binary/terminal prompts for Bluetooth permission
  (System Settings › Privacy & Security › Bluetooth).
- Only one central can hold the session: quit the app before using `zoomctl session/key/...` directly.
