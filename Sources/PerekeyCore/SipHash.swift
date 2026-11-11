// SPDX-License-Identifier: GPL-3.0-or-later

/// SipHash-2-4 with a 64-bit result and a 128-bit key (Aumasson and
/// Bernstein, «SipHash: a fast short-input PRF», 2012): the keyed
/// fingerprint of the personal lexicon (`PersonalLexicon`).
///
/// The standard library's `Hasher` will not do: it is SipHash-1-3 under a key
/// that changes with every process, so a fingerprint stored on disk would
/// never match again. This one takes the key it is given, runs on the tap
/// thread without allocating and without Foundation, and is tested against
/// the 64 vectors of the reference implementation (`vectors.h`: key
/// `00 01 … 0f`, input `00 01 …` of length 0 to 63).
public struct SipHash24: Sendable {
    private var v0: UInt64
    private var v1: UInt64
    private var v2: UInt64
    private var v3: UInt64
    /// Bytes not yet compressed, little-endian, the first in the low byte.
    private var tail: UInt64 = 0
    /// Bytes taken so far: its low byte goes into the last block.
    private var length: UInt64 = 0

    /// - Parameters:
    ///   - k0: the first eight bytes of the key, little-endian.
    ///   - k1: the last eight.
    public init(k0: UInt64, k1: UInt64) {
        v0 = k0 ^ 0x736F_6D65_7073_6575
        v1 = k1 ^ 0x646F_7261_6E64_6F6D
        v2 = k0 ^ 0x6C79_6765_6E65_7261
        v3 = k1 ^ 0x7465_6462_7974_6573
    }

    public init(key: PersonalKey) {
        self.init(k0: key.k0, k1: key.k1)
    }

    @inline(__always)
    private static func rotate(_ value: UInt64, _ bits: UInt64) -> UInt64 {
        (value << bits) | (value >> (64 - bits))
    }

    @inline(__always)
    private mutating func round() {
        v0 = v0 &+ v1
        v1 = Self.rotate(v1, 13)
        v1 ^= v0
        v0 = Self.rotate(v0, 32)
        v2 = v2 &+ v3
        v3 = Self.rotate(v3, 16)
        v3 ^= v2
        v0 = v0 &+ v3
        v3 = Self.rotate(v3, 21)
        v3 ^= v0
        v2 = v2 &+ v1
        v1 = Self.rotate(v1, 17)
        v1 ^= v2
        v2 = Self.rotate(v2, 32)
    }

    @inline(__always)
    private mutating func compress(_ block: UInt64) {
        v3 ^= block
        round()
        round()
        v0 ^= block
    }

    /// Takes one byte.
    public mutating func append(_ byte: UInt8) {
        let position = length & 7
        tail |= UInt64(byte) << (position * 8)
        length &+= 1
        if position == 7 {
            compress(tail)
            tail = 0
        }
    }

    /// Takes the four bytes of `value`, little-endian.
    public mutating func append(littleEndian value: UInt32) {
        var value = value
        for _ in 0..<4 {
            append(UInt8(truncatingIfNeeded: value))
            value >>= 8
        }
    }

    /// The 64-bit result. Call once, after the last byte.
    public func finalize() -> UInt64 {
        var state = self
        state.compress(tail | (length & 0xFF) << 56)
        state.v2 ^= 0xFF
        state.round()
        state.round()
        state.round()
        state.round()
        return state.v0 ^ state.v1 ^ state.v2 ^ state.v3
    }

    /// The hash of `bytes` under the key.
    public static func hash(k0: UInt64, k1: UInt64, _ bytes: some Sequence<UInt8>) -> UInt64 {
        var hasher = SipHash24(k0: k0, k1: k1)
        for byte in bytes { hasher.append(byte) }
        return hasher.finalize()
    }
}
