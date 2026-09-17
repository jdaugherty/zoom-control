<!-- Copyright (c) 2026 The Zoom Control Authors — SPDX-License-Identifier: MIT -->

# Zoom H6studio + BTA-1 — Bluetooth control protocol

Documented 2026-09-17 by dumping the recorder's GATT table and observing the Bluetooth traffic
exchanged with the ZOOM *Handy Control & Sync* controller app, then verifying every packet below
against an H6studio running firmware `v_3.0.9.504`. Zoom's older wired-remote protocol
(H4n/H5/H6, 2400 baud, `00→82, C2→83 …`) is **not** used by this generation.

## 1. BLE transport

The BTA-1 is a transparent UART bridge (Dialog/Renesas SPS-style service).

| Item | Value |
|---|---|
| Advertised name | `H6studio` (recorder in **Bluetooth › Control & Sync**, state *Searching*) |
| Service | `530CA1F1-AE57-208B-D745-7E1550E00CC3` |
| Server TX Data (recorder → host) | `3DD03220-904F-DDAE-BE4C-C3209199AB2D`, notify |
| Server RX Data (host → recorder) | `A81759EF-A552-789F-8347-B53ABB5E631E`, write-without-response |
| Flow Control | `81B02F4F-7BB6-4ABC-F647-A736C35B959E`, read/write-w/o-rsp/notify; reads `01` (XON). Writing `01` is harmless; the controller app never touches it. |
| Device Information `180A` | Manufacturer `ZOOM`, Model `H6studio`, Firmware `v_3.0.9.504`, Software `v_0.01` |
| MTU | 157 B write-without-response on macOS; the controller app requests 100 |
| Pairing | none |

Host procedure: connect → enable notifications on TX → send the handshake (§3). Notifications may
contain several packets back-to-back; reassemble by length.

## 2. Packet format

```
[command: 1 byte][length: 1 byte][payload: length bytes]
```
Same framing both ways. Multi-byte counters are little-endian **7-bit** groups (`lo + (hi << 7)`).

## 3. Session handshake (host, after subscribing to notifications)

| # | Send | Expect (first byte) | Meaning |
|---|---|---|---|
| 1 | `B6 00` | `80` ACK | Connect |
| 2 | `FA 00` | `FB` | DeviceNameReq → `FB 10 <16-byte UTF-8 name, NUL padded>` |
| 3 | `FF 01 01` | `80` | AppKind = 1 |
| 4 | `91 00` | `92` | RecorderStatusRequest → `92 01 <state>` |
| 5 | `95 01 00` | `96` | CardStatusRequest → `96 03 00 <card> 00` |
| 6 | `97 01 00` | `98` | RecFormatRequest → `98 04 00 01 <fs> 12` |
| 7 | `AE 01 00` | `EC` | CurrentPlayFileNameRequest → EC chunks (§5) |
| 8 | `8F 01 01` | `80` | PowerStatusPermission on → recorder then pushes `88` |
| 9 | `FD 01 01` | `80` | TimeCodeEnable on |
| 10 | `8E 01 01` | `80` | TimecodePermission on |
| 11 | `8D 01 01` | `80` | LocaterTimePermission on → pushes `86` while rec/play |
| 12 | `90 01 01` | `80` | RemainTimePermission on → pushes `89` |
| 13 | `8A 01 01` | `80` | LevelMeterPermission on → pushes `FE` ~8×/s |
| 14 | `CA 00` | `80` | ConnectFinished |

Controller timeout per step: 3 s. Tear-down: send `B7 00` (Disconnect) then drop the link; the recorder returns
to *Searching*. Dropping the link without `B7` can leave the recorder unresponsive until Control & Sync is
re-entered.

## 4. Commands host → recorder

| Byte | Name | Payload | Notes |
|---|---|---|---|
| `A2` | KeyOnEdge | `01 <key>` | key: `00` REC, `01` PLAY(/pause), `02` STOP. **No ACK.** The controller sends only KeyOn. |
| `A3` | KeyOffEdge | `01 <key>` | optional release |
| `A9` | SetDateTime | `06 ss mm hh DD MM (YYYY-2000)` | ACKed |
| `87` | TimeCode push | `06 <isFirst> hh mm ss 01 05` | controller streams once/second while "sync" is on |
| `FC` | SetDeviceName | `10 <16 bytes>` | ACKed |
| `B7` | Disconnect | `00` | |
| `91`/`95`/`97`/`AE` | status requests | see §3 | |
| `8A 8B 8C 8D 8E 8F 90` | permissions | `01 <0/1>` | LevelMeter, LimiterIndicator, ClipIndicator, LocaterTime, Timecode, PowerStatus, RemainTime |
| `A1` | Prm (get/set parameter) | `..` | param IDs known (Trim 03, Pan 04, Fader 05, HPF 07, InputLimiter 08, PhantomOnOff 0D, SampleRate 16, WAVBitDepth 18 …) but format untested |
| `A6` AllKeyStatus, `A7` AllPrmDumpReq, `93` FrameRateRequest, `9B` TrackStatusRequest, `BA` ManuProductNameReq, `E0` MenuDataReq … | | | defined by the protocol, unused in normal control |

## 5. Messages recorder → host

| Byte | Name | Payload | Decode |
|---|---|---|---|
| `80` | ACK | `01 00` | |
| `81` | NAK | | |
| `92` | RecorderStatus | `01 <state>` | 0 STOP, 1 REC, 2 REC_PAUSE, 3 PLAY, 4 PLAY_PAUSE, 5 REW, 6 FF, 7 PREV, 8 NEXT |
| `96` | CardStatus | `03 00 <card> 00` | card: 0 none, 1 ok, 2 not playable |
| `98` | RecFormat | `04 00 01 <fs> 12` | fs: 0 → 44.1 kHz, 6 → 88.2, 7 → 96, 8 → 192, anything else → 48 kHz (H6studio sends 3) |
| `88` | PowerStatus | `03 <battery> <source> 00` | battery 0 n/a, 1 empty … 4 full; source 0 internal, 1 external, 2 battery |
| `89` | RemainTime | `06 00 ss mm hL hH 00` | hours = hL + (hH<<7); app caps display at 99:59:59 |
| `86` | LocaterTime | `06 xx xx ss mm hL hH` | current record/play position (bytes 2–3 are sub-second counters) |
| `FE` | LevelMeter (H2 style) | `03 <ch> <L> <R>` | ch 1 mono / 2 stereo; 0…127 linear bar fraction (`value/127`) |
| `FB` | DeviceName | `10 <name>` | |
| `EC` / `ED` | Play / Rec file name (multi-chunk) | seq 0: `00 <kind> <totLo> <totHi> body…`; seq n: `<n> body…` | 3 bytes → 1 char: `(b0&7F) \| (b1&7F)<<7 \| (b2&3)<<14` |
| `D4` / `DE` | Popup show / hide | UTF-8 text | recorder wants a message displayed |
| `BB` | Manufacturer/ProductName | | app ignores |
| `83 84 85 87 94 9C A1 A8 …` | LevelMeterData, Limiter, Clip, TimeCode, FrameRate, TrackStatus, Prm, AllPrmDump | | not seen on H6studio in Control & Sync |

## 6. Example session (real capture)

```
→ b6 00                       ← 80 01 00                       Connect / ACK
→ fa 00                       ← fb 10 48 36 73 74 75 64 69 6f 00…  "H6studio"
→ ff 01 01                    ← 80 01 00
→ 91 00                       ← 92 01 00                       STOP
→ 95 01 00                    ← 96 03 00 02 00
→ 97 01 00                    ← 98 04 00 01 03 12              48 kHz
→ ae 01 00                    ← ec 06 05 01 00 00 00 00
→ 8f 01 01                    ← 80 01 00   88 03 00 00 00      power: internal
→ fd 01 01 / 8e 01 01 / 8d 01 01 / 90 01 01 / 8a 01 01   (ACK each; 89 and fe start streaming)
→ ca 00                       ← 80 01 00
→ a2 01 00                                                    REC (no ACK) → 92 01 01, 86 … counting
→ a2 01 02                    ← 92 01 00                       STOP
→ b7 00                                                        Disconnect
```

## 7. Full command-byte table

Send: ACK 80, NAK 81, DataDumpProcessed 82, AppVersion D1, FseriesVersionReq D2, PopupSelect DF,
MenuDataReq E0, MenuSelectValue E4, MenuEditStr E5, MenuStringReq E8, LevelMeterPermission 8A,
LimiterIndicatorPermission 8B, ClipIndicatorPermission 8C, LocaterTimePermission 8D, TimecodePermission 8E,
PowerStatusPermission 8F, RemainTimePermission 90, RecorderStatusRequest 91, RecorderStatus 92,
FrameRateRequest 93, CardStatusRequest 95, RecFormatRequest 97, RecPlayTrackRequest 99, TrackStatusRequest 9B,
TrackLinkStatusRequest 9D, LevelMeterLinkStatusRequest A0, TrackNameRequest C5, MicCapsuleRequest CE,
AllKeyStatus A6, KeyOnEdge A2, KeyOffEdge A3, TrackPartsEnableRequest C8, IconOnEdge F2, IconOffEdge F3,
IconEnableRequest F4, MixerEnterExit F6, Prm A1, AllPrmDumpReq A7, SetDateTime A9, FinderEnterExit CD,
FileListDumpRequest AA, FileListDumpAbort C6, SetListPath C3, SetListPathMulti E9, FileNumberRequest BC,
ListFileNameNnnRequest AD, ListFileName BE, ListFileNameMulti EA, ListInfo C4, CurrentPlayPathRequest AB,
CurrentPlayPath AC, CurrentPlayPathMulti EB, CurrentPlayFileNameRequest AE, PlayFileID CB, SetPFL C7,
Connect B6, ConnectFinished CA, Disconnect B7, ManuProductNameReq BA, DeviceNameReq FA, SetDeviceName FC,
TimeCodeEnable FD, AppKind FF.

Receive: ACK 80, NAK 81, DataDumpProcessed 82, AppVersionReq D0, FseriesVersion D3, PopupShowReq D4,
PopupHideReq DE, MenuData E1, MenuStrData E2, MenuItemData E3, MenuDataStart E6, MenuDataVerify E7,
FaderMode EE, LevelMeterData 83, LimiterIndicator 84, ClipIndicator 85, LocaterTime 86, TimeCode 87,
PowerStatus 88, RemainTime 89, RecorderStatus 92, FrameRate 94, CardStatus 96, RecFormat 98, RecPlayTrack 9A,
TrackStatus 9C, TrackLinkStatus 9E, LevelMeterLinkStatus A4, TrackName A5, MicCapsule CF, Wave EF,
WaveTrack F1, PlayMark F0, TrackPartsEnable C9, IconEnable F5, FinderFileUpdate F7, FinderFileInfoEnter F8,
Prm A1, AllPrmDump A8, FileNumber BD, ListFileName BE, ListFileNameMulti EA, ListInfo C4, CurrentPlayPath AC,
CurrentPlayPathMulti EB, PlayFileName BF, PlayFileNameMulti EC, RecFileName C0, RecFileNameMulti ED,
MarkNumber B5, SetPFL C7, ManufacturerProductName BB, DeviceName FB, LevelMeterDataH2 FE, WaveZoom 54(?),
PanAllTrack A6, Fantom A6.

Parameter IDs (`kPrmID_*`, for `A1 Prm`): TrimAllTracks 00, PanAllTracks 01, FaderAllTracks 02, Trim 03,
Pan 04, Fader 05, HPFTr1_8 06, HPF 07, InputLimiter 08, InputLimiterEachValue 09, PhaseInvertTr1_8 0A,
PhaseInvert 0B, PhantomOnOffTr1_8 0C, PhantomOnOff 0D, PhantomVoltage 0E, PluginPower 0F, InputDelayTr1_8 10,
InputDelay 11, StereoLinkTr1_8 1E, StereoLink 1F, StereoLinkModeTr1_8 12, StereoLinkMode 13, RectoSD1 14,
RectoSD2 15, SampleRate 16, WAVBitDepth 18, MP3Bitrate 19, NextTakeNote 1A, NextTakeSceneNameMode 1B,
NextTakeUserSceneName 1C, NextTakeTakeNumberResetMode 1D, Note 20, NoteRequest 21, Circle 22, CircleRequest 23,
FolderTapeName 28, FolderTapeNameRequest 29, ProjectName 2A, ProjectNameRequest 2B, PFLModeTr1_8 2D, PFLMode 2C,
SideMicLevelTr1_8 2E, SideMicLevel 2F, SlateToneOnOff 30, DualChannelRec 31, HomeTrackName 32,
InputSourceTr1_8 33, InputSource 34, Fader2 35, HeadphoneVolume 37, LineOutLevel 38, PlaySpeedLevel 39,
MonoMixLevel 3C, PlaybackRange 3A, AudioNormalization 3B. (Payload layouts not yet documented.)
