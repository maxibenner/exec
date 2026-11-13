// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Exec",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Exec", targets: ["Exec"])],
    dependencies: [
        .package(path: "../shared/ExecRemote"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .executableTarget(name: "Exec", dependencies: [
            .product(name: "ExecRemote", package: "ExecRemote"),
            .product(name: "Sparkle", package: "Sparkle")
        ])
    ]
)
