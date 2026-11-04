import Foundation
import Darwin

/// A snapshot of the selected project's root instructions, not a filesystem sandbox.
struct Workspace: Sendable {
    static let instructionByteLimit = 64 * 1024
    let root: URL
    let instructions: String?

    var modelInstructions: String {
        var text = "Selected workspace: \(root.path)"
        if let instructions {
            text += "\n\nProject instructions from the workspace root AGENTS.md:\n\(instructions)"
        }
        return text
    }

    static func load(_ url: URL) throws -> Workspace {
        guard url.isFileURL else { throw HarnessError("Choose a local project folder.") }
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw HarnessError("Could not open the project folder. Check that it exists and you have permission to read it.") }
        defer { close(directory) }

        // Anchor the read to the opened directory. Don't follow an AGENTS.md
        // symlink or block on a special file such as a named pipe.
        let descriptor = openat(directory, "AGENTS.md", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return Workspace(root: root, instructions: nil) }
            throw HarnessError("Could not read AGENTS.md. It must be a readable regular file, not a symbolic link.")
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw HarnessError("AGENTS.md must be a regular UTF-8 text file.")
        }
        var data = Data()
        while data.count <= instructionByteLimit {
            try Task.checkCancellation()
            let chunk = try file.read(upToCount: instructionByteLimit + 1 - data.count) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= instructionByteLimit else {
            throw HarnessError("AGENTS.md exceeds the 64 KiB instruction limit. Shorten it before selecting this workspace.")
        }
        guard let instructions = String(data: data, encoding: .utf8) else {
            throw HarnessError("AGENTS.md must be UTF-8 text. Convert it before selecting this workspace.")
        }
        return Workspace(root: root, instructions: instructions)
    }
}
