// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

struct TreeEntry: Decodable {
    struct LFS: Decodable { let oid: String }
    let type: String
    let path: String
    let size: Int64?
    let lfs: LFS?
}

struct CatalogFile: Codable {
    /// Path inside the model directory.
    var path: String
    /// Path inside the Hugging Face repository.
    var remotePath: String
    var size: Int64
    var sha256: String
}

struct ManifestSource: Codable {
    var repo: String
    var commit: String
    var files: [CatalogFile]
}

struct Manifest: Codable {
    var id: String
    var sources: [ManifestSource]
}

enum ProbeError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let text): return text }
    }
}

enum ProbePaths {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/perekey-voice-probe", isDirectory: true)
    static func modelDirectory(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    static func manifest(_ id: String) -> URL {
        root.appendingPathComponent("manifests/\(id).json")
    }
}

/// Plain `URLSession` downloader: the file list comes from the Hugging Face API
/// at a pinned commit, the bytes from `resolve/<commit>/<file>?download=true`.
enum Downloader {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        return URLSession(configuration: configuration)
    }()

    static func list(repo: String, commit: String) async throws -> [TreeEntry] {
        var entries: [TreeEntry] = []
        var next: URL? = URL(string: "https://huggingface.co/api/models/\(repo)/tree/\(commit)?recursive=true")
        while let url = next {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw ProbeError.message("tree \(repo)@\(commit): \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            entries += try JSONDecoder().decode([TreeEntry].self, from: data)
            next = nextLink(http.value(forHTTPHeaderField: "Link"))
        }
        return entries.filter { $0.type == "file" }
    }

    private static func nextLink(_ header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") where part.contains("rel=\"next\"") {
            guard let open = part.firstIndex(of: "<"), let close = part.firstIndex(of: ">") else { continue }
            return URL(string: String(part[part.index(after: open)..<close]))
        }
        return nil
    }

    static func resolveURL(repo: String, commit: String, path: String) -> URL {
        let encoded = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        return URL(string: "https://huggingface.co/\(repo)/resolve/\(commit)/\(encoded)?download=true")!
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Downloads every file of the model that is missing or differs from the
    /// pinned commit, checks size and SHA-256 and writes the manifest.
    static func download(_ model: ProbeModel) async throws {
        let directory = ProbePaths.modelDirectory(model.id)
        var manifest = Manifest(id: model.id, sources: [])
        for source in model.sources {
            let entries = try await list(repo: source.repo, commit: source.commit)
                .filter { source.matches($0.path) }
                .sorted { $0.path < $1.path }
            guard !entries.isEmpty else {
                throw ProbeError.message("\(source.repo)@\(source.commit): nothing matches \(source.include)")
            }
            var files: [CatalogFile] = []
            for entry in entries {
                let size = entry.size ?? 0
                let local = source.localPath(entry.path)
                let destination = directory.appendingPathComponent(local)
                let expected = entry.lfs?.oid
                if let existing = try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64,
                    existing == size, let hash = try? sha256(of: destination), expected == nil || expected == hash
                {
                    files.append(CatalogFile(path: local, remotePath: entry.path, size: size, sha256: hash))
                    continue
                }
                let hash = try await fetch(
                    url: resolveURL(repo: source.repo, commit: source.commit, path: entry.path),
                    to: destination, expectedSize: size, expectedHash: expected)
                files.append(CatalogFile(path: local, remotePath: entry.path, size: size, sha256: hash))
                print("  \(model.id): \(local) \(size) bytes")
            }
            manifest.sources.append(ManifestSource(repo: source.repo, commit: source.commit, files: files))
        }
        try FileManager.default.createDirectory(
            at: ProbePaths.manifest(model.id).deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: ProbePaths.manifest(model.id))
    }

    private static func fetch(url: URL, to destination: URL, expectedSize: Int64, expectedHash: String?) async throws
        -> String
    {
        var lastError: Error = ProbeError.message("no attempt")
        for attempt in 1...3 {
            do {
                let (temporary, response) = try await session.download(from: url)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw ProbeError.message("\(url.path): HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                }
                let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? Int64) ?? -1
                guard size == expectedSize else {
                    throw ProbeError.message("\(url.path): got \(size) bytes, expected \(expectedSize)")
                }
                let hash = try sha256(of: temporary)
                if let expectedHash, expectedHash != hash {
                    throw ProbeError.message("\(url.path): SHA-256 \(hash), expected \(expectedHash)")
                }
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                return hash
            } catch {
                lastError = error
                print("  retry \(attempt): \(error)")
            }
        }
        throw lastError
    }
}
