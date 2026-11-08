// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Exec",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Exec", targets: ["Exec"])],
    targets: [
        .executableTarget(name: "Exec")
    ]
)
