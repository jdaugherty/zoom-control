// Copyright (c) 2026 The Zoom Control Authors
// SPDX-License-Identifier: MIT
import SwiftUI
import ZoomKit

/// Owns the Bluetooth client and the local control API for the whole process lifetime,
/// independent of any window. Also sends the protocol-level Disconnect before quitting so the
/// recorder returns to 'Searching'.
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let client = ZoomRecorderClient()
    private(set) var server: ControlServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let s = ControlServer(client: client)
        s.start()
        server = s
        client.startScanning()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard client.phase.isReady || client.phase.isBusy else { return .terminateNow }
        client.disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct ZoomControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Zoom Control") {
            ContentView()
                .environmentObject(delegate.client)
                .frame(minWidth: 440, minHeight: 560)
        }
        .windowResizability(.contentSize)
        .commands { TransportCommands(client: delegate.client) }

        MenuBarExtra {
            MenuBarContent(client: delegate.client)
        } label: {
            MenuBarLabel(client: delegate.client)
        }
    }
}

struct TransportCommands: Commands {
    @ObservedObject var client: ZoomRecorderClient
    var body: some Commands {
        CommandMenu("Transport") {
            Button("Record") { Task { await client.press(.rec) } }
                .keyboardShortcut("r", modifiers: .command).disabled(!client.phase.isReady)
            Button("Stop") { Task { await client.press(.stop) } }
                .keyboardShortcut(".", modifiers: .command).disabled(!client.phase.isReady)
            Button("Play / Pause") { Task { await client.press(.play) } }
                .keyboardShortcut("p", modifiers: .command).disabled(!client.phase.isReady)
            Divider()
            Button("Set Recorder Clock from Mac") { Task { _ = await client.setClock() } }
                .disabled(!client.phase.isReady)
            Button("Disconnect") { client.disconnect() }
                .keyboardShortcut("d", modifiers: .command).disabled(!client.phase.isReady && !client.phase.isBusy)
        }
    }
}

struct MenuBarContent: View {
    @ObservedObject var client: ZoomRecorderClient
    var body: some View {
        Text(client.status.deviceName.isEmpty ? "No recorder connected" : "\(client.status.deviceName): \(client.status.state?.label ?? "—")")
        if let t = client.status.locatorTime, client.phase.isReady { Text(t).font(.body.monospaced()) }
        Divider()
        Button("Record") { Task { await client.press(.rec) } }.disabled(!client.phase.isReady)
        Button("Stop") { Task { await client.press(.stop) } }.disabled(!client.phase.isReady)
        Button("Play / Pause") { Task { await client.press(.play) } }.disabled(!client.phase.isReady)
        Divider()
        Button("Quit Zoom Control") { NSApplication.shared.terminate(nil) }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var client: ZoomRecorderClient
    var body: some View {
        Image(systemName: client.status.state == .rec ? "record.circle.fill" : "record.circle")
            .symbolRenderingMode(client.status.state == .rec ? .multicolor : .monochrome)
    }
}
