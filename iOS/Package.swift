// swift-tools-version: 6.0
import PackageDescription

// Run the iOS store's lifecycle checks on macOS without launching the app or
// accessing a real device credential. The UI remains in the Xcode app target.
let package = Package(
    name: "ExecRemoteStoreChecks",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../shared/ExecRemote")],
    targets: [
        .target(
            name: "ExecRemoteStore",
            dependencies: [.product(name: "ExecRemote", package: "ExecRemote")],
            path: "ExecRemote",
            exclude: ["Assets.xcassets", "ExecRemoteApp.swift", "HostConnectionOverlay.swift", "Info.plist", "NativeTranscript.swift", "RemoteUIFixture.swift", "TranscriptUIFixture.swift", "ScannerView.swift"],
            sources: ["RemoteStore.swift", "ConversationPresentation.swift", "DeviceStore.swift", "TranscriptScrollState.swift", "ThinkingIndicatorLifecycle.swift"]
        ),
        .testTarget(name: "ExecRemoteStoreTests", dependencies: ["ExecRemoteStore"], path: "Tests")
    ]
)
