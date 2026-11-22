// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ExtendPadMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ExtendPad", targets: ["ExtendPad"]),
    ],
    targets: [
        // Private CoreGraphics virtual-display API, isolated and resolved at runtime.
        .target(
            name: "EPVirtualDisplayBridge",
            path: "ExtendPadMac/VirtualDisplay/Bridge",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("Foundation")]
        ),
        // Everything that is not UI: display, capture, encode, transport, connection, input.
        .target(
            name: "ExtendPadCore",
            dependencies: ["EPVirtualDisplayBridge"],
            path: "ExtendPadMac",
            exclude: ["App", "UI", "VirtualDisplay/Bridge", "Resources"],
            sources: ["VirtualDisplay/Swift", "Capture", "Encoder", "Transport", "Connection", "Input", "Diagnostics"],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Network"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        // SwiftUI menu-bar application.
        .executableTarget(
            name: "ExtendPad",
            dependencies: ["ExtendPadCore"],
            path: "ExtendPadMac",
            exclude: ["VirtualDisplay", "Capture", "Encoder", "Transport", "Connection", "Input", "Diagnostics", "Resources"],
            sources: ["App", "UI"]
        ),
        .testTarget(
            name: "ExtendPadCoreTests",
            dependencies: ["ExtendPadCore"],
            path: "Tests/ExtendPadCoreTests"
        ),
    ]
)
