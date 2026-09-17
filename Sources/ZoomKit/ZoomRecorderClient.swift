// Copyright (c) 2026 The Zoom Control Authors
// SPDX-License-Identifier: MIT
import Foundation
import CoreBluetooth
import Combine

public struct DiscoveredRecorder: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var rssi: Int
}

public enum ConnectionPhase: Equatable, Sendable {
    case bluetoothOff, unauthorized, idle, scanning, connecting, handshaking(String), ready, failed(String)
    public var isReady: Bool { self == .ready }
    public var isBusy: Bool { if case .connecting = self { return true }; if case .handshaking = self { return true }; return false }
}

public struct RecorderStatus: Equatable, Sendable {
    public var deviceName = ""
    public var model = ""
    public var firmware = ""
    public var state: Zoom.RecorderState? = nil
    /// 0 = no card, 1 = card ok, 2 = card not playable (per the app's CARD_STATUS_* constants)
    public var cardState: Int? = nil
    public var sampleRate: String? = nil
    public var battery: Int? = nil
    public var powerSource: Zoom.PowerSource? = nil
    public var remainTime: String? = nil
    public var locatorTime: String? = nil
    public var meterChannels = 2
    public var meterL = 0        // 0...127
    public var meterR = 0
    public var playFileName: String? = nil
    public var recFileName: String? = nil
    public var popup: String? = nil
    public init() {}
}

public struct LogLine: Identifiable, Sendable {
    public enum Direction: Sendable { case sent, received, info }
    public let id = UUID()
    public let time = Date()
    public let direction: Direction
    public let text: String
}

/// CoreBluetooth client for a Zoom recorder fitted with a BTA-1, speaking the Handy Control & Sync protocol.
/// All state is published on the main thread (the CBCentralManager is created with the main queue).
public final class ZoomRecorderClient: NSObject, ObservableObject {
    public static let serviceUUID = CBUUID(string: "530CA1F1-AE57-208B-D745-7E1550E00CC3")
    static let txUUID   = CBUUID(string: "3DD03220-904F-DDAE-BE4C-C3209199AB2D")   // recorder -> host, notify
    static let rxUUID   = CBUUID(string: "A81759EF-A552-789F-8347-B53ABB5E631E")   // host -> recorder, write w/o response
    static let flowUUID = CBUUID(string: "81B02F4F-7BB6-4ABC-F647-A736C35B959E")   // Dialog SPS style flow control
    static let disUUID  = CBUUID(string: "180A")
    static let modelUUID = CBUUID(string: "2A24"), firmwareUUID = CBUUID(string: "2A26")

    @Published public private(set) var phase: ConnectionPhase = .idle
    @Published public private(set) var discovered: [DiscoveredRecorder] = []
    @Published public private(set) var status = RecorderStatus()
    @Published public private(set) var log: [LogLine] = []
    /// Level-meter packets arrive ~8x/s; keep them out of the log unless asked.
    @Published public var logMeters = false
    /// Connect to the first recorder found while scanning (needed for hands-off Stream Deck use).
    @Published public var autoConnect = true
    private var lastFailure: Date?
    public var logLimit = 500

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var tx: CBCharacteristic?, rx: CBCharacteristic?, flow: CBCharacteristic?
    private var assembler = ZoomPacketAssembler()
    private var inbox: [[UInt8]] = []
    private var playNameDecoder = ZoomFileNameDecoder(), recNameDecoder = ZoomFileNameDecoder()
    private var wantScan = false
    private var handshakeTask: Task<Void, Never>?

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Public API

    public func startScanning() {
        wantScan = true
        guard central.state == .poweredOn, peripheral == nil else { return }
        discovered.removeAll()
        phase = .scanning
        central.scanForPeripherals(withServices: [Self.serviceUUID],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        info("Scanning for recorders in Bluetooth 'Control & Sync' mode…")
    }

    public func stopScanning() {
        wantScan = false
        central.stopScan()
        if phase == .scanning { phase = .idle }
    }

    public func connect(_ id: UUID) {
        guard let p = peripherals[id] else { return }
        central.stopScan()
        peripheral = p
        p.delegate = self
        phase = .connecting
        status = RecorderStatus()
        status.deviceName = discovered.first(where: { $0.id == id })?.name ?? (p.name ?? "")
        info("Connecting to \(status.deviceName)…")
        central.connect(p, options: nil)
    }

    /// Polite disconnect: tell the recorder (so it goes back to 'searching'), then drop the link.
    public func disconnect() {
        handshakeTask?.cancel()
        guard let p = peripheral else { return }
        if rx != nil, p.state == .connected {
            send(Zoom.packet(Zoom.Snd.disconnect), "Disconnect")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.central.cancelPeripheralConnection(p)
            }
        } else {
            central.cancelPeripheralConnection(p)
        }
    }

    /// Press a transport key. The recorder does not acknowledge key edges, so this is fire-and-forget.
    @MainActor
    public func press(_ key: Zoom.Key) async {
        guard phase.isReady else { return }
        send(Zoom.keyOn(key), "key ON \(key)")
        try? await Task.sleep(nanoseconds: 150_000_000)
        send(Zoom.keyOff(key), "key OFF \(key)")
    }

    /// Set the recorder's clock to this Mac's clock. Returns true if the recorder ACKed.
    @MainActor
    public func setClock() async -> Bool {
        guard phase.isReady else { return false }
        let ok = await request(Zoom.setDateTime(), expect: Zoom.Rcv.ack, note: "SetDateTime") != nil
        info(ok ? "Recorder clock set to \(Date().formatted(date: .abbreviated, time: .standard))" : "SetDateTime: no ACK")
        return ok
    }

    @MainActor
    public func refreshStatus() async {
        guard phase.isReady else { return }
        _ = await request(Zoom.packet(Zoom.Snd.recorderStatusRequest), expect: Zoom.Rcv.recorderStatus, note: "RecorderStatusRequest")
    }

    public func sendRaw(_ bytes: [UInt8]) { send(bytes, "raw") }
    public func clearLog() { log.removeAll() }

    // MARK: - Internals

    private func info(_ s: String) { append(.info, s) }
    private func append(_ d: LogLine.Direction, _ s: String) {
        log.append(LogLine(direction: d, text: s))
        if log.count > logLimit { log.removeFirst(log.count - logLimit) }
    }

    private func send(_ bytes: [UInt8], _ note: String) {
        guard let p = peripheral, let rx = rx else { info("cannot send: not connected"); return }
        append(.sent, "\(Zoom.hex(bytes))   \(note)")
        p.writeValue(Data(bytes), for: rx, type: .withoutResponse)
    }

    /// Send a packet and wait for the first packet whose command byte equals `expect`.
    @MainActor
    private func request(_ bytes: [UInt8], expect: UInt8, note: String, timeout: Double = 3.0) async -> [UInt8]? {
        inbox.removeAll()
        send(bytes, note)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return nil }
            if let i = inbox.firstIndex(where: { $0[0] == expect }) { return inbox.remove(at: i) }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        return nil
    }

    private func startHandshake() {
        handshakeTask?.cancel()
        handshakeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Flow control: XON, as a Dialog SPS host would do (harmless if the tunnel ignores it).
            if let f = flow, let p = peripheral {
                p.writeValue(Data([0x01]), for: f, type: .withoutResponse)
                append(.sent, "01   flow-control XON")
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            for step in Zoom.initSequence {
                if Task.isCancelled { return }
                phase = .handshaking(step.name)
                guard await request(step.bytes, expect: step.expect, note: step.name) != nil else {
                    lastFailure = Date()
                    phase = .failed("Recorder did not answer '\(step.name)'. Re-enter Control & Sync mode on the recorder and try again.")
                    info("Handshake failed at \(step.name)")
                    if let p = peripheral { central.cancelPeripheralConnection(p) }
                    return
                }
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            phase = .ready
            info("Session established with \(status.deviceName)")
        }
    }

    private func apply(_ p: [UInt8]) {
        let cmd = p[0], len = Int(p[1])
        func b(_ i: Int) -> Int { i < p.count ? Int(p[i]) : 0 }
        switch cmd {
        case Zoom.Rcv.recorderStatus:
            status.state = Zoom.RecorderState(rawValue: p[2])
        case Zoom.Rcv.cardStatus:
            if b(2) == 0 { status.cardState = b(3) }
        case Zoom.Rcv.recFormat:
            status.sampleRate = Zoom.sampleRateLabel(b(4))
        case Zoom.Rcv.powerStatus:
            status.battery = b(2); status.powerSource = Zoom.PowerSource(rawValue: p[3])
        case Zoom.Rcv.remainTime:
            if b(2) == 0 {
                let h = b(5) + (b(6) << 7)
                status.remainTime = String(format: "%02d:%02d:%02d", h, b(4), b(3))   // official app caps at 99:59:59; we show the real value
            }
        case Zoom.Rcv.locaterTime:
            status.locatorTime = String(format: "%02d:%02d:%02d", b(6) + (b(7) << 7), b(5), b(4))
        case Zoom.Rcv.levelMeterDataH2:
            status.meterChannels = b(2); status.meterL = b(3); status.meterR = b(4)
        case Zoom.Rcv.deviceName:
            let s = String(decoding: p[2..<min(p.count, 2 + len)].filter { $0 != 0 }, as: UTF8.self)
            if !s.isEmpty { status.deviceName = s }
        case Zoom.Rcv.playFileNameMulti:
            if let s = playNameDecoder.add(p) { status.playFileName = s }
        case Zoom.Rcv.recFileNameMulti:
            if let s = recNameDecoder.add(p) { status.recFileName = s }
        case Zoom.Rcv.popupShowReq:
            status.popup = String(decoding: p[2..<min(p.count, 2 + len)].filter { $0 >= 0x20 }, as: UTF8.self)
        case Zoom.Rcv.popupHideReq:
            status.popup = nil
        default: break
        }
    }

    private func resetLink() {
        peripheral = nil; tx = nil; rx = nil; flow = nil
        assembler.reset(); inbox.removeAll()
        status.state = nil; status.locatorTime = nil; status.meterL = 0; status.meterR = 0
    }
}

// MARK: - CBCentralManagerDelegate
extension ZoomRecorderClient: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            if phase == .bluetoothOff || phase == .unauthorized { phase = .idle }
            if wantScan { startScanning() }
        case .unauthorized:
            phase = .unauthorized
            info("Bluetooth access denied. Allow it in System Settings › Privacy & Security › Bluetooth.")
        case .poweredOff:
            phase = .bluetoothOff
        default: break
        }
    }

    public func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String : Any], rssi: NSNumber) {
        peripherals[p.identifier] = p
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "Zoom recorder"
        if let i = discovered.firstIndex(where: { $0.id == p.identifier }) {
            discovered[i].rssi = rssi.intValue; discovered[i].name = name
        } else {
            discovered.append(DiscoveredRecorder(id: p.identifier, name: name, rssi: rssi.intValue))
            info("Found \(name) (RSSI \(rssi))")
        }
        // Auto-connect, with a cool-down after a failed session so a wedged recorder is not hammered.
        if autoConnect, peripheral == nil, phase == .scanning,
           lastFailure.map({ Date().timeIntervalSince($0) > 8 }) ?? true {
            connect(p.identifier)
        }
    }

    public func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        info("Link up; discovering services")
        p.discoverServices([Self.serviceUUID, Self.disUUID])
    }

    public func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        lastFailure = Date()
        phase = .failed("Connection failed: \(error?.localizedDescription ?? "unknown error")")
        resetLink()
        if wantScan { startScanning() }
    }

    public func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        handshakeTask?.cancel()
        info("Disconnected" + (error.map { " (\($0.localizedDescription))" } ?? ""))
        resetLink()
        if case .failed = phase {} else { phase = .idle }
        if wantScan { startScanning() }
    }
}

// MARK: - CBPeripheralDelegate
extension ZoomRecorderClient: CBPeripheralDelegate {
    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = p.services, services.contains(where: { $0.uuid == Self.serviceUUID }) else {
            phase = .failed("This device does not expose the Zoom control service.")
            central.cancelPeripheralConnection(p); return
        }
        for s in services { p.discoverCharacteristics(nil, for: s) }
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            switch ch.uuid {
            case Self.txUUID:   tx = ch; p.setNotifyValue(true, for: ch)
            case Self.rxUUID:   rx = ch
            case Self.flowUUID: flow = ch; p.setNotifyValue(true, for: ch)
            case Self.modelUUID, Self.firmwareUUID: p.readValue(for: ch)
            default: break
            }
        }
    }

    public func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        if ch.uuid == Self.txUUID, ch.isNotifying, rx != nil { startHandshake() }
        if ch.uuid == Self.txUUID, let e = error {
            phase = .failed("Could not subscribe to recorder data: \(e.localizedDescription)")
        }
    }

    public func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let v = ch.value else { return }
        switch ch.uuid {
        case Self.modelUUID:    status.model = String(decoding: v, as: UTF8.self)
        case Self.firmwareUUID: status.firmware = String(decoding: v, as: UTF8.self)
        case Self.flowUUID:     append(.received, "flow-control = \(Zoom.hex([UInt8](v)))")
        case Self.txUUID:
            for pkt in assembler.feed([UInt8](v)) {
                let isMeter = pkt[0] == Zoom.Rcv.levelMeterDataH2 || pkt[0] == Zoom.Rcv.levelMeterData
                if logMeters || !isMeter { append(.received, "\(Zoom.hex(pkt))   \(Zoom.describe(pkt))") }
                apply(pkt)
                inbox.append(pkt); if inbox.count > 64 { inbox.removeFirst() }
            }
        default: break
        }
    }
}
