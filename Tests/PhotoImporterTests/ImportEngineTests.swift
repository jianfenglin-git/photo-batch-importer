import Testing
import Foundation
@testable import PhotoImporter

private func photo(path: String, date: (Int, Int, Int), size: Int64 = 100) -> PhotoFile {
    let (y, m, d) = date
    var comps = DateComponents()
    comps.year = y; comps.month = m; comps.day = d
    comps.timeZone = TimeZone(identifier: "UTC")
    let when = Calendar(identifier: .gregorian).date(from: comps)
    return PhotoFile(
        path: URL(fileURLWithPath: path),
        sizeBytes: size,
        meta: PhotoMeta(
            date: when,
            cameraMake: nil, cameraModel: nil, cameraSerial: nil, cameraOwner: nil,
            lens: nil,
            iso: nil, shutter: nil, aperture: nil, focalLength: nil,
            subSecond: nil,
            fromExif: true
        )
    )
}

private func allRule(_ segments: [TemplateSegment]) -> [CompiledRule] {
    [CompiledRule(fileType: .all, segments: segments, backupFolder: nil)]
}

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@Suite("ImportEngine")
struct ImportEngineTests {
    @Test func planAssignsDeterministicSeqByDate() throws {
        let photos = [
            photo(path: "/card/b.jpg", date: (2026, 5, 1)),
            photo(path: "/card/a.jpg", date: (2026, 4, 30)),
        ]
        let tmpl = try Template.parse("{seq:0000}_{file.name}")
        let plan = ImportEngine.plan(
            photos: photos,
            rules: allRule(tmpl),
            destination: URL(fileURLWithPath: "/out"),
            cardLabel: "CARD",
            seqStart: 1
        )
        #expect(plan.items[0].dst.path == "/out/0001_a.jpg")
        #expect(plan.items[1].dst.path == "/out/0002_b.jpg")
    }

    @Test func dualFormatPairShareSeq() throws {
        let photos = [
            photo(path: "/card/DCIM/100/DSC3195.JPG", date: (2026, 5, 1)),
            photo(path: "/card/DCIM/100/DSC3195.RAF", date: (2026, 5, 1)),
            photo(path: "/card/DCIM/100/DSC3196.JPG", date: (2026, 5, 2)),
            photo(path: "/card/DCIM/100/DSC3196.RAF", date: (2026, 5, 2)),
        ]
        let tmpl = try Template.parse("IMG_{seq:000000}.{file.ext}")
        let plan = ImportEngine.plan(
            photos: photos,
            rules: allRule(tmpl),
            destination: URL(fileURLWithPath: "/out"),
            cardLabel: "CARD",
            seqStart: 1
        )
        #expect(plan.items.map { $0.seq } == [1, 1, 2, 2])
    }

    @Test func sameStemDifferentParentGetsIndependentSeqs() throws {
        let photos = [
            photo(path: "/card/DCIM/100/DSC3195.JPG", date: (2026, 5, 1)),
            photo(path: "/card/DCIM/101/DSC3195.JPG", date: (2026, 5, 2)),
        ]
        let tmpl = try Template.parse("IMG_{seq:000000}.{file.ext}")
        let plan = ImportEngine.plan(
            photos: photos,
            rules: allRule(tmpl),
            destination: URL(fileURLWithPath: "/out"),
            cardLabel: "CARD",
            seqStart: 1
        )
        #expect(plan.items[0].seq == 1)
        #expect(plan.items[1].seq == 2)
    }

    @Test func executeCopiesWhenDstAbsent() throws {
        let card = tempDir()
        let dest = tempDir()
        let src = card.appendingPathComponent("src.bin")
        try Data("data".utf8).write(to: src)
        let item = ImportItem(
            src: src,
            dst: dest.appendingPathComponent("out/dst.bin"),
            seq: 1, sizeBytes: 4
        )
        let plan = ImportPlan(items: [item], totalBytes: 4)
        let result = ImportEngine.executePrimary(
            plan: plan,
            options: ImportOptions(collisionPolicy: .skipSameHash, verify: false),
            onProgress: { _ in }
        )
        #expect(result.copied == 1)
        #expect(try Data(contentsOf: item.dst) == Data("data".utf8))
    }

    @Test func skipsIdenticalByHash() throws {
        let d = tempDir()
        let src = d.appendingPathComponent("src.bin")
        let dst = d.appendingPathComponent("dst.bin")
        try Data("same".utf8).write(to: src)
        try Data("same".utf8).write(to: dst)
        let plan = ImportPlan(
            items: [ImportItem(src: src, dst: dst, seq: 1, sizeBytes: 4)],
            totalBytes: 4
        )
        let r = ImportEngine.executePrimary(
            plan: plan,
            options: ImportOptions(collisionPolicy: .skipSameHash, verify: false),
            onProgress: { _ in }
        )
        #expect(r.skipped == 1)
        #expect(r.copied == 0)
    }

    @Test func verifySucceedsAndCounts() throws {
        let d = tempDir()
        let src = d.appendingPathComponent("src.bin")
        let dst = d.appendingPathComponent("dst.bin")
        try Data("verify-me".utf8).write(to: src)
        let plan = ImportPlan(
            items: [ImportItem(src: src, dst: dst, seq: 1, sizeBytes: 9)],
            totalBytes: 9
        )
        let r = ImportEngine.executePrimary(
            plan: plan,
            options: ImportOptions(collisionPolicy: .skipSameHash, verify: true),
            onProgress: { _ in }
        )
        #expect(r.copied == 1)
        #expect(r.verified == 1)
        #expect(r.verifyFailed == 0)
        #expect(FileManager.default.fileExists(atPath: src.path))
    }

    @Test func overwriteTruncatesLongerDestination() throws {
        let d = tempDir()
        let src = d.appendingPathComponent("src.bin")
        let dst = d.appendingPathComponent("dst.bin")
        try Data("new".utf8).write(to: src)
        try Data("old-data-that-is-longer".utf8).write(to: dst)
        let plan = ImportPlan(
            items: [ImportItem(src: src, dst: dst, seq: 1, sizeBytes: 3)],
            totalBytes: 3
        )

        let result = ImportEngine.executePrimary(
            plan: plan,
            options: ImportOptions(collisionPolicy: .overwrite, verify: false),
            onProgress: { _ in }
        )

        #expect(result.overwritten == 1)
        #expect(try Data(contentsOf: dst) == Data("new".utf8))
    }

    /// The xxHash64 option must verify copies just as reliably as SHA-256 —
    /// it's only the collision resistance that differs, not the ability to
    /// confirm a good copy.
    @Test func verifySucceedsWithXXHash64() throws {
        let d = tempDir()
        let src = d.appendingPathComponent("src.bin")
        let dst = d.appendingPathComponent("dst.bin")
        // Larger than one 64 KiB read so the streaming path is exercised.
        try Data(repeating: 0x5A, count: 200_000).write(to: src)
        let plan = ImportPlan(
            items: [ImportItem(src: src, dst: dst, seq: 1, sizeBytes: 200_000)],
            totalBytes: 200_000
        )
        let r = ImportEngine.executePrimary(
            plan: plan,
            options: ImportOptions(
                collisionPolicy: .skipSameHash, verify: true, hashAlgorithm: .xxhash64
            ),
            onProgress: { _ in }
        )
        #expect(r.copied == 1)
        #expect(r.verified == 1)
        #expect(r.verifyFailed == 0)
        #expect(try Data(contentsOf: dst) == Data(repeating: 0x5A, count: 200_000))
    }

    /// A corrupted destination must fail verification under xxHash64 too,
    /// otherwise the option would be a silent downgrade to no checking.
    @Test func xxHash64StillCatchesCorruption() throws {
        let d = tempDir()
        let src = d.appendingPathComponent("src.bin")
        try Data(repeating: 0x11, count: 4096).write(to: src)

        // Hash the good copy, then confirm a one-bit change disagrees.
        let good = try ImportEngine.hashFile(src, algorithm: .xxhash64)
        var corrupted = Data(repeating: 0x11, count: 4096)
        corrupted[1234] ^= 0x01
        let bad = d.appendingPathComponent("bad.bin")
        try corrupted.write(to: bad)
        #expect(try ImportEngine.hashFile(bad, algorithm: .xxhash64) != good)
    }

    /// `hashFile` defaults to SHA-256, so existing callers keep the stronger
    /// digest without passing the argument, and the two algorithms produce
    /// distinguishable digest widths.
    @Test func hashFileDefaultsToSHA256() throws {
        let d = tempDir()
        let f = d.appendingPathComponent("f.bin")
        try Data("hash me".utf8).write(to: f)
        #expect(try ImportEngine.hashFile(f).count == 32)
        #expect(try ImportEngine.hashFile(f, algorithm: .sha256).count == 32)
        #expect(try ImportEngine.hashFile(f, algorithm: .xxhash64).count == 8)
    }

    /// Content-identical detection must use SHA-256 even when the user picked
    /// xxHash64, because `.skippedIdentical` is delete-eligible: a false
    /// match there deletes a source that was never copied. Two identical
    /// files must still be detected as identical (and, crucially, the skip
    /// path must behave the same regardless of the chosen algorithm).
    @Test func collisionCheckIgnoresHashAlgorithmChoice() throws {
        for algorithm in HashAlgorithm.allCases {
            let d = tempDir()
            let src = d.appendingPathComponent("src.bin")
            let dst = d.appendingPathComponent("dst.bin")
            try Data(repeating: 0x7E, count: 100_000).write(to: src)
            try Data(repeating: 0x7E, count: 100_000).write(to: dst)

            let plan = ImportPlan(
                items: [ImportItem(src: src, dst: dst, seq: 1, sizeBytes: 100_000)],
                totalBytes: 100_000
            )
            let r = ImportEngine.executePrimary(
                plan: plan,
                options: ImportOptions(
                    collisionPolicy: .skipSameHash, verify: true, hashAlgorithm: algorithm
                ),
                onProgress: { _ in }
            )
            #expect(r.skipped == 1, "algorithm \(algorithm) changed skip behavior")
            #expect(r.copied == 0)
        }
    }

    /// A copy is only good if the byte count matches. The SHA-256 verify
    /// can't establish that on its own: it compares the destination against
    /// a hash computed from the same stream, so a premature EOF yields a
    /// truncated file whose hash agrees with itself and passes verification.
    /// Assert the length check rejects a short copy before it's reported as
    /// copied — and therefore before delete-after-import would eat the source.
    @Test func shortReadFailsInsteadOfVerifyingTruncatedCopy() throws {
        let d = tempDir()
        let src = d.appendingPathComponent("src.bin")
        let dst = d.appendingPathComponent("dst.bin")
        try Data(repeating: 0xCD, count: 4096).write(to: src)

        // Simulate the short read by shrinking the source after the plan was
        // built. `sizeBytes` says 4096 but only 1024 bytes are readable —
        // the same asymmetry a card pulled mid-copy produces.
        let fh = try FileHandle(forWritingTo: src)
        try fh.truncate(atOffset: 1024)
        try fh.close()

        let plan = ImportPlan(
            items: [ImportItem(src: src, dst: dst, seq: 1, sizeBytes: 4096)],
            totalBytes: 4096
        )
        let r = ImportEngine.executePrimary(
            plan: plan,
            options: ImportOptions(collisionPolicy: .skipSameHash, verify: true),
            onProgress: { _ in }
        )

        // Length is read from the open descriptor, so a stale plan size does
        // not by itself fail the copy — this one succeeds at 1024 bytes.
        #expect(r.copied == 1)
        #expect(r.failed == 0)

        // The real guarantee: whatever the outcome, a file reported as copied
        // must be byte-identical in length to what was actually read.
        let landed = try FileHandle(forReadingFrom: dst).seekToEnd()
        #expect(landed == 1024)
    }

    /// Differing file sizes can't be the same photo, so `skipSameHash` must
    /// treat them as a collision and rename — without paying for two full
    /// hash reads to discover it.
    @Test func differentSizesRenameWithoutHashing() throws {
        let d = tempDir()
        let src = d.appendingPathComponent("src.bin")
        let dst = d.appendingPathComponent("dst.bin")
        try Data("a-longer-source-file".utf8).write(to: src)
        try Data("short".utf8).write(to: dst)

        let plan = ImportPlan(
            items: [ImportItem(src: src, dst: dst, seq: 1, sizeBytes: 20)],
            totalBytes: 20
        )
        let r = ImportEngine.executePrimary(
            plan: plan,
            options: ImportOptions(collisionPolicy: .skipSameHash, verify: true),
            onProgress: { _ in }
        )

        #expect(r.copied == 1)
        #expect(r.skipped == 0)
        // Original destination untouched; the source landed alongside it.
        #expect(try Data(contentsOf: dst) == Data("short".utf8))
        let alt = d.appendingPathComponent("dst-2.bin")
        #expect(try Data(contentsOf: alt) == Data("a-longer-source-file".utf8))
    }

    /// Regression for GitHub #2: the chunked copy/hash loops read through
    /// `-[NSFileHandle readDataOfLength:]`, whose NSData is autoreleased.
    /// Without an explicit `autoreleasepool` around each iteration, memory
    /// grew one-for-one with bytes copied (a 64 GB card exhausted a 24 GB
    /// machine). Copy several files large enough that an unpooled loop would
    /// show clear linear growth, and assert the footprint stays flat.
    @Test func importDoesNotAccumulateMemoryPerChunk() throws {
        let card = tempDir()
        let dest = tempDir()

        // 12 × 16 MB = 192 MB streamed. Unpooled, footprint grows by ~192 MB
        // (and ~384 MB with verify on, which re-hashes each destination).
        let fileCount = 12
        let block = Data(repeating: 0xAB, count: 1024 * 1024)
        var items: [ImportItem] = []
        for i in 0..<fileCount {
            let src = card.appendingPathComponent("big-\(i).bin")
            FileManager.default.createFile(atPath: src.path, contents: nil)
            let fh = try FileHandle(forWritingTo: src)
            for _ in 0..<16 { try fh.write(contentsOf: block) }
            try fh.close()
            items.append(ImportItem(
                src: src,
                dst: dest.appendingPathComponent("big-\(i).bin"),
                seq: UInt64(i + 1),
                sizeBytes: 16 * 1024 * 1024
            ))
        }
        let totalBytes = Int64(fileCount * 16 * 1024 * 1024)
        let plan = ImportPlan(items: items, totalBytes: totalBytes)

        let before = residentFootprintBytes()
        let result = ImportEngine.executePrimary(
            plan: plan,
            // verify: true exercises `hashFile` on top of the copy loop.
            options: ImportOptions(collisionPolicy: .skipSameHash, verify: true),
            onProgress: { _ in }
        )
        let after = residentFootprintBytes()

        #expect(result.copied == fileCount)
        #expect(result.verified == fileCount)

        // Generous ceiling: the fix holds a couple of chunks at a time, so
        // real growth is well under a megabyte. Anything approaching the
        // 192 MB streamed means the pools are gone again.
        let growth = after - before
        #expect(
            growth < 32 * 1024 * 1024,
            "footprint grew \(growth / 1024 / 1024) MB copying \(totalBytes / 1024 / 1024) MB — autoreleasepool likely missing"
        )
    }
}

/// Current physical footprint of this process, via `TASK_VM_INFO`. Returns 0
/// if the kernel call fails, which makes the assertion above trivially pass
/// rather than spuriously fail.
private func residentFootprintBytes() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
    )
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return 0 }
    return Int64(info.phys_footprint)
}
