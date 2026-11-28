import Foundation
import UniformTypeIdentifiers

/// Validates local file targets separately from the provider-controlled display text.
struct ToolFileTarget {
    let directory: String
    let filename: String
    private let components: [Substring]

    init?(path: String) {
        guard !path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("\\"),
              path.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        let components = path.split(separator: "/")
        guard let last = components.last, last != ".", !components.contains(".."),
              !path.hasSuffix("/") else { return nil }
        self.components = components.filter { $0 != "." }
        filename = String(last)
        directory = path.lastIndex(of: "/").map { String(path[...$0]) } ?? ""
    }

    func openableURL(in workspace: URL) -> URL? {
        guard workspace.isFileURL else { return nil }
        let root = workspace.resolvingSymlinksInPath().standardizedFileURL
        let file = components.reduce(root) { $0.appendingPathComponent(String($1)) }
        // Match workspace tools: do not follow symlinks inside the workspace.
        guard file.resolvingSymlinksInPath().standardizedFileURL.path == file.standardizedFileURL.path,
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isAliasFileKey, .contentTypeKey]),
              values.isRegularFile == true, values.isAliasFile != true,
              values.contentType?.conforms(to: .executable) != true,
              !Self.launcherExtensions.contains(file.pathExtension.lowercased()),
              !FileManager.default.isExecutableFile(atPath: file.path) else { return nil }
        return file
    }

    private static let launcherExtensions: Set<String> = [
        "command", "terminal", "workflow", "shortcut", "scpt", "webloc", "inetloc", "url"
    ]
}
