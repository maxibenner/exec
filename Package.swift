// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Harness",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Harness", targets: ["Harness"])],
    targets: [
        .executableTarget(name: "Harness")
    ]
)
