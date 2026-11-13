// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ExecRemote", platforms: [.macOS(.v14), .iOS(.v17)], products: [.library(name: "ExecRemote", targets: ["ExecRemote"])], targets: [.target(name: "ExecRemote"), .testTarget(name: "ExecRemoteTests", dependencies: ["ExecRemote"])])
