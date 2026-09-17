// Copyright (c) 2026 The Zoom Control Authors
// SPDX-License-Identifier: MIT
import Foundation
import Network

/// Minimal WebSocket client for the Zoom Control app's local API (ws://127.0.0.1:47337).
/// Lets `zoomctl rec|stop|play|toggle|status|clock` act instantly through the app's live session.
final class RemoteHub {
    let conn: NWConnection
    private var buffered: [[String: Any]] = []

    init(port: UInt16) {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options(); ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        // The WebSocket framer needs a URL endpoint (for the HTTP Upgrade request line / Host header).
        conn = NWConnection(to: .url(URL(string: "ws://127.0.0.1:\(port)")!), using: params)
    }

    /// Returns false if nothing is listening (app not running).
    private final class Flag: @unchecked Sendable { var done = false; var ok = false }
    func connect(timeout: Double = 1.5) async -> Bool {
        let flag = Flag()
        let debug = ProcessInfo.processInfo.environment["ZOOMCTL_DEBUG"] != nil
        conn.stateUpdateHandler = { st in
            if debug { fputs("[ws] state: \(st)\n", stderr) }
            switch st {
            case .ready: flag.ok = true; flag.done = true
            case .failed, .cancelled: flag.done = true
            case .waiting: flag.done = true   // nothing listening → fail fast
            default: break
            }
        }
        conn.start(queue: .main)
        let deadline = Date().addingTimeInterval(timeout)
        while !flag.done && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        if flag.ok { pump() }
        return flag.ok
    }

    private func pump() {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let d = data, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { self.buffered.append(o) }
            if error == nil { self.pump() }
        }
    }

    func send(_ obj: [String: Any]) {
        let md = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [md])
        conn.send(content: try? JSONSerialization.data(withJSONObject: obj), contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    /// Wait for the next message of a given type.
    func next(type: String, timeout: Double = 3) async -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let i = buffered.firstIndex(where: { ($0["type"] as? String) == type }) { return buffered.remove(at: i) }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        return nil
    }

    func close() { conn.cancel() }
}

func formatStatus(_ s: [String: Any]) -> String {
    let phase = s["phase"] as? String ?? "?"
    guard (s["connected"] as? Bool) == true else {
        var line = "not connected (\(phase))"
        if let e = s["error"] as? String { line += " — \(e)" }
        return line
    }
    var parts: [String] = []
    parts.append("\(s["device"] as? String ?? "recorder"): \(s["state"] as? String ?? "—")")
    if let v = s["locator"] as? String { parts.append("time \(v)") }
    if let v = s["remain"] as? String { parts.append("remaining \(v)") }
    if let v = s["sampleRate"] as? String { parts.append(v) }
    if let v = s["powerSource"] as? String { parts.append(v) }
    if let l = s["meterL"] as? Int, let r = s["meterR"] as? Int { parts.append("meters L\(l) R\(r)") }
    return parts.joined(separator: " · ")
}
