// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A language model file mapped from disk.
///
/// The only Foundation in the model path: `Data(contentsOf:options:)` with
/// `.alwaysMapped` keeps the file paged in by the kernel, and the `Data` is
/// the model's owner. Everything else reads the raw bytes.
public enum ModelFile {
    public static func load(_ path: String) throws -> LanguageModel {
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
