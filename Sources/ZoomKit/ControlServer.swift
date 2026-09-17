// Copyright (c) 2026 The Zoom Control Authors
// SPDX-License-Identifier: MIT
import Foundation
import Network
import Combine

/// Tiny local WebSocket control API for automation (Stream Deck plugin, scripts).
///
///   ws://127.0.0.1:47337
///   server → client (on connect and whenever anything changes):
///     {"type":"status","phase":"ready","device":"H6studio","state":"REC","stateCode":1,
///      "locator":"00:00:04","remain":"739:57:33","sampleRate":"48 kHz","battery":0,
///      "powerSource":"External (USB/AC)","meterL":12,"meterR":9,"card":2,"connected":true}
///   client → server:
///     {"cmd":"key","key":"rec|stop|play"}   {"cmd":"toggleRecord"}   {"cmd":"status"}
///     {"cmd":"connect"}   {"cmd":"disconnect"}   {"cmd":"setClock"}
public final class ControlServer {
    public static let defaultPort: UInt16 = 47337
    private let client: ZoomRecorderClient
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var subs: Set<AnyCancellable> = []
    public private(set) var port: UInt16
    public private(set) var lastError: String?

    public init(client: ZoomRecorderClient, port: UInt16 = ControlServer.defaultPort) {
        self.client = client; self.port = port
    }

    public func start() {
        do {
            let params = NWParameters.tcp
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            let l = try NWListener(using: params)
            l.stateUpdateHandler = { [weak self] st in
                if case .failed(let e) = st { self?.lastError = e.localizedDescription }
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.start(queue: .main)
            listener = l
        } catch {
            lastError = error.localizedDescription
        }
        // Push status on any change, capped at ~10 Hz (meters arrive ~8 Hz).
        client.$status.map { _ in () }.merge(with: client.$phase.map { _ in () })
            .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.broadcastStatus() }
            .store(in: &subs)
    }

    public func stop() { listener?.cancel(); connections.values.forEach { $0.cancel() }; connections.removeAll() }

    private func accept(_ c: NWConnection) {
        connections[ObjectIdentifier(c)] = c
        c.stateUpdateHandler = { [weak self, weak c] st in
            guard let c else { return }
            switch st {
            case .ready: self?.send(self?.statusJSON() ?? Data(), to: c)
            case .failed, .cancelled: self?.connections.removeValue(forKey: ObjectIdentifier(c))
            default: break
            }
        }
        c.start(queue: .main)
        receive(on: c)
    }

    private func receive(on c: NWConnection) {
        c.receiveMessage { [weak self, weak c] data, ctx, _, error in
            guard let self, let c else { return }
            if let data, !data.isEmpty { self.handle(data, from: c) }
            if error == nil, c.state == .ready || c.state == .preparing { self.receive(on: c) }
        }
    }

    private func handle(_ data: Data, from c: NWConnection) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = obj["cmd"] as? String else {
            send(json(["type": "error", "message": "expected {\"cmd\": ...}"]), to: c); return
        }
        Task { @MainActor in
            switch cmd {
            case "status": self.send(self.statusJSON(), to: c)
            case "key":
                let map: [String: Zoom.Key] = ["rec": .rec, "record": .rec, "stop": .stop, "play": .play]
                if let k = map[(obj["key"] as? String ?? "").lowercased()] { await self.client.press(k) }
                else { self.send(self.json(["type": "error", "message": "key must be rec|stop|play"]), to: c) }
            case "toggleRecord":
                let s = self.client.status.state
                await self.client.press((s == .rec || s == .recPause) ? .stop : .rec)
            case "connect":
                self.client.autoConnect = true; self.client.startScanning()
            case "disconnect":
                self.client.disconnect()
            case "setClock":
                _ = await self.client.setClock()
            default:
                self.send(self.json(["type": "error", "message": "unknown cmd \(cmd)"]), to: c)
            }
            self.send(self.json(["type": "ack", "cmd": cmd]), to: c)
        }
    }

    private func statusJSON() -> Data {
        let s = client.status
        var phase: String
        switch client.phase {
        case .bluetoothOff: phase = "bluetoothOff"
        case .unauthorized: phase = "unauthorized"
        case .idle: phase = "idle"
        case .scanning: phase = "scanning"
        case .connecting: phase = "connecting"
        case .handshaking: phase = "handshaking"
        case .ready: phase = "ready"
        case .failed: phase = "failed"
        }
        var d: [String: Any] = [
            "type": "status", "phase": phase, "connected": client.phase.isReady,
            "device": s.deviceName, "model": s.model, "firmware": s.firmware,
            "meterL": s.meterL, "meterR": s.meterR, "meterChannels": s.meterChannels,
        ]
        if case .failed(let m) = client.phase { d["error"] = m }
        if let st = s.state { d["state"] = st.label; d["stateCode"] = Int(st.rawValue) }
        if let v = s.locatorTime { d["locator"] = v }
        if let v = s.remainTime { d["remain"] = v }
        if let v = s.sampleRate { d["sampleRate"] = v }
        if let v = s.battery { d["battery"] = v }
        if let v = s.powerSource { d["powerSource"] = v.label }
        if let v = s.cardState { d["card"] = v }
        if let v = s.recFileName { d["recFileName"] = v }
        if let v = s.playFileName { d["playFileName"] = v }
        if let v = s.popup { d["popup"] = v }
        return json(d)
    }

    private func json(_ d: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: d)) ?? Data() }

    private func broadcastStatus() {
        let payload = statusJSON()
        for c in connections.values where c.state == .ready { send(payload, to: c) }
    }

    private func send(_ data: Data, to c: NWConnection) {
        let md = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [md])
        c.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }
}
