import Testing
import Foundation
@testable import PhotoImporter

/// Reference vectors for XXH64 with seed 0, generated from the canonical
/// implementation (python `xxhash` 3.8.1, which wraps Yann Collet's C
/// library). Inputs are `byte[i] = (i * 7 + 13) % 256`.
///
/// These pin the digest to the published algorithm. A "faster" hash that
/// silently disagrees with the spec would still verify copies self-
/// consistently, so nothing else in the suite would catch a subtle break in
/// the round/merge constants or the tail handling.
private let vectors: [(n: Int, hex: String)] = [
    (0, "ef46db3751d8e999"),
    (1, "2078e1ad38ad738b"),
    (3, "bdef762e8804c53e"),
    (4, "6bb99866cb63c0a8"),
    (7, "31365618ad874893"),
    (8, "3ba000679fbee7b5"),
    (15, "a3666d452d79e70d"),
    (16, "201bd74388e1fae2"),
    (31, "7231380363bb4388"),
    (32, "56699a69da28fd3b"),
    (33, "d477447593124012"),
    (64, "bad331060e4cd79a"),
    (127, "b631cccc2915aa19"),
    (128, "d8ee6fe6fef67e1c"),
    (1024, "cf2bf9d171c048b2"),
]

private func input(_ n: Int) -> Data {
    Data((0..<n).map { UInt8((($0 * 7) + 13) % 256) })
}

private func hex(_ d: Data) -> String {
    d.map { String(format: "%02x", $0) }.joined()
}

@Suite("XXHash64")
struct XXHash64Tests {
    /// Empty input has a well-known digest; worth its own case since it's the
    /// one path that never touches the accumulators or the tail loop.
    @Test func emptyInputMatchesReference() {
        var h = XXHash64()
        h.update(data: Data())
        #expect(hex(h.finalizeData()) == "ef46db3751d8e999")
    }

    /// Feeding the same bytes in different chunk sizes must not change the
    /// digest. This is the property `ImportEngine` depends on: it hashes the
    /// source in 64 KiB reads during the copy and re-reads the destination
    /// separately, so any dependence on chunk boundaries would make every
    /// verify fail (or, worse, pass by coincidence).
    @Test func chunkingDoesNotAffectDigest() {
        // 200 000 bytes spans several 64 KiB chunks and ends mid-stripe.
        let data = input(200_000)

        var oneShot = XXHash64()
        oneShot.update(data: data)
        let expected = hex(oneShot.finalizeData())

        for chunk in [1, 7, 8, 31, 32, 33, 1024, 65_536] {
            var h = XXHash64()
            var offset = 0
            while offset < data.count {
                let end = min(offset + chunk, data.count)
                h.update(data: data.subdata(in: offset..<end))
                offset = end
            }
            #expect(
                hex(h.finalizeData()) == expected,
                "digest changed when fed in \(chunk)-byte chunks"
            )
        }
    }

    /// A single flipped bit must change the digest — the whole point of using
    /// it to detect corruption.
    @Test func detectsSingleBitFlip() {
        var a = XXHash64()
        a.update(data: input(4096))

        var corrupted = input(4096)
        corrupted[2000] ^= 0x01
        var b = XXHash64()
        b.update(data: corrupted)

        #expect(hex(a.finalizeData()) != hex(b.finalizeData()))
    }

    /// Digest bytes are big-endian, so hex renders in the conventional order
    /// and `Data` comparison against a stored digest is stable.
    @Test func digestIsBigEndianEightBytes() {
        var h = XXHash64()
        h.update(data: Data())
        let d = h.finalizeData()
        #expect(d.count == 8)
        #expect(d.first == 0xef)
        #expect(d.last == 0x99)
    }

    @Test func matchesReferenceVectors() {
        for v in vectors {
            var h = XXHash64()
            h.update(data: input(v.n))
            #expect(
                hex(h.finalizeData()) == v.hex,
                "n=\(v.n): got \(hex(h.finalizeData())), reference says \(v.hex)"
            )
        }
    }
}
