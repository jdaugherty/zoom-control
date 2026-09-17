// Copyright (c) 2026 The Zoom Control Authors
// SPDX-License-Identifier: MIT
import SwiftUI
import ZoomKit

struct ContentView: View {
    @EnvironmentObject var client: ZoomRecorderClient
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if client.phase.isReady || client.phase.isBusy {
                recorderPanel
            } else {
                devicePicker
            }
            Divider()
            logSection
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: header
    private var header: some View {
        HStack(spacing: 10) {
            Circle().fill(phaseColor).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(client.status.deviceName.isEmpty ? "Zoom Control" : client.status.deviceName)
                    .font(.headline)
                Text(phaseText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if client.phase.isReady || client.phase.isBusy {
                Button("Disconnect") { client.disconnect() }
            }
        }
        .padding(12)
    }

    private var phaseColor: Color {
        switch client.phase {
        case .ready: return .green
        case .connecting, .handshaking: return .yellow
        case .failed, .bluetoothOff, .unauthorized: return .red
        default: return .gray
        }
    }
    private var phaseText: String {
        switch client.phase {
        case .bluetoothOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth permission denied — allow Zoom Control in System Settings › Privacy & Security › Bluetooth"
        case .idle: return "Not connected"
        case .scanning: return "Searching… put the recorder in Bluetooth › Control & Sync mode"
        case .connecting: return "Connecting…"
        case .handshaking(let step): return "Opening session… \(step)"
        case .ready:
            var parts: [String] = []
            if !client.status.model.isEmpty { parts.append(client.status.model) }
            if !client.status.firmware.isEmpty { parts.append("fw \(client.status.firmware)") }
            return parts.isEmpty ? "Connected" : parts.joined(separator: " · ")
        case .failed(let msg): return msg
        }
    }

    // MARK: device picker
    private var devicePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recorders").font(.subheadline.weight(.semibold))
                Spacer()
                if client.phase == .scanning { ProgressView().controlSize(.small) }
                Button(client.phase == .scanning ? "Stop" : "Scan") {
                    client.phase == .scanning ? client.stopScanning() : client.startScanning()
                }
            }
            Toggle("Connect automatically to the first recorder found", isOn: $client.autoConnect)
                .toggleStyle(.checkbox).font(.callout)
            if client.discovered.isEmpty {
                Text("No recorders found yet. On the H6studio choose Bluetooth › Control & Sync so it starts searching, and make sure the BTA-1 is fitted.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            } else {
                ForEach(client.discovered) { d in
                    Button {
                        client.connect(d.id)
                    } label: {
                        HStack {
                            Image(systemName: "waveform.circle.fill").font(.title2)
                            VStack(alignment: .leading) {
                                Text(d.name).font(.body.weight(.medium))
                                Text("Signal \(d.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Connect").foregroundStyle(.tint)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: recorder panel
    private var recorderPanel: some View {
        let s = client.status
        return VStack(spacing: 14) {
            // transport state + counters
            VStack(spacing: 6) {
                Text(s.state?.label ?? "—")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(stateColor(s.state))
                    .frame(maxWidth: .infinity)
                Text(s.locatorTime ?? "00:00:00")
                    .font(.system(size: 30, weight: .medium, design: .monospaced))
                HStack(spacing: 16) {
                    Label("Remaining \(s.cardState == 0 ? "--:--:--" : (s.remainTime ?? "--:--:--"))", systemImage: "sdcard")
                    if let sr = s.sampleRate { Label(sr, systemImage: "waveform") }
                    Label(powerText(s), systemImage: powerIcon(s))
                }
                .font(.callout).foregroundStyle(.secondary)
                if let f = s.recFileName ?? s.playFileName, !f.isEmpty {
                    Text(f).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if let popup = s.popup, !popup.isEmpty {
                    Text(popup).font(.callout).padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.yellow.opacity(0.25)))
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))

            // meters
            VStack(spacing: 6) {
                MeterBar(label: s.meterChannels == 1 ? "M" : "L", value: s.meterL)
                if s.meterChannels != 1 { MeterBar(label: "R", value: s.meterR) }
            }

            // transport buttons
            HStack(spacing: 14) {
                TransportButton(title: "REC", systemImage: "record.circle", tint: .red,
                                active: s.state == .rec || s.state == .recPause) { await client.press(.rec) }
                TransportButton(title: "STOP", systemImage: "stop.fill", tint: .primary,
                                active: s.state == .stop) { await client.press(.stop) }
                TransportButton(title: "PLAY", systemImage: "playpause.fill", tint: .green,
                                active: s.state == .play || s.state == .playPause) { await client.press(.play) }
            }
            .disabled(!client.phase.isReady)

            HStack {
                Button { Task { _ = await client.setClock() } } label: { Label("Set clock from Mac", systemImage: "clock.arrow.2.circlepath") }
                Spacer()
                Text("⌘R record · ⌘. stop · ⌘P play · API ws://127.0.0.1:\(ControlServer.defaultPort)").font(.caption).foregroundStyle(.tertiary)
            }
            .disabled(!client.phase.isReady)
        }
        .padding(12)
    }

    private func stateColor(_ st: Zoom.RecorderState?) -> Color {
        switch st {
        case .rec: return .red
        case .recPause: return .orange
        case .play, .playPause: return .green
        case nil: return .secondary
        default: return .primary
        }
    }
    private func powerText(_ s: RecorderStatus) -> String {
        guard let src = s.powerSource else { return "Power —" }
        if src == .battery, let b = s.battery { return "Battery \(Zoom.batteryLabel(b))" }
        return src.label
    }
    private func powerIcon(_ s: RecorderStatus) -> String {
        guard let src = s.powerSource else { return "bolt" }
        if src != .battery { return "powerplug" }
        switch s.battery ?? 0 { case 1: return "battery.0"; case 2: return "battery.25"; case 3: return "battery.50"; default: return "battery.100" }
    }

    // MARK: log
    private var logSection: some View {
        VStack(spacing: 0) {
            HStack {
                Button { withAnimation { showLog.toggle() } } label: {
                    Label("Protocol log", systemImage: showLog ? "chevron.down" : "chevron.right")
                }.buttonStyle(.plain)
                Spacer()
                if showLog {
                    Toggle("meters", isOn: $client.logMeters).toggleStyle(.checkbox).font(.caption)
                    Button("Clear") { client.clearLog() }.controlSize(.small)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            if showLog {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(client.log) { line in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(line.time, format: .dateTime.hour().minute().second())
                                        .foregroundStyle(.tertiary)
                                    Text(prefix(line.direction)).foregroundStyle(color(line.direction))
                                    Text(line.text).textSelection(.enabled)
                                }
                                .font(.system(size: 11, design: .monospaced))
                                .id(line.id)
                            }
                        }
                        .padding(8)
                    }
                    .frame(height: 180)
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: client.log.count) { _ in
                        if let last = client.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }
    private func prefix(_ d: LogLine.Direction) -> String { switch d { case .sent: return "→"; case .received: return "←"; case .info: return "•" } }
    private func color(_ d: LogLine.Direction) -> Color { switch d { case .sent: return .blue; case .received: return .green; case .info: return .secondary } }
}

struct MeterBar: View {
    let label: String
    let value: Int   // 0...127
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption.monospaced().weight(.bold)).frame(width: 14)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: .controlBackgroundColor))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * CGFloat(min(max(value, 0), 127)) / 127)
                        .animation(.linear(duration: 0.08), value: value)
                }
            }
            .frame(height: 14)
            Text(String(format: "%3d", value)).font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
        }
    }
}

struct TransportButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let active: Bool
    let action: () async -> Void
    var body: some View {
        Button { Task { await action() } } label: {
            VStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 26))
                Text(title).font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity).frame(height: 70)
            .background(RoundedRectangle(cornerRadius: 12).fill(active ? tint.opacity(0.25) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(active ? tint : .clear, lineWidth: 2))
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}
