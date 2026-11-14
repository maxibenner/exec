// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ExecTranscript", platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "ExecTranscript", targets: ["ExecTranscript"])],
    targets: [.target(name: "ExecTranscript"), .testTarget(name: "ExecTranscriptTests", dependencies: ["ExecTranscript"])])
