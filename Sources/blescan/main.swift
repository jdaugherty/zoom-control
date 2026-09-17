// Copyright (c) 2026 The Zoom Control Authors
// SPDX-License-Identifier: MIT
import Foundation
import CoreBluetooth

// blescan: discover the Zoom BTA-1 / H6studio over BLE, dump its GATT table,
// read every readable characteristic, subscribe to every notify/indicate
// characteristic and log all traffic as hex.
//
// Usage: blescan [--filter <substring>] [--connect] [--seconds N] [--all]

var filter = "zoom"          // case-insensitive substring match on the advertised name
var doConnect = false
var seconds: Double = 20
var showAll = false

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--filter":  filter = args.removeFirst().lowercased()
    case "--connect": doConnect = true
    case "--seconds": seconds = Double(args.removeFirst()) ?? 20
    case "--all":     showAll = true
    default: break
    }
}

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined(separator: " ") }
func ts() -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: Date())
}
func log(_ s: String) { print("[\(ts())] \(s)"); fflush(stdout) }

final class Scanner: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var seen: [UUID: String] = [:]
    var target: CBPeripheral?
    var chars: [CBCharacteristic] = []

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            log("Bluetooth powered on. Scanning (filter='\(filter)', showAll=\(showAll)) ...")
            c.scanForPeripherals(withServices: nil,
                                 options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        case .unauthorized:
            log("Bluetooth UNAUTHORIZED. Grant Bluetooth access to your terminal app in System Settings > Privacy & Security > Bluetooth, then rerun.")
            exit(2)
        case .poweredOff: log("Bluetooth is powered off."); exit(2)
        case .unsupported: log("BLE unsupported."); exit(2)
        default: log("Bluetooth state: \(c.state.rawValue)")
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "(no name)"
        let match = filter.isEmpty || name.lowercased().contains(filter)
            || filter == "*"
        if !(showAll || match) { return }
        if seen[p.identifier] == nil {
            seen[p.identifier] = name
            log("DISCOVERED \(name)  id=\(p.identifier)  rssi=\(rssi)")
            for (k, v) in ad {
                if let d = v as? Data { log("   adv \(k) = \(hex(d))") }
                else { log("   adv \(k) = \(v)") }
            }
        }
        if match && doConnect && target == nil {
            log("Connecting to \(name) ...")
            target = p
            p.delegate = self
            c.stopScan()
            c.connect(p, options: nil)
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log("CONNECTED to \(p.name ?? "?")  mtu(writeWithoutResponse)=\(p.maximumWriteValueLength(for: .withoutResponse)) mtu(withResponse)=\(p.maximumWriteValueLength(for: .withResponse))")
        p.discoverServices(nil)
    }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("FAILED to connect: \(error?.localizedDescription ?? "?")"); exit(1)
    }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log("DISCONNECTED: \(error?.localizedDescription ?? "clean")"); exit(0)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = p.services else { log("no services: \(error?.localizedDescription ?? "")"); return }
        for s in services {
            log("SERVICE \(s.uuid)  primary=\(s.isPrimary)")
            p.discoverCharacteristics(nil, for: s)
            p.discoverIncludedServices(nil, for: s)
        }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverIncludedServicesFor s: CBService, error: Error?) {
        for inc in s.includedServices ?? [] { log("   included service \(inc.uuid) in \(s.uuid)") }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            log("   CHAR \(ch.uuid) in \(s.uuid)  props=\(props(ch.properties))")
            chars.append(ch)
            p.discoverDescriptors(for: ch)
            if ch.properties.contains(.read) { p.readValue(for: ch) }
            if ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                p.setNotifyValue(true, for: ch)
            }
        }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverDescriptorsFor ch: CBCharacteristic, error: Error?) {
        for d in ch.descriptors ?? [] {
            log("      DESC \(d.uuid) on \(ch.uuid)")
            p.readValue(for: d)
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor d: CBDescriptor, error: Error?) {
        log("      DESC \(d.uuid) on \(d.characteristic?.uuid.uuidString ?? "?") value=\(String(describing: d.value ?? "nil"))")
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        log("   NOTIFY \(ch.isNotifying ? "ON " : "off") \(ch.uuid) \(error.map { "err=\($0.localizedDescription)" } ?? "")")
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if let e = error { log("   READ ERR \(ch.uuid): \(e.localizedDescription)"); return }
        let v = ch.value ?? Data()
        let ascii = String(decoding: v.filter { $0 >= 0x20 && $0 < 0x7f }, as: UTF8.self)
        log("   VALUE \(ch.uuid) [\(v.count)B] \(hex(v))  '\(ascii)'")
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        log("   WROTE \(ch.uuid) \(error.map { "err=\($0.localizedDescription)" } ?? "ok")")
    }

    func props(_ p: CBCharacteristicProperties) -> String {
        var out: [String] = []
        if p.contains(.broadcast) { out.append("broadcast") }
        if p.contains(.read) { out.append("read") }
        if p.contains(.writeWithoutResponse) { out.append("writeNoRsp") }
        if p.contains(.write) { out.append("write") }
        if p.contains(.notify) { out.append("notify") }
        if p.contains(.indicate) { out.append("indicate") }
        if p.contains(.authenticatedSignedWrites) { out.append("signedWrite") }
        if p.contains(.extendedProperties) { out.append("ext") }
        return out.joined(separator: "|")
    }
}

let scanner = Scanner()
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    log("Timeout after \(Int(seconds))s. Seen \(scanner.seen.count) matching peripheral(s).")
    if let t = scanner.target { scanner.central.cancelPeripheralConnection(t) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
}
RunLoop.main.run()
