import Darwin
import Foundation

/// A file as the editor shows it.
public struct EditorFile: Hashable, Sendable {
    public let name: String
    public var content: String
    public let readOnly: Bool

    public init(name: String, content: String, readOnly: Bool) {
        self.name = name
        self.content = content
        self.readOnly = readOnly
    }
}

/// Lesson folders for building, running and testing code, and for opening it in an editor:
/// ~/Library/Caches/Gopherwood/work/<lesson>/ holds the readme, your files, the read-only
/// tests and go.mod, so `go build` and `go test` work there in a terminal too. Hidden files
/// are never written; they are added at build time.
///
/// The folder is disposable: your code lives in the database (code_file). Preparing a folder
/// writes what the database holds, unless the file on disk is newer, which means you edited
/// it in another editor; then the disk wins and the caller saves it to the database.
public struct Workspace: Sendable {
    public let root: URL

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gopherwood/work", isDirectory: true)
    }

    public init(root: URL = Workspace.defaultRoot) {
        self.root = root
    }

    /// Where runs keep their overlay files and binaries while they last: work/.runs.
    public var runsFolder: URL {
        root.appendingPathComponent(".runs", isDirectory: true)
    }

    /// Removes what runs left behind, such as after a crash: folders in .runs older than
    /// `age`. A run in progress (of another copy of the app) is younger and stays.
    @discardableResult
    public func removeStaleRuns(olderThan age: Duration = .seconds(600), now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: runsFolder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return 0 }
        var removed = 0
        for url in entries {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard now.timeIntervalSince(modified) > Double(age.components.seconds) else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// The lesson's folder, named by its uuid (slugs repeat across chapters).
    public func folder(for lesson: LessonDetail) -> URL {
        root.appendingPathComponent(lesson.id.replacingOccurrences(of: "/", with: "-"), isDirectory: true)
    }

    /// What preparing a folder found.
    public struct Prepared: Sendable {
        public var folder: URL
        /// The visible files, with your code in the editable ones.
        public var files: [EditorFile]
        /// Editable files whose copy on disk was newer than the database's: save these.
        public var readBack: [CodeFileRecord]
    }

    /// Creates or refreshes a lesson's folder. The readme, read-only files and go.mod come
    /// from the lesson; editable files from `saved` (the database) or the starter code,
    /// unless the folder holds a newer edit.
    /// `unsettled` names files left in conflict when the app last quit: their copy on disk is
    /// left alone, and the editor gets yours from the database, so the next save asks.
    public func prepare(_ lesson: LessonDetail, code: CodeExercise, saved: [String: CodeFileRecord], goVersion: String,
                        unsettled: Set<String> = []) throws -> Prepared {
        let dir = folder(for: lesson)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !lesson.readme.isEmpty {
            try Workspace.writeIfChanged(dir.appendingPathComponent("README.md"), lesson.readme, mode: 0o644)
        }
        var files: [EditorFile] = []
        var readBack: [CodeFileRecord] = []
        for f in code.starterFiles where f.isVisible {
            let path = try Workspace.lessonPath(dir, f.name)
            if f.isReadonly {
                try Workspace.writeIfChanged(path, f.content, mode: 0o444)
                files.append(EditorFile(name: f.name, content: f.content, readOnly: true))
                continue
            }
            let mine = saved[f.name]
            var content = mine?.content ?? f.content
            if unsettled.contains(f.name) {
                files.append(EditorFile(name: f.name, content: content, readOnly: false))
                continue
            }
            if let disk = try? String(contentsOf: path, encoding: .utf8) {
                let modified = (try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if let mine {
                    if disk != mine.content {
                        if modified > (Clock.date(mine.updatedAt) ?? .distantPast) {
                            content = disk
                            readBack.append(CodeFileRecord(name: f.name, content: disk, updatedAt: Clock.string(modified)))
                        } else {
                            try Workspace.writeIfChanged(path, mine.content, mode: 0o644)
                        }
                    }
                } else if disk != f.content {
                    content = disk
                    readBack.append(CodeFileRecord(name: f.name, content: disk, updatedAt: Clock.string(modified)))
                }
            } else {
                try Workspace.writeIfChanged(path, content, mode: 0o644)
            }
            files.append(EditorFile(name: f.name, content: content, readOnly: false))
        }
        if code.runsHere {
            let mod = dir.appendingPathComponent("go.mod")
            if !FileManager.default.fileExists(atPath: mod.path) {
                try Workspace.writeIfChanged(mod, "module lesson\n\ngo \(goVersion)\n", mode: 0o644)
            }
        }
        return Prepared(folder: dir, files: files, readBack: readBack)
    }

    /// Writes one of your files into the lesson folder.
    public func write(_ lesson: LessonDetail, name: String, content: String) throws {
        let path = try Workspace.lessonPath(folder(for: lesson), name)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Workspace.writeIfChanged(path, content, mode: 0o644)
    }

    /// Resolves a lesson file name inside `dir`, refusing names that would escape it.
    public static func lessonPath(_ dir: URL, _ name: String) throws -> URL {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !name.isEmpty, !name.hasPrefix("/"), !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else {
            throw WorkspaceError.badName(name)
        }
        return dir.appendingPathComponent(name)
    }

    /// Writes `content` unless the file already holds exactly that with the same mode. Goes
    /// through a temporary file and a rename, which also replaces read-only files.
    public static func writeIfChanged(_ url: URL, _ content: String, mode: mode_t) throws {
        let fm = FileManager.default
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == content,
           let attrs = try? fm.attributesOfItem(atPath: url.path), let perms = attrs[.posixPermissions] as? NSNumber,
           mode_t(perms.uint16Value) == mode {
            return
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".tmp")
        try? fm.removeItem(at: tmp)
        try Data(content.utf8).write(to: tmp)
        guard chmod(tmp.path, mode) == 0 else { throw WorkspaceError.io(tmp.path, String(cString: strerror(errno))) }
        guard rename(tmp.path, url.path) == 0 else { throw WorkspaceError.io(url.path, String(cString: strerror(errno))) }
    }
}

public enum WorkspaceError: Error, LocalizedError, Sendable {
    case badName(String)
    case io(String, String)

    public var errorDescription: String? {
        switch self {
        case .badName(let name): "\(name) is not a file name inside the lesson."
        case .io(let path, let message): "Could not write \(path): \(message)"
        }
    }
}
