import Foundation
import Darwin

/// Descriptor-relative traversal prevents symlink escapes, including replacement
/// between validation and reading. These constraints do not apply to the shell.
struct WorkspaceFiles: Sendable {
    let root: URL
    private let fileLimit = 1_048_576
    private let outputLimit = 32_768

    private func openPath(_ path: String, directory: Bool) throws -> Int32 {
        guard !path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096 else {
            throw HarnessError("Use a relative workspace path.")
        }
        let parts = path.split(separator: "/").filter { $0 != "." }
        guard !parts.contains("..") else { throw HarnessError("Paths may not leave the workspace.") }
        // Walk the canonical root too: an ancestor replaced with a symlink
        // after folder selection must not redirect a read outside the project.
        let rootParts = root.path.split(separator: "/")
        let allParts = rootParts + parts
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw HarnessError("The workspace is unavailable.") }
        for (index, part) in allParts.enumerated() {
            let isDirectory = index < allParts.count - 1 || directory || parts.isEmpty
            let next = openat(fd, String(part), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (isDirectory ? O_DIRECTORY : 0))
            close(fd)
            guard next >= 0 else { throw HarnessError("Cannot open \(path). Check permissions and avoid symlinks.") }
            fd = next
        }
        return fd
    }

    private func names(_ fd: Int32) throws -> (entries: [String], truncated: Bool) {
        let copy = dup(fd)
        guard copy >= 0 else { throw HarnessError("Cannot list directory.") }
        guard let directory = fdopendir(copy) else { close(copy); throw HarnessError("Cannot list directory.") }
        defer { closedir(directory) }
        var result: [String] = []
        while let entry = readdir(directory) {
            try Task.checkCancellation()
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            if result.count == 2000 { return (result.sorted(), true) }
            result.append(name)
        }
        return (result.sorted(), false)
    }

    func list(_ path: String) throws -> String {
        let fd = try openPath(path, directory: true)
        defer { close(fd) }
        let listing = try names(fd)
        var lines: [String] = []
        var bytes = 0
        var truncated = listing.truncated
        for name in listing.entries {
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            let line = name + (kind == S_IFDIR ? "/" : kind == S_IFLNK ? " [symlink; not followed]" : "")
            if bytes + line.utf8.count + 1 > outputLimit { truncated = true; break }
            lines.append(line); bytes += line.utf8.count + 1
        }
        return (lines.isEmpty ? "(empty directory)" : lines.joined(separator: "\n")) + (truncated ? "\n[Listing truncated; choose a narrower directory.]" : "")
    }

    private func text(_ path: String) throws -> String {
        let fd = try openPath(path, directory: false)
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= fileLimit else {
            throw HarnessError("Read requires a regular text file of at most 1 MiB.")
        }
        var data = Data()
        while data.count <= fileLimit {
            try Task.checkCancellation()
            let chunk = try file.read(upToCount: min(65_536, fileLimit + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= fileLimit, !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw HarnessError("File is not UTF-8 text or exceeds 1 MiB.")
        }
        return text
    }

    func read(_ path: String, start: Int, end: Int) throws -> String {
        guard start >= 1, end >= start, end - start < 400 else { throw HarnessError("Request 1–400 lines, starting at line 1 or later.") }
        let lines = try text(path).components(separatedBy: "\n")
        guard start <= lines.count else { return "Requested range is past end of file (\(lines.count) lines)." }
        var output = ""
        for index in (start - 1)..<min(end, lines.count) {
            let line = "\(index + 1): \(lines[index])\n"
            if output.utf8.count + line.utf8.count > outputLimit { return output + "[Output truncated at 32 KiB.]" }
            output += line
        }
        return output
    }

    func search(_ path: String, query: String) throws -> String {
        guard !query.isEmpty, query.utf8.count <= 4096, !query.contains("\n") else {
            throw HarnessError("Search requires a nonempty single-line literal of at most 4 KiB.")
        }
        // Validate the requested directory even when the search finds no files.
        let initial = try openPath(path, directory: true)
        close(initial)
        var pending = [(path, 0)]
        var visited = 0
        var matches = 0
        var output = ""
        var incomplete = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        search: while let (directory, depth) = pending.popLast() {
            try Task.checkCancellation()
            if visited >= 2000 || ContinuousClock.now >= deadline { incomplete = true; break }
            let fd: Int32
            do { fd = try openPath(directory, directory: true) }
            catch { incomplete = true; continue }
            let listing: (entries: [String], truncated: Bool)
            do { listing = try names(fd) }
            catch { close(fd); throw error }
            close(fd)
            incomplete = incomplete || listing.truncated
            for name in listing.entries {
                try Task.checkCancellation()
                visited += 1
                if visited > 2000 || ContinuousClock.now >= deadline { incomplete = true; break search }
                if name.hasPrefix(".") || ["node_modules", "dist"].contains(name) { continue }
                let relative = directory == "." || directory.isEmpty ? name : directory + "/" + name
                if let child = try? openPath(relative, directory: true) {
                    close(child)
                    if depth < 16 { pending.append((relative, depth + 1)) } else { incomplete = true }
                    continue
                }
                let content: String
                do { content = try text(relative) }
                catch is CancellationError { throw CancellationError() }
                catch { incomplete = true; continue }
                for (index, line) in content.components(separatedBy: "\n").enumerated() where line.contains(query) {
                    let result = "\(relative):\(index + 1): \(line)\n"
                    if matches >= 100 || output.utf8.count + result.utf8.count > outputLimit { incomplete = true; break search }
                    output += result; matches += 1
                }
            }
        }
        return (output.isEmpty ? "No matches in searched files.\n" : output) + (incomplete ? "[Search incomplete: limits reached or unreadable, oversized, binary, or linked files skipped.]" : "")
    }
}
