import Foundation

/// Frontend selection only. Rust canonicalizes paths and freezes root instructions.
struct Workspace: Codable, Sendable {
    let root: URL
    static func load(_ url: URL) throws -> Workspace {
        guard url.isFileURL else { throw ExecError("Choose a local project folder.") }
        return Workspace(root: url)
    }
}
