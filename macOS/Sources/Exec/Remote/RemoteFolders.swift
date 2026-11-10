import Foundation

/// Authenticated, shallow folder discovery on the host Mac. This is not a file
/// download API or a sandbox: workspace tools retain their normal approval rules.
enum RemoteFolders {
    struct Listing: Encodable, Sendable {
        struct Folder: Encodable, Sendable {
            let name: String
            let path: String
        }
        let path: String
        let parent: String?
        let folders: [Folder]
        let truncated: Bool
    }

    static func directory(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw ExecError("Choose an absolute folder path on the Mac.")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        guard values.isDirectory == true, values.isPackage != true,
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw ExecError("Choose a readable folder, not a file or application.")
        }
        return url
    }

    static func list(_ path: String) throws -> Listing {
        let directory = try directory(path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        var readError: Error?
        guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys,
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, error in readError = error; return false }) else {
            throw ExecError("Could not open this folder.")
        }
        var folders: [Listing.Folder] = []
        var inspected = 0
        var truncated = false
        for case let url as URL in entries {
            try Task.checkCancellation()
            inspected += 1
            if inspected > 5000 || folders.count >= 1000 { truncated = true; break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true, values.isPackage != true else { continue }
            folders.append(.init(name: url.lastPathComponent, path: url.path))
        }
        if let readError { throw readError }
        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Listing(path: directory.path, parent: directory.path == "/" ? nil : directory.deletingLastPathComponent().path,
                       folders: folders, truncated: truncated)
    }
}
