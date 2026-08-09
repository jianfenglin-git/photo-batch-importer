import Foundation

/// Streaming xxHash64 (Yann Collet's XXH64, the original — not XXH3).
///
/// Offered alongside SHA-256 as the integrity-check algorithm for the
/// post-copy verify pass. It is NOT cryptographic: collisions are cheap to
/// construct deliberately. That's acceptable here because verify only ever
/// compares a file against a hash of the bytes we just wrote ourselves —
/// there's no adversary in that loop, only random corruption to detect, and
/// 64 bits of it. See `HashAlgorithm` for where this choice is safe and where
/// SHA-256 is required.
///
/// Interface mirrors CryptoKit's hashers (`update(data:)` / `finalize()`) so
/// both can sit behind one enum. Verified against the reference test vectors
/// in `XXHash64Tests`.
struct XXHash64 {
    private static let prime1: UInt64 = 0x9E3779B185EBCA87
    private static let prime2: UInt64 = 0xC2B2AE3D27D4EB4F
    private static let prime3: UInt64 = 0x165667B19E3779F9
    private static let prime4: UInt64 = 0x85EBCA77C2B2AE63
    private static let prime5: UInt64 = 0x27D4EB2F165667C5

    private var v1: UInt64
    private var v2: UInt64
    private var v3: UInt64
    private var v4: UInt64

    /// Bytes not yet folded into the state: xxHash64 consumes 32-byte
    /// stripes, so a chunk boundary mid-stripe has to be carried over.
    private var buffer: [UInt8] = []
    private var totalLength: UInt64 = 0

    init(seed: UInt64 = 0) {
        v1 = seed &+ Self.prime1 &+ Self.prime2
        v2 = seed &+ Self.prime2
        v3 = seed
        v4 = seed &- Self.prime1
        buffer.reserveCapacity(32)
    }

    private static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 {
        (x << r) | (x >> (64 - r))
    }

    private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        var acc = acc &+ (input &* prime2)
        acc = rotl(acc, 31)
        return acc &* prime1
    }

    private static func mergeRound(_ acc: UInt64, _ val: UInt64) -> UInt64 {
        let v = round(0, val)
        var acc = acc ^ v
        acc = acc &* prime1
        return acc &+ prime4
    }

    /// Little-endian 64-bit load. Byte-by-byte rather than a reinterpreting
    /// load so it's alignment-safe on any offset into the buffer.
    private static func load64(_ b: UnsafePointer<UInt8>) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 {
            v |= UInt64(b[i]) << UInt64(8 * i)
        }
        return v
    }

    private static func load32(_ b: UnsafePointer<UInt8>) -> UInt64 {
        var v: UInt32 = 0
        for i in 0..<4 {
            v |= UInt32(b[i]) << UInt32(8 * i)
        }
        return UInt64(v)
    }

    mutating func update(data: Data) {
        guard !data.isEmpty else { return }
        totalLength &+= UInt64(data.count)

        // Fast path: nothing buffered and the chunk covers whole stripes.
        // Avoids copying the (large) chunk into `buffer` on every call.
        if buffer.isEmpty {
            let consumed = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                var offset = 0
                while raw.count - offset >= 32 {
                    let p = base + offset
                    v1 = Self.round(v1, Self.load64(p))
                    v2 = Self.round(v2, Self.load64(p + 8))
                    v3 = Self.round(v3, Self.load64(p + 16))
                    v4 = Self.round(v4, Self.load64(p + 24))
                    offset += 32
                }
                return offset
            }
            if consumed < data.count {
                buffer.append(contentsOf: data[(data.startIndex + consumed)...])
            }
            return
        }

        // Slow path: top up the carried remainder, then drain full stripes.
        buffer.append(contentsOf: data)
        guard buffer.count >= 32 else { return }
        var offset = 0
        buffer.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            while buf.count - offset >= 32 {
                let p = base + offset
                v1 = Self.round(v1, Self.load64(p))
                v2 = Self.round(v2, Self.load64(p + 8))
                v3 = Self.round(v3, Self.load64(p + 16))
                v4 = Self.round(v4, Self.load64(p + 24))
                offset += 32
            }
        }
        buffer.removeFirst(offset)
    }

    func finalize() -> UInt64 {
        var acc: UInt64
        if totalLength >= 32 {
            acc = Self.rotl(v1, 1) &+ Self.rotl(v2, 7)
                &+ Self.rotl(v3, 12) &+ Self.rotl(v4, 18)
            acc = Self.mergeRound(acc, v1)
            acc = Self.mergeRound(acc, v2)
            acc = Self.mergeRound(acc, v3)
            acc = Self.mergeRound(acc, v4)
        } else {
            // Inputs shorter than one stripe never touched the accumulators.
            acc = v3 &+ Self.prime5
        }
        acc = acc &+ totalLength

        // Consume the tail: 8-byte, then 4-byte, then single bytes.
        buffer.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var i = 0
            while buf.count - i >= 8 {
                let k1 = Self.round(0, Self.load64(base + i))
                acc ^= k1
                acc = Self.rotl(acc, 27) &* Self.prime1
                acc = acc &+ Self.prime4
                i += 8
            }
            if buf.count - i >= 4 {
                acc ^= Self.load32(base + i) &* Self.prime1
                acc = Self.rotl(acc, 23) &* Self.prime2
                acc = acc &+ Self.prime3
                i += 4
            }
            while i < buf.count {
                acc ^= UInt64(base[i]) &* Self.prime5
                acc = Self.rotl(acc, 11) &* Self.prime1
                i += 1
            }
        }

        // Final avalanche.
        acc ^= acc >> 33
        acc = acc &* Self.prime2
        acc ^= acc >> 29
        acc = acc &* Self.prime3
        acc ^= acc >> 32
        return acc
    }

    /// Big-endian bytes, so the digest is comparable as `Data` alongside
    /// SHA-256's and renders in the conventional hex order.
    func finalizeData() -> Data {
        var v = finalize().bigEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }
}
