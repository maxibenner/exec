// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "ExecRemote",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "ExecRemote", targets: ["ExecRemote"])],
    dependencies: [.package(path: "../ExecTranscript")],
    targets: [
        .target(name: "ExecRemote", dependencies: ["ExecTranscript"]),
        .testTarget(name: "ExecRemoteTests", dependencies: ["ExecRemote", "ExecTranscript"])
    ]
)
