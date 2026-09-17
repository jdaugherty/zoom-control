<!-- Copyright (c) 2026 The Zoom Control Authors — SPDX-License-Identifier: MIT -->

# Stream Deck integration (deferred)

Stream Deck software is not installed on this Mac yet, so nothing here is built. Two routes:

## 1. No plugin needed (works today)
Run `make install` in the repo root, keep **Zoom Control.app** running (it auto-connects to the recorder), and
add Stream Deck *System → Open* actions (or the BarRaider "Advanced Launcher" plugin) that run:

    /usr/local/bin/zoomctl toggle     # one key: REC when stopped, STOP when recording
    /usr/local/bin/zoomctl rec
    /usr/local/bin/zoomctl stop
    /usr/local/bin/zoomctl play

Each returns in well under a second because it goes through the app's live Bluetooth session.

## 2. Native plugin (later)
A Node.js plugin built with `@elgato/streamdeck` (package.json here is a starting point) should connect to
`ws://127.0.0.1:47337`, subscribe to the `status` messages (state, locator time, meters) to draw key images,
and send `{"cmd":"toggleRecord"}` / `{"cmd":"key","key":"..."}` on key press. See `Sources/ZoomKit/ControlServer.swift`
for the message schema. `npm install` for the SDK did not complete on this network; retry from a network
that can reach the npm registry.
