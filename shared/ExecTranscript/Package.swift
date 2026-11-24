// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ExecTranscript",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "ExecTranscript", type: .static, targets: ["ExecTranscript"])],
    dependencies: [
        // Use the original URL to share package identity with the pinned grammar manifests.
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter", exact: "0.25.10"),
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", exact: "0.7.1-with-generated-files"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.23.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.23.6"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust", exact: "0.24.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-go", exact: "0.23.4"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-c", exact: "0.23.4"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-cpp", exact: "0.23.4"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash", exact: "0.23.3"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-html", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-css", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", exact: "0.24.8"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-yaml", exact: "0.6.1"),
    ],
    targets: [
        .target(
            name: "ExecTranscript",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitter", package: "tree-sitter"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
                .product(name: "TreeSitterC", package: "tree-sitter-c"),
                .product(name: "TreeSitterCPP", package: "tree-sitter-cpp"),
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
                .product(name: "TreeSitterHTML", package: "tree-sitter-html"),
                .product(name: "TreeSitterCSS", package: "tree-sitter-css"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterYAML", package: "tree-sitter-yaml"),
            ],
            resources: [.copy("SyntaxQueries")]
        ),
        .testTarget(name: "ExecTranscriptTests", dependencies: ["ExecTranscript"]),
    ]
)
