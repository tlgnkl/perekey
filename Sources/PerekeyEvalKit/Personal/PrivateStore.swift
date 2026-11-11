// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

/// The folder of personal sets and their runs: `PEREKEY_EVAL_PRIVATE`
/// (docs/eval.md, «Личные наборы»). It lies outside the repository and
/// outside the folders the preview server shows (rule 2.9), and its files are
/// for the owner alone: the folder is 0700, the files 0600.
public struct PrivateStore: Sendable {
    public static let variable = "PEREKEY_EVAL_PRIVATE"

    /// Folders that are shown to other people: the scratchpads of the agent,
    /// which the preview server hands out (the machine's rule «Показать html
    /// человеку»). Compared after symbolic links are resolved.
    public static let publishedPrefixes = ["/private/tmp/claude-"]

    /// The folder, symbolic links resolved.
    public let root: String

    /// Checks a folder and makes it if it is missing. Throws without a word
    /// of any set: only the reason and the path the person gave.
    public init(path: String, forbiddenPrefixes: [String] = Self.publishedPrefixes, creating: Bool = false) throws {
        guard path.hasPrefix("/") else {
            throw EvalError.input("\(Self.variable) must be an absolute path")
        }
        let resolved = Self.resolve(path)
        if let prefix = forbiddenPrefixes.first(where: { resolved.hasPrefix($0) }) {
            throw EvalError.input("\(Self.variable) is inside \(prefix)…, which is shown to other people; choose another folder")
        }
        if let repository = Self.repository(containing: resolved) {
            throw EvalError.input("\(Self.variable) is inside the repository \(repository); personal sets live outside it")
        }
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory) {
            guard creating else { throw EvalError.input("\(Self.variable): no such folder \(path)") }
            try FileManager.default.createDirectory(atPath: resolved, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            // Spotlight does not index a folder that has this file.
            FileManager.default.createFile(atPath: (resolved as NSString).appendingPathComponent(".metadata_never_index"),
                                           contents: nil, attributes: [.posixPermissions: 0o600])
        } else if !isDirectory.boolValue {
            throw EvalError.input("\(Self.variable) is not a folder: \(path)")
        }
        root = resolved
    }

    /// The store the environment names; nil when the variable is unset or empty.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment,
                                       forbiddenPrefixes: [String] = Self.publishedPrefixes,
                                       creating: Bool = false) throws -> PrivateStore?
    {
        guard let path = environment[variable], !path.isEmpty else { return nil }
        return try PrivateStore(path: path, forbiddenPrefixes: forbiddenPrefixes, creating: creating)
    }

    /// Whether a path (a file, or one that does not exist yet) lies in the folder.
    public func contains(_ path: String) -> Bool {
        let resolved = Self.resolve(path)
        return resolved == root || resolved.hasPrefix(root + "/")
    }

    /// An error for a path outside the folder, with no words in it.
    public func require(inside path: String, what: String) throws {
        guard contains(path) else {
            throw EvalError.input("\(what) must be inside \(Self.variable) (\(root)): it holds a personal set")
        }
    }

    /// The hash that stands for a text in the files and the output of a run.
    public func redactor() throws -> Redactor {
        Redactor(salt: try salt())
    }

    private static let saltName = ".salt"

    /// The secret the hashes are salted with: made on first use, 0600, by an exclusive open, so two runs at
    /// once keep one salt. A file of the wrong length is an error, not a reason for a new salt: new hashes
    /// would not match the old runs. Without a salt a hash of a short word would fall to a dictionary.
    private func salt() throws -> Data {
        let path = (root as NSString).appendingPathComponent(Self.saltName)
        func existing() throws -> Data? {
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            guard let data = FileManager.default.contents(atPath: path), data.count == Redactor.saltBytes else {
                throw EvalError.input("\(path) is not a salt of \(Redactor.saltBytes) bytes; remove it only if the runs of this store may stop matching")
            }
            return data
        }
        if let data = try existing() { return data }
        var bytes = [UInt8](repeating: 0, count: Redactor.saltBytes)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw EvalError.input("cannot make the salt of the hashes")
        }
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if descriptor < 0 {
            // Another run made it first: read its salt.
            if errno == EEXIST, let data = try existing() { return data }
            throw EvalError.input("cannot write \(path)")
        }
        defer { close(descriptor) }
        guard Darwin.write(descriptor, bytes, bytes.count) == bytes.count else {
            unlink(path)
            throw EvalError.input("cannot write \(path)")
        }
        return Data(bytes)
    }

    /// Writes a file of the store for its owner alone.
    public func write(_ text: String, to path: String) throws {
        try require(inside: path, what: "the file")
        try Self.ownerOnly(directory: (path as NSString).deletingLastPathComponent)
        FileManager.default.createFile(atPath: path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
        guard FileManager.default.fileExists(atPath: path) else { throw EvalError.input("cannot write \(path)") }
        // A file that was there keeps its rights through the write: tighten them.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    /// Makes a folder (and the ones above it, up to the store) for its owner alone.
    func ownerOnly(directory: String) throws {
        try Self.ownerOnly(directory: directory)
    }

    static func ownerOnly(directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
    }

    /// The path with symbolic links resolved as far as it exists; the rest is
    /// kept. `realpath`, not `URL.resolvingSymlinksInPath`, which turns
    /// `/private/tmp` into `/tmp` and hides the folders that are shown.
    static func resolve(_ path: String) -> String {
        var existing = URL(fileURLWithPath: path).standardized.path
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing), existing != "/" {
            tail.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let real = realpath(existing, &buffer) != nil ? String(cString: buffer) : existing
        return tail.reduce(real) { ($0 as NSString).appendingPathComponent($1) }
    }

    /// The nearest folder above `path` that holds a `.git`.
    static func repository(containing path: String) -> String? {
        var url = URL(fileURLWithPath: path)
        while url.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
            url = url.deletingLastPathComponent()
        }
        return nil
    }
}

/// Stands for a text of a personal set in the files and the output of a run:
/// the same text gives the same hash in every run of one store, so two runs
/// compare, and no hash can be guessed without the salt.
public struct Redactor: Sendable {
    static let saltBytes = 32
    /// The hash is this many hex digits of SHA-256: 48 bits, enough to tell
    /// the words of one person apart.
    static let digits = 12
    let salt: Data

    public init(salt: Data) {
        self.salt = salt
    }

    public func hash(_ text: String) -> String {
        var input = salt
        input.append(Data(text.utf8))
        let hex = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
        return "h:" + hex.prefix(Self.digits)
    }

    /// The id of a personal case as the files and the output of a run name it.
    /// The id in the set's own file is a hash of the case's content, and a
    /// guess at a short word gives it away; this one is salted. The suite and
    /// the scenario stay, so the files read as before.
    public func caseID(_ id: String) -> String {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return hash(id) }
        return "\(parts[0])/\(parts[1])/" + hash(id).dropFirst(2)
    }

    /// What files say for a text of a personal case when no salt is at hand.
    public static let withheld = "(personal)"
}

public extension EvalCase {
    /// The id for files and messages: the case's own, or, for a personal case,
    /// the salted one; without the salt only the suite and the scenario.
    func shownID(_ redactor: Redactor?) -> String {
        guard isPersonal else { return id }
        return redactor?.caseID(id) ?? "\(suite)/\(scenario)/\(Redactor.withheld)"
    }
}
