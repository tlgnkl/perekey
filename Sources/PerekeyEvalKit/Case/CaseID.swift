// SPDX-License-Identifier: GPL-3.0-or-later

/// FNV-1a, 64 bits: the hash of case ids and of the dev/test split.
public enum FNV1a {
    public static func hash64(_ bytes: some Sequence<UInt8>) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return hash
    }

    public static func hash64(_ text: String) -> UInt64 { hash64(text.utf8) }
}

public extension EvalCase {
    /// The content the id hashes: `layouts`, `start`, `env`, `warmup`,
    /// `script`, `want`, each as canonical JSON, joined by U+001F. An absent
    /// `env` reads as `{}` and an absent `warmup` as `[]`: the same content.
    func canonicalContent() throws -> String {
        let parts = try [
            CaseCodec.json(layouts),
            CaseCodec.json(start),
            env.map { try CaseCodec.json($0) } ?? "{}",
            CaseCodec.json(warmup ?? []),
            CaseCodec.json(script),
            CaseCodec.json(want),
        ]
        return parts.joined(separator: "\u{1F}")
    }

    /// `<suite>/<scenario>/<12 hex>`: the same content, the same id.
    func computedID() throws -> String {
        let hex = String(FNV1a.hash64(try canonicalContent()), radix: 16)
        let padded = String(repeating: "0", count: 16 - hex.count) + hex
        return "\(suite)/\(scenario)/\(padded.prefix(12))"
    }

    /// The case with its id computed.
    func identified() throws -> EvalCase {
        var copy = self
        copy.id = try computedID()
        return copy
    }
}
