// swift-tools-version:5.9
// Copyright (c) 2026 The Zoom Control Authors
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
    name: "ZoomControl",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ZoomKit", targets: ["ZoomKit"]),
        .executable(name: "ZoomControl", targets: ["ZoomControl"]),
        .executable(name: "zoomctl", targets: ["zoomctl"]),
        .executable(name: "blescan", targets: ["blescan"]),
    ],
    targets: [
        // Protocol + CoreBluetooth client shared by the app and the CLI.
        .target(name: "ZoomKit", path: "Sources/ZoomKit",
                linkerSettings: [.linkedFramework("CoreBluetooth")]),
        // SwiftUI macOS app.
        .executableTarget(name: "ZoomControl", dependencies: ["ZoomKit"], path: "Sources/ZoomControl",
                          linkerSettings: [.linkedFramework("CoreBluetooth"), .linkedFramework("SwiftUI")]),
        // Command-line control / protocol exploration tool.
        .executableTarget(name: "zoomctl", dependencies: ["ZoomKit"], path: "Sources/zoomctl",
                          linkerSettings: [.linkedFramework("CoreBluetooth")]),
        // Generic BLE scanner / GATT dumper for BLE debugging.
        .executableTarget(name: "blescan", path: "Sources/blescan",
                          linkerSettings: [.linkedFramework("CoreBluetooth")]),
    ]
)
