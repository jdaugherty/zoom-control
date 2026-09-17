// Copyright (c) 2026 The Zoom Control Authors
// SPDX-License-Identifier: MIT
import Foundation
import CoreBluetooth
import ZoomKit

// zoomctl — talk to a Zoom H6studio / essential-series recorder through the BTA-1 BLE tunnel
// using the recovered Handy Control & Sync protocol (see ZoomProtocol.swift).
//
// Through the running Zoom Control app (instant; uses the app's live Bluetooth session):
//   zoomctl rec | stop | play | toggle | status | clock | connect | disconnect [--json]
//   (falls back to a direct Bluetooth session if the app is not running)
//
// Direct Bluetooth (no app needed; the recorder must be in Control & Sync "searching" mode):
//   zoomctl session [--idle N]      connect, run the official 14-step handshake, then print
//                                     every status packet (meters, battery, remaining time...) for N s
//   zoomctl key <rec|play|stop>     handshake, press+release the key, show the resulting status
//   zoomctl settime                 handshake, set recorder clock to this Mac's clock
//   zoomctl raw <hex...>            handshake, send arbitrary bytes, print replies
//   zoomctl repl                    interactive: hex lines, or 'rec' 'play' 'stop' 'time' 'q'
//   zoomctl dump                    like session but no handshake (just listen)
// Options: --name <substring of advertised name> (default h6studio)  --idle <seconds> (default 15)

let SERVICE = CBUUID(string: "530CA1F1-AE57-208B-D745-7E1550E00CC3")
let TX_CHAR = CBUUID(string: "3DD03220-904F-DDAE-BE4C-C3209199AB2D") // recorder -> host (notify)
let RX_CHAR = CBUUID(string: "A81759EF-A552-789F-8347-B53ABB5E631E") // host -> recorder (write w/o response)
let FLOW_CHAR = CBUUID(string: "81B02F4F-7BB6-4ABC-F647-A736C35B959E") // Dialog SPS-style flow control (0x01 = XON)
var useFlow = true
var rxNotify = false
var withResponse = false

var mode = "status"
var jsonOut = false
let remoteModes: Set<String> = ["rec", "record", "stop", "play", "toggle", "status", "clock", "connect", "disconnect"]
var nameFilter = "h6studio"
var idleSeconds: Double = 15
var extra: [String] = []

var args = Array(CommandLine.arguments.dropFirst())
if let m = args.first, !m.hasPrefix("--") { mode = m; args.removeFirst() }
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--name": nameFilter = args.removeFirst().lowercased()
    case "--idle": idleSeconds = Double(args.removeFirst()) ?? 15
    case "--json": jsonOut = true
    case "--flow": useFlow = true
    case "--no-flow": useFlow = false
    case "--rxnotify": rxNotify = true
    case "--withresponse": withResponse = true
    default: extra.append(a)
    }
}

func parseHex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    for tok in s.replacingOccurrences(of: "0x", with: "").split(whereSeparator: { $0 == " " || $0 == "," }) {
        var t = String(tok); if t.count % 2 == 1 { t = "0" + t }
        var i = t.startIndex
        while i < t.endIndex { let j = t.index(i, offsetBy: 2); if let b = UInt8(t[i..<j], radix: 16) { out.append(b) }; i = j }
    }
    return out
}
func ts() -> String { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: Date()) }
func log(_ s: String) { print("[\(ts())] \(s)"); fflush(stdout) }

final class Link: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var dev: CBPeripheral?
    var tx: CBCharacteristic?, rx: CBCharacteristic?, flow: CBCharacteristic?
    var assembler = ZoomPacketAssembler()
    var inbox: [[UInt8]] = []            // parsed packets not yet consumed by a waiter
    var onReady: (() -> Void)?
    var ready = false
    var quietMeters = false

    override init() { super.init(); central = CBCentralManager(delegate: self, queue: nil) }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else {
            log("Bluetooth not available (state \(c.state.rawValue)). If unauthorized: System Settings > Privacy & Security > Bluetooth.")
            if c.state == .unauthorized || c.state == .poweredOff { exit(2) }
            return
        }
        log("Scanning for '\(nameFilter)' (recorder must be in Bluetooth 'Control & Sync' mode) ...")
        c.scanForPeripherals(withServices: [SERVICE], options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            if self?.dev == nil {
                log("No recorder found in 12 s. Is it in Control & Sync mode and showing 'Searching'? (If the Zoom Control app is connected to it, use the app or quit it first.)")
                exit(4)
            }
        }
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        guard dev == nil, nameFilter.isEmpty || name.lowercased().contains(nameFilter) else { return }
        log("Found \(name) rssi=\(rssi); connecting")
        dev = p; p.delegate = self; c.stopScan(); c.connect(p, options: nil)
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { p.discoverServices([SERVICE]) }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { log("connect failed: \(error?.localizedDescription ?? "?")"); exit(1) }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { log("DISCONNECTED (\(error?.localizedDescription ?? "clean"))"); exit(0) }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == SERVICE }) else { log("Zoom service missing"); exit(1) }
        p.discoverCharacteristics([TX_CHAR, RX_CHAR, FLOW_CHAR], for: s)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid == TX_CHAR { tx = ch; p.setNotifyValue(true, for: ch) }
            if ch.uuid == RX_CHAR { rx = ch; if rxNotify { p.setNotifyValue(true, for: ch) } }
            if ch.uuid == FLOW_CHAR { flow = ch; if useFlow { p.setNotifyValue(true, for: ch) } }
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        log("notify state \(ch.uuid): \(ch.isNotifying) \(error.map { "err: \($0.localizedDescription)" } ?? "")")
        if ch.uuid == TX_CHAR && ch.isNotifying && !ready { log("Connected; notifications on."); ready = true; onReady?() }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if ch.uuid == FLOW_CHAR { log("  FLOW notify = \(Zoom.hex([UInt8](ch.value ?? Data())))"); return }
        if ch.uuid == RX_CHAR { log("  RX-char notify = \(Zoom.hex([UInt8](ch.value ?? Data())))") }
        guard ch.uuid == TX_CHAR, let v = ch.value else { return }
        for pkt in assembler.feed([UInt8](v)) {
            let isMeter = pkt[0] == Zoom.Rcv.levelMeterDataH2 || pkt[0] == Zoom.Rcv.levelMeterData
            if !(quietMeters && isMeter) { log("  <- \(Zoom.hex(pkt))   \(Zoom.describe(pkt))") }
            inbox.append(pkt)
        }
    }

    func send(_ bytes: [UInt8], _ note: String = "") {
        guard let d = dev, let rx = rx else { log("not ready"); return }
        log("  -> \(Zoom.hex(bytes))   \(note)")
        d.writeValue(Data(bytes), for: rx, type: withResponse ? .withResponse : .withoutResponse)
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        log("  write result \(ch.uuid): \(error.map { "ERROR \($0.localizedDescription) (\(($0 as NSError).code))" } ?? "ok")")
    }
    /// Send and wait (up to `timeout`) for a packet whose command byte == expect.
    func request(_ bytes: [UInt8], expect: UInt8, note: String = "", timeout: Double = 3.0) async -> [UInt8]? {
        inbox.removeAll()
        send(bytes, note)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let i = inbox.firstIndex(where: { $0[0] == expect }) { return inbox.remove(at: i) }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        return nil
    }
    func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    /// The official app's session handshake. Returns false if any step gets no expected reply.
    func handshake() async -> Bool {
        log("== Handshake ==")
        for step in Zoom.initSequence {
            guard let reply = await request(step.bytes, expect: step.expect, note: step.name) else {
                log("!! no reply to \(step.name) (expected cmd \(Zoom.hex(step.expect)))"); return false
            }
            _ = reply
            await sleep(0.05)
        }
        log("== Session established ==")
        return true
    }

    /// Key presses are not ACKed by the recorder (the official app fires KeyOnEdge and moves on).
    func press(_ k: Zoom.Key) async {
        send(Zoom.keyOn(k), "key ON \(k)")
        await sleep(0.15)
        send(Zoom.keyOff(k), "key OFF \(k)")
        await sleep(0.4)
    }
}

// ---- Fast path: talk to the running Zoom Control app -----------------------------------------
if remoteModes.contains(mode) {
    let hub = RemoteHub(port: 47337)
    var finished = false
    var handled = false
    Task { @MainActor in
        if await hub.connect() {
            handled = true
            _ = await hub.next(type: "status", timeout: 1)   // initial snapshot
            let cmd: [String: Any]
            switch mode {
            case "rec", "record": cmd = ["cmd": "key", "key": "rec"]
            case "stop":  cmd = ["cmd": "key", "key": "stop"]
            case "play":  cmd = ["cmd": "key", "key": "play"]
            case "toggle": cmd = ["cmd": "toggleRecord"]
            case "clock": cmd = ["cmd": "setClock"]
            case "connect": cmd = ["cmd": "connect"]
            case "disconnect": cmd = ["cmd": "disconnect"]
            default: cmd = ["cmd": "status"]
            }
            hub.send(["cmd": "status"])
            let before = await hub.next(type: "status", timeout: 2)
            hub.send(cmd)
            _ = await hub.next(type: "ack", timeout: 5)
            // Transport keys take ~0.5–1 s to show up in RecorderStatus; wait for the state to change (max 1.5 s).
            var st: [String: Any]? = before
            if ["rec", "record", "stop", "play", "toggle"].contains(mode) {
                let deadline = Date().addingTimeInterval(1.5)
                while Date() < deadline {
                    if let s = await hub.next(type: "status", timeout: 0.3) {
                        st = s
                        if (s["stateCode"] as? Int) != (before?["stateCode"] as? Int) { break }
                    }
                }
            }
            hub.send(["cmd": "status"])
            if let latest = await hub.next(type: "status", timeout: 2) { st = latest }
            if let st {
                if jsonOut, let d = try? JSONSerialization.data(withJSONObject: st, options: [.sortedKeys]) { print(String(decoding: d, as: UTF8.self)) }
                else { print(formatStatus(st)) }
                let connected = (st["connected"] as? Bool) == true
                hub.close(); exit(connected || mode == "status" ? 0 : 3)
            }
            hub.close(); exit(1)
        }
        finished = true
    }
    // Pump the main run loop (Network.framework callbacks and the MainActor task need it).
    while !finished { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    if !handled {
        fputs("Zoom Control app is not running; using a direct Bluetooth session instead.\n", stderr)
        switch mode {
        case "rec", "record": mode = "key"; extra = ["rec"]
        case "stop": mode = "key"; extra = ["stop"]
        case "play": mode = "key"; extra = ["play"]
        case "toggle": fputs("toggle needs the app's live state; use rec/stop.\n", stderr); exit(2)
        case "clock": mode = "settime"
        case "connect", "disconnect": fputs("connect/disconnect only apply to the running app.\n", stderr); exit(2)
        default: mode = "session"; idleSeconds = 3
        }
    }
}

let link = Link()

link.onReady = {
    Task { @MainActor in
        await link.sleep(0.3)
        if useFlow, let f = link.flow, let d = link.dev {
            log("  -> FLOW write 01 (XON)")
            d.writeValue(Data([0x01]), for: f, type: .withoutResponse)
            await link.sleep(0.3)
        }
        func finish() async {
            log("Listening \(Int(idleSeconds))s (Ctrl-C to stop) ...")
            await link.sleep(idleSeconds)
            link.send(Zoom.packet(Zoom.Snd.disconnect), "Disconnect")
            await link.sleep(0.4)
            if let d = link.dev { link.central.cancelPeripheralConnection(d) }
            await link.sleep(0.5); exit(0)
        }
        switch mode {
        case "dump":
            await finish()
        case "session":
            guard await link.handshake() else { exit(1) }
            await finish()
        case "key":
            guard let name = extra.first, let k = ["rec": Zoom.Key.rec, "play": .play, "stop": .stop][name.lowercased()] else { log("usage: key rec|play|stop"); exit(2) }
            guard await link.handshake() else { exit(1) }
            link.quietMeters = true
            await link.press(k)
            _ = await link.request(Zoom.packet(Zoom.Snd.recorderStatusRequest), expect: Zoom.Rcv.recorderStatus, note: "RecorderStatusRequest")
            await finish()
        case "settime":
            guard await link.handshake() else { exit(1) }
            link.quietMeters = true
            _ = await link.request(Zoom.setDateTime(), expect: Zoom.Rcv.ack, note: "SetDateTime")
            await finish()
        case "raw":
            guard await link.handshake() else { exit(1) }
            link.send(parseHex(extra.joined(separator: " ")), "raw")
            await finish()
        case "repl":
            guard await link.handshake() else { exit(1) }
            link.quietMeters = true
            log("REPL: rec | play | stop | time | meters | hex bytes | q")
            DispatchQueue.global().async {
                while let line = readLine() {
                    let t = line.trimmingCharacters(in: .whitespaces).lowercased()
                    DispatchQueue.main.async {
                        Task { @MainActor in
                            switch t {
                            case "q": link.send(Zoom.packet(Zoom.Snd.disconnect), "Disconnect"); await link.sleep(0.3); exit(0)
                            case "rec": await link.press(.rec)
                            case "play": await link.press(.play)
                            case "stop": await link.press(.stop)
                            case "time": _ = await link.request(Zoom.setDateTime(), expect: Zoom.Rcv.ack, note: "SetDateTime")
                            case "meters": link.quietMeters.toggle(); log("meters \(link.quietMeters ? "hidden" : "shown")")
                            case "": break
                            default: link.send(parseHex(t), "raw")
                            }
                        }
                    }
                }
            }
        default: log("unknown mode \(mode)"); exit(2)
        }
    }
}
RunLoop.main.run()
