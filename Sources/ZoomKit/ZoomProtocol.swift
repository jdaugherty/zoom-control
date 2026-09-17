// Copyright (c) 2026 The Zoom Control Authors
// SPDX-License-Identifier: MIT
import Foundation

/// Zoom "Handy Control & Sync" serial protocol as carried over the BTA-1 BLE tunnel.
/// Documented by observing the controller/recorder Bluetooth traffic and verified against an
/// H6studio (firmware v_3.0.9.504).
///
/// Every packet, in both directions, is:  [command: UInt8][length: UInt8][payload: length bytes]
public enum Zoom {
    // MARK: Commands we send (host -> recorder)
    public enum Snd {
        public static let ack: UInt8                     = 0x80
        public static let nak: UInt8                     = 0x81
        public static let levelMeterPermission: UInt8    = 0x8A
        public static let limiterIndicatorPermission: UInt8 = 0x8B
        public static let clipIndicatorPermission: UInt8 = 0x8C
        public static let locaterTimePermission: UInt8   = 0x8D
        public static let timecodePermission: UInt8      = 0x8E
        public static let powerStatusPermission: UInt8   = 0x8F
        public static let remainTimePermission: UInt8    = 0x90
        public static let recorderStatusRequest: UInt8   = 0x91
        public static let frameRateRequest: UInt8        = 0x93
        public static let cardStatusRequest: UInt8       = 0x95
        public static let recFormatRequest: UInt8        = 0x97
        public static let trackStatusRequest: UInt8      = 0x9B
        public static let prm: UInt8                     = 0xA1   // parameter get/set (trim, pan, phantom, ...)
        public static let keyOnEdge: UInt8               = 0xA2
        public static let keyOffEdge: UInt8              = 0xA3
        public static let allKeyStatus: UInt8            = 0xA6
        public static let allPrmDumpReq: UInt8           = 0xA7
        public static let setDateTime: UInt8             = 0xA9
        public static let currentPlayFileNameRequest: UInt8 = 0xAE
        public static let connect: UInt8                 = 0xB6
        public static let disconnect: UInt8              = 0xB7
        public static let manuProductNameReq: UInt8      = 0xBA
        public static let connectFinished: UInt8         = 0xCA
        public static let deviceNameReq: UInt8           = 0xFA
        public static let setDeviceName: UInt8           = 0xFC
        public static let timeCodeEnable: UInt8          = 0xFD
        public static let appKind: UInt8                 = 0xFF
        public static let timeCode: UInt8                = 0x87   // app pushes wall-clock timecode with this id
    }

    // MARK: Commands we receive (recorder -> host)
    public enum Rcv {
        public static let ack: UInt8                 = 0x80
        public static let nak: UInt8                 = 0x81
        public static let levelMeterData: UInt8      = 0x83
        public static let limiterIndicator: UInt8    = 0x84
        public static let clipIndicator: UInt8       = 0x85
        public static let locaterTime: UInt8         = 0x86
        public static let timeCode: UInt8            = 0x87
        public static let powerStatus: UInt8         = 0x88
        public static let remainTime: UInt8          = 0x89
        public static let recorderStatus: UInt8      = 0x92
        public static let frameRate: UInt8           = 0x94
        public static let cardStatus: UInt8          = 0x96
        public static let recFormat: UInt8           = 0x98
        public static let trackStatus: UInt8         = 0x9C
        public static let prm: UInt8                 = 0xA1
        public static let allPrmDump: UInt8          = 0xA8
        public static let manufacturerProductName: UInt8 = 0xBB
        public static let popupShowReq: UInt8        = 0xD4
        public static let popupHideReq: UInt8        = 0xDE
        public static let playFileNameMulti: UInt8   = 0xEC
        public static let recFileNameMulti: UInt8    = 0xED
        public static let deviceName: UInt8          = 0xFB
        public static let levelMeterDataH2: UInt8    = 0xFE
    }

    /// Transport keys accepted by KeyOnEdge / KeyOffEdge.
    public enum Key: UInt8, CaseIterable, Sendable { case rec = 0, play = 1, stop = 2 }

    public enum RecorderState: UInt8, Sendable {
        case stop = 0, rec, recPause, play, playPause, rew, ff, prev, next
        public var label: String { ["STOP","REC","REC PAUSE","PLAY","PLAY PAUSE","REW","FF","PREV","NEXT"][Int(rawValue)] }
    }
    public enum PowerSource: UInt8, Sendable {
        case internalPower = 0, external = 1, battery = 2
        public var label: String { ["Internal","External (USB/AC)","Battery"][Int(rawValue)] }
    }
    /// RecFormat payload byte[4] → sample rate, as displayed by the official app.
    public static func sampleRateLabel(_ code: Int) -> String {
        switch code {
        case 0: return "44.1 kHz"
        case 6: return "88.2 kHz"
        case 7: return "96 kHz"
        case 8: return "192 kHz"
        default: return "48 kHz"   // the official app shows 48 kHz for every other code (H6studio reports 3)
        }
    }
    /// PowerStatus battery byte: 0 = no battery / not applicable, 1 = empty ... 4 = full (app shows 4 icons).
    public static func batteryLabel(_ b: Int) -> String {
        switch b { case 0: return "—"; case 1: return "empty"; case 2: return "low"; case 3: return "mid"; default: return "full" }
    }

    /// Build a packet.
    public static func packet(_ cmd: UInt8, _ payload: [UInt8] = []) -> [UInt8] { [cmd, UInt8(payload.count)] + payload }

    public struct HandshakeStep: Sendable {
        public let bytes: [UInt8]; public let expect: UInt8; public let name: String
    }
    /// The 14-step session handshake the official app performs after subscribing to notifications.
    public static let initSequence: [HandshakeStep] = [
        .init(bytes: packet(Snd.connect),                     expect: Rcv.ack,              name: "Connect"),
        .init(bytes: packet(Snd.deviceNameReq),               expect: Rcv.deviceName,       name: "DeviceNameReq"),
        .init(bytes: packet(Snd.appKind, [0x01]),             expect: Rcv.ack,              name: "AppKind=1"),
        .init(bytes: packet(Snd.recorderStatusRequest),       expect: Rcv.recorderStatus,   name: "RecorderStatusRequest"),
        .init(bytes: packet(Snd.cardStatusRequest, [0x00]),   expect: Rcv.cardStatus,       name: "CardStatusRequest"),
        .init(bytes: packet(Snd.recFormatRequest, [0x00]),    expect: Rcv.recFormat,        name: "RecFormatRequest"),
        .init(bytes: packet(Snd.currentPlayFileNameRequest, [0x00]), expect: Rcv.playFileNameMulti, name: "CurrentPlayFileNameRequest"),
        .init(bytes: packet(Snd.powerStatusPermission, [0x01]), expect: Rcv.ack,            name: "PowerStatusPermission on"),
        .init(bytes: packet(Snd.timeCodeEnable, [0x01]),      expect: Rcv.ack,              name: "TimeCodeEnable on"),
        .init(bytes: packet(Snd.timecodePermission, [0x01]),  expect: Rcv.ack,              name: "TimecodePermission on"),
        .init(bytes: packet(Snd.locaterTimePermission, [0x01]), expect: Rcv.ack,            name: "LocaterTimePermission on"),
        .init(bytes: packet(Snd.remainTimePermission, [0x01]), expect: Rcv.ack,             name: "RemainTimePermission on"),
        .init(bytes: packet(Snd.levelMeterPermission, [0x01]), expect: Rcv.ack,             name: "LevelMeterPermission on"),
        .init(bytes: packet(Snd.connectFinished),             expect: Rcv.ack,              name: "ConnectFinished"),
    ]

    public static func keyOn(_ k: Key) -> [UInt8]  { packet(Snd.keyOnEdge,  [k.rawValue]) }
    public static func keyOff(_ k: Key) -> [UInt8] { packet(Snd.keyOffEdge, [k.rawValue]) }

    /// A9 06 sec min hour day month (year-2000)
    public static func setDateTime(_ d: Date = Date()) -> [UInt8] {
        let c = Calendar.current.dateComponents([.year,.month,.day,.hour,.minute,.second], from: d)
        return packet(Snd.setDateTime, [UInt8(c.second!), UInt8(c.minute!), UInt8(c.hour!), UInt8(c.day!), UInt8(c.month!), UInt8(c.year! - 2000)])
    }
    /// 87 06 isFirst hour min sec 01 05   (what the app streams once per second while "sync" is running)
    public static func timecode(isFirst: Bool, _ d: Date = Date()) -> [UInt8] {
        let c = Calendar.current.dateComponents([.hour,.minute,.second], from: d)
        return packet(Snd.timeCode, [isFirst ? 1 : 0, UInt8(c.hour!), UInt8(c.minute!), UInt8(c.second!), 0x01, 0x05])
    }
    /// FC 10 + name padded/truncated to 16 bytes
    public static func setDeviceName(_ name: String) -> [UInt8] {
        var b = Array(name.utf8.prefix(16)); b += [UInt8](repeating: 0, count: 16 - b.count)
        return packet(Snd.setDeviceName, b)
    }

    /// Human-readable decode of an incoming packet.
    public static func describe(_ p: [UInt8]) -> String {
        guard p.count >= 2 else { return "short packet" }
        let cmd = p[0], len = Int(p[1])
        guard p.count >= len + 2 else { return "truncated packet cmd=\(hex(cmd)) len=\(len) got=\(p.count - 2)" }
        let d = p
        func b(_ i: Int) -> Int { i < d.count ? Int(d[i]) : 0 }
        switch cmd {
        case Rcv.ack: return "ACK"
        case Rcv.nak: return "NAK"
        case Rcv.recorderStatus:
            return "RecorderStatus: \(RecorderState(rawValue: d[2])?.label ?? "state \(d[2])")"
        case Rcv.cardStatus:
            return b(2) == 0 ? "CardStatus: \(["none","ok","not-play"][safe: b(3)] ?? "\(b(3))")" : "CardStatus(sub \(b(2))) raw \(hex(Array(d[2...])))"
        case Rcv.recFormat: return "RecFormat: \(sampleRateLabel(b(4)))  raw \(hex(Array(d[2...])))"
        case Rcv.powerStatus:
            return "PowerStatus: battery=\(batteryLabel(b(2))) source=\(PowerSource(rawValue: d[3])?.label ?? "\(d[3])")"
        case Rcv.remainTime:
            if b(2) == 0 { return String(format: "RemainTime: %02d:%02d:%02d", b(5) + (b(6) << 7), b(4), b(3)) }
            return "RemainTime(sub \(b(2))) raw \(hex(Array(d[2...])))"
        case Rcv.locaterTime:
            return String(format: "LocaterTime: %02d:%02d:%02d", b(6) + (b(7) << 7), b(5), b(4))
        case Rcv.levelMeterDataH2: return "LevelMeter: ch=\(b(2)) L=\(b(3)) R=\(b(4))"
        case Rcv.levelMeterData: return "LevelMeterData(83): \(hex(Array(d[2...])))"
        case Rcv.deviceName:
            return "DeviceName: '\(String(decoding: d[2..<(2+len)].filter { $0 != 0 }, as: UTF8.self))'"
        case Rcv.manufacturerProductName:
            return "Manufacturer/Product: raw \(hex(Array(d[2...])))"
        case Rcv.playFileNameMulti, Rcv.recFileNameMulti:
            return "\(cmd == Rcv.playFileNameMulti ? "PlayFileName" : "RecFileName") chunk seq=\(b(2)) raw \(hex(Array(d[2...])))"
        case Rcv.popupShowReq: return "PopupShow: '\(String(decoding: d[2...].filter { $0 >= 0x20 && $0 < 0x7f }, as: UTF8.self))'"
        case Rcv.popupHideReq: return "PopupHide"
        case Rcv.timeCode: return "TimeCode: \(hex(Array(d[2...])))"
        default: return "cmd \(hex(cmd)) len \(len): \(hex(Array(d[2...])))"
        }
    }

    public static func hex(_ b: UInt8) -> String { String(format: "%02x", b) }
    public static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Reassembles the tunnel's notification stream into [cmd,len,payload] packets.
/// A single BLE notification may carry one packet, several, or a partial one.
public struct ZoomPacketAssembler {
    private var buf: [UInt8] = []
    public init() {}
    public mutating func feed(_ data: [UInt8]) -> [[UInt8]] {
        buf += data
        var out: [[UInt8]] = []
        while buf.count >= 2 {
            let n = Int(buf[1]) + 2
            guard buf.count >= n else { break }
            out.append(Array(buf[0..<n])); buf.removeFirst(n)
        }
        return out
    }
    public mutating func reset() { buf.removeAll() }
}

/// Port of the app's FileNameDecoder: file names arrive as EC/ED chunks.
/// seq 0: [cmd len 00 kind totalLo totalHi body...]; seq n: [cmd len n body...]; 3 bytes → 1 char.
public struct ZoomFileNameDecoder {
    private var chunks: [Int: [UInt8]] = [:]
    private var total = 0, count = 0, maxSeq = 0
    public init() {}
    public mutating func add(_ p: [UInt8]) -> String? {
        guard p.count >= 3 else { return nil }
        let seq = Int(p[2])
        chunks[seq] = p; maxSeq = max(maxSeq, seq)
        if seq == 0 {
            total = p.count > 5 ? Int(p[4]) | (Int(p[5]) << 8) : 0
            count = Int(p[1]) - 1
        } else { count += Int(p[1]) - 1 }
        guard count >= total, let first = chunks[0] else { return nil }
        var body = Array(first.dropFirst(6))
        for i in 1...max(1, maxSeq) where i <= maxSeq { if let c = chunks[i] { body += c.dropFirst(3) } }
        var s = ""
        var i = 0
        while i + 2 < body.count {
            let v = (Int(body[i]) & 0x7f) | ((Int(body[i+1]) & 0x7f) << 7) | ((Int(body[i+2]) & 0x03) << 14)
            if v != 0, let u = UnicodeScalar(v) { s.unicodeScalars.append(u) }
            i += 3
        }
        chunks.removeAll(); total = 0; count = 0; maxSeq = 0
        return s
    }
}
