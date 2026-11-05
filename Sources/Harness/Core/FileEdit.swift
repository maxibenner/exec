import Foundation
import Darwin

/// Serialize this app's replacements so two conversations cannot both pass the final check
/// against the same old file. Shell commands and external writers remain outside this lock.
actor FileEditWriter {
    static let shared = FileEditWriter()
    func apply(_ edit: FileEdit, workspace: Workspace) throws -> String {
        try edit.apply(workspace: workspace)
    }
}

/// One exact replacement, or creation of a new file. No fuzzy patches or deletes.
struct FileEdit: Sendable {
    struct Arguments: Decodable, Sendable {
        let path: String
        let expected_revision: String
        let old_text: String
        let new_text: String
    }
    let path: String
    let before: Data?
    let after: Data
    let inode: UInt64?
    let device: Int32?
    let diff: String

    static func prepare(_ arguments: Arguments, workspace: Workspace) throws -> FileEdit {
        let parent = try WorkspaceFiles(root: workspace.root).parent(of: arguments.path)
        defer { close(parent.descriptor) }
        let fd = openat(parent.descriptor, parent.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        var before: Data?
        var info = stat()
        if fd >= 0 {
            defer { close(fd) }
            before = try WorkspaceFiles.readTextData(fd)
            guard fstat(fd, &info) == 0, info.st_mode & (S_ISUID | S_ISGID) == 0 else {
                throw HarnessError("Cannot edit this file's permissions/type.")
            }
            guard arguments.expected_revision == WorkspaceFiles.revision(before!) else {
                throw HarnessError("File changed or revision is missing. Read the file again before proposing an edit.")
            }
        } else {
            guard errno == ENOENT, arguments.expected_revision == "new", arguments.old_text.isEmpty else {
                throw HarnessError("Cannot edit this path. Read an existing regular file first, or use revision 'new' with empty old_text to create a file.")
            }
        }
        var after = before ?? Data()
        let old = Data(arguments.old_text.utf8)
        let replacement = Data(arguments.new_text.utf8)
        if old.isEmpty {
            guard after.isEmpty else { throw HarnessError("old_text must match one nonempty block in an existing file.") }
            after = replacement
        } else {
            guard let range = after.range(of: old),
                  after.range(of: old, in: (range.lowerBound + 1)..<after.endIndex) == nil else {
                throw HarnessError("old_text must match exactly once. Include more surrounding text and try again.")
            }
            after.replaceSubrange(range, with: replacement)
        }
        guard after.count <= WorkspaceFiles.fileLimit, !after.contains(0), before != after else {
            throw HarnessError("Edit is unchanged, contains NUL bytes, or exceeds 1 MiB.")
        }
        let diff = preview(path: arguments.path, before: before, after: after)
        guard diff.utf8.count <= 65_536 else { throw HarnessError("The complete diff exceeds 64 KiB. Propose a smaller edit.") }
        return FileEdit(path: arguments.path, before: before, after: after,
                        inode: before == nil ? nil : info.st_ino, device: before == nil ? nil : info.st_dev, diff: diff)
    }

    func apply(workspace: Workspace) throws -> String {
        try Task.checkCancellation()
        let parent = try WorkspaceFiles(root: workspace.root).parent(of: path)
        defer { close(parent.descriptor) }
        let source = openat(parent.descriptor, parent.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        defer { if source >= 0 { close(source) } }
        var original = stat()
        if let before {
            guard source >= 0, fstat(source, &original) == 0, original.st_mode & (S_ISUID | S_ISGID) == 0,
                  original.st_ino == inode, original.st_dev == device,
                  try WorkspaceFiles.readTextData(source) == before else {
                throw HarnessError("File changed while approval was pending. Nothing was written; read it again and propose a new edit.")
            }
        } else if source >= 0 || errno != ENOENT {
            throw HarnessError("The new file path is no longer available. Nothing was written.")
        }

        let temporary = ".harness-edit-\(UUID().uuidString)"
        let target = openat(parent.descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard target >= 0 else { throw HarnessError("Cannot stage the edit in this directory.") }
        defer { close(target); unlinkat(parent.descriptor, temporary, 0) }
        let file = FileHandle(fileDescriptor: target, closeOnDealloc: false)
        try file.write(contentsOf: after)
        if source >= 0 {
            // Preserve ACLs, extended attributes and ordinary mode bits; don't
            // turn replacement into an accidental permissions change.
            guard fchown(target, original.st_uid, original.st_gid) == 0,
                  fcopyfile(source, target, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR)) == 0,
                  fchmod(target, original.st_mode & 0o777) == 0 else {
                throw HarnessError("Could not preserve file permissions/attributes. Nothing was written.")
            }
        }
        try file.synchronize()
        try Task.checkCancellation()
        if let before {
            var current = stat()
            guard fstatat(parent.descriptor, parent.name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_ino == inode, current.st_dev == device,
                  current.st_mode == original.st_mode, current.st_uid == original.st_uid, current.st_gid == original.st_gid,
                  current.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec,
                  current.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec,
                  try WorkspaceFiles.readTextData(source) == before else {
                throw HarnessError("File changed before replacement. Nothing was written.")
            }
            guard renameat(parent.descriptor, temporary, parent.descriptor, parent.name) == 0 else {
                throw HarnessError("Could not replace the file.")
            }
        } else {
            guard renameatx_np(parent.descriptor, temporary, parent.descriptor, parent.name, UInt32(RENAME_EXCL)) == 0 else {
                throw HarnessError("Could not create the file; it may now exist. Nothing was overwritten.")
            }
        }
        return "Edited \(path). Revision: \(WorkspaceFiles.revision(after))"
    }

    private static func preview(path: String, before: Data?, after: Data) -> String {
        let oldText = String(decoding: before ?? Data(), as: UTF8.self)
        let newText = String(decoding: after, as: UTF8.self)
        func lines(_ text: String) -> [String] {
            if text.isEmpty { return [] }
            var lines = text.components(separatedBy: "\n")
            if text.hasSuffix("\n") { lines.removeLast() }
            return lines
        }
        let old = lines(oldText), new = lines(newText)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        let sameLines = old == new
        if sameLines { prefix = max(0, prefix - 1) } // A final-newline-only change.
        var suffix = 0
        while !sameLines, oldText.hasSuffix("\n") == newText.hasSuffix("\n"),
              suffix < min(old.count, new.count) - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        let start = max(0, prefix - 3)
        let oldEnd = min(old.count, old.count - suffix + 3)
        let newEnd = min(new.count, new.count - suffix + 3)
        var result = "--- \(before == nil ? "/dev/null" : path.debugDescription)\n+++ \(path.debugDescription)\n@@ -\(old.isEmpty ? 0 : start + 1),\(oldEnd - start) +\(new.isEmpty ? 0 : start + 1),\(newEnd - start) @@\n"
        func append(_ line: String, prefix: String, last: Bool, newline: Bool) {
            result += prefix + line.replacingOccurrences(of: "\r", with: "\\r") + "\n"
            if last && !newline { result += "\\ No newline at end of file\n" }
        }
        for index in start..<prefix { append(old[index], prefix: " ", last: false, newline: true) }
        for index in prefix..<(old.count - suffix) {
            append(old[index], prefix: "-", last: index == old.count - 1, newline: oldText.hasSuffix("\n"))
        }
        for index in prefix..<(new.count - suffix) {
            append(new[index], prefix: "+", last: index == new.count - 1, newline: newText.hasSuffix("\n"))
        }
        for index in (new.count - suffix)..<newEnd {
            append(new[index], prefix: " ", last: index == new.count - 1, newline: newText.hasSuffix("\n"))
        }
        return result
    }
}
