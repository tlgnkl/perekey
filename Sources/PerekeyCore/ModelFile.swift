// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A language model file mapped from disk.
///
/// The only Foundation in the model path: `Data(contentsOf:options:)` with
/// `.alwaysMapped` keeps the file paged in by the kernel, and the `Data` is
/// the model's owner. Everything else reads the raw bytes.
public enum ModelFile {
    /// The extension of a model file: `ru.pklm`, `en.pklm`.
    public static let fileExtension = "pklm"

    /// A model file, or a directory of them. From a directory it maps the
    /// files of `languages` that are there (`<language>.pklm`), or every
    /// file when `languages` is nil.
    public static func load(_ path: String, languages: [String]? = nil) throws -> LanguageModel {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return try loadFile(path)
        }
        let names = try languages.map { $0.map { "\($0).\(fileExtension)" } }
            ?? FileManager.default.contentsOfDirectory(atPath: path).filter { $0.hasSuffix(".\(fileExtension)") }.sorted()
        let models = try names.map { "\(path)/\($0)" }.filter { FileManager.default.fileExists(atPath: $0) }.map(loadFile)
        guard !models.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
        return LanguageModel(combining: models)
    }

    /// One model file.
    public static func loadFile(_ path: String) throws -> LanguageModel {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        let box = DataBox(data)
        return try LanguageModel(bytes: box.buffer, owner: box)
    }
}

/// Keeps a `Data` alive at a stable address.
final class DataBox: @unchecked Sendable {
    private let data: NSData
    let buffer: UnsafeRawBufferPointer

    init(_ data: Data) {
        // Bridging to NSData gives one stable pointer for the object's life.
        let stable = data as NSData
        self.data = stable
        buffer = UnsafeRawBufferPointer(start: stable.bytes, count: stable.length)
    }
}
