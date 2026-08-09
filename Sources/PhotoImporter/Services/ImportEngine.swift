import Foundation
import CryptoKit

/// A pre-parsed template rule. Empty `segments` marks the row inactive
/// (either the user left the template blank or parsing failed).
struct CompiledRule {
    var fileType: FileType
    var segments: [TemplateSegment]
    var backupFolder: URL?
}

/// Plan + execute an import in two independent phases (primary then backup).
/// Each phase reads from the SD card separately so the user can start using
/// the primary copies while the slower backup copy is in progress.
enum ImportEngine {
    /// Read/write granularity for the streaming copy and hash loops.
    private static let chunkSize = 64 * 1024

    /// Build an execution plan: filter every photo against the rule list
    /// top-to-bottom (first match wins; no match = excluded), then sort by
    /// date, detect dual-format pairs, and assign seq numbers. Excluded
    /// photos don't consume a seq number.
    static func plan(
        photos: [PhotoFile],
        rules: [CompiledRule],
        destination: URL,
        cardLabel: String,
        seqStart: UInt64
    ) -> ImportPlan {
        let paired: [(PhotoFile, CompiledRule)] = photos.compactMap { photo in
            let ext = photo.path.pathExtension
            guard let rule = rules.first(where: { !$0.segments.isEmpty && $0.fileType.matches(extension: ext) })
            else { return nil }
            return (photo, rule)
        }

        let sorted = paired.sorted { a, b in
            let ad = a.0.meta.date ?? .distantPast
            let bd = b.0.meta.date ?? .distantPast
            if ad != bd { return ad < bd }
            return a.0.path.path < b.0.path.path
        }

        var seqs: [UInt64] = []
        seqs.reserveCapacity(sorted.count)
        var nextSeq = seqStart
        var prevKey: String? = nil
        for (photo, _) in sorted {
            let parent = photo.path.deletingLastPathComponent().path
            let stem = photo.path.deletingPathExtension().lastPathComponent.lowercased()
            let key = parent + "\u{1F}" + stem
            if prevKey == key {
                seqs.append(seqs.last!)
            } else {
                seqs.append(nextSeq)
                nextSeq += 1
            }
            prevKey = key
        }

        var items: [ImportItem] = []
        items.reserveCapacity(sorted.count)
        var totalBytes: Int64 = 0
        for (i, (photo, rule)) in sorted.enumerated() {
            let seq = seqs[i]
            let rel = Template.evaluate(rule.segments, photo: photo, seq: seq, cardLabel: cardLabel)
            let dst = destination.appendingPathComponent(rel)
            let backup = rule.backupFolder?.appendingPathComponent(rel)
            totalBytes &+= photo.sizeBytes
            items.append(ImportItem(
                src: photo.path,
                dst: dst,
                seq: seq,
                sizeBytes: photo.sizeBytes,
                backupDst: backup
            ))
        }
        return ImportPlan(items: items, totalBytes: totalBytes)
    }

    /// Phase 1: source → primary. One pass over all items.
    static func executePrimary(
        plan: ImportPlan,
        options: ImportOptions,
        onProgress: (ImportProgress) -> Void
    ) -> ImportResult {
        executePhase(plan: plan, phase: .primary, options: options, onProgress: onProgress)
    }

    /// Phase 2: source → backup, for the subset of items that have a
    /// backup destination. Re-reads the source — NOT the primary — so the
    /// user can start editing primary files while phase 2 is still running.
    /// Returns nil if no items have a backup destination.
    static func executeBackup(
        plan: ImportPlan,
        options: ImportOptions,
        onProgress: (ImportProgress) -> Void
    ) -> ImportResult? {
        // Rewrite each backup-eligible item so `dst` points at the backup
        // destination for the shared per-item executor; `backupDst` cleared
        // to keep the executor single-target. One compactMap pass rather
        // than filter-then-map so only a single array is materialised.
        let mapped: [ImportItem] = plan.items.compactMap { item in
            guard let backupDst = item.backupDst else { return nil }
            return ImportItem(
                src: item.src,
                dst: backupDst,
                seq: item.seq,
                sizeBytes: item.sizeBytes,
                backupDst: nil
            )
        }
        guard !mapped.isEmpty else { return nil }
        let totalBytes = mapped.reduce(Int64(0)) { $0 &+ $1.sizeBytes }
        let phasePlan = ImportPlan(items: mapped, totalBytes: totalBytes)
        return executePhase(plan: phasePlan, phase: .backup, options: options, onProgress: onProgress)
    }

    // MARK: - Shared per-item executor

    private static func executePhase(
        plan: ImportPlan,
        phase: ImportPhase,
        options: ImportOptions,
        onProgress: (ImportProgress) -> Void
    ) -> ImportResult {
        var result = ImportResult()
        let totalItems = plan.items.count
        var bytesDone: Int64 = 0
        for (i, item) in plan.items.enumerated() {
            // Per-item pool as defense in depth: catches autoreleased objects
            // from path manipulation and FileManager calls, which would
            // otherwise also accumulate across the whole phase.
            let step = autoreleasepool { executeItem(item, options: options) }
            switch step.outcome {
            case .copied, .copiedAs:
                result.copied += 1
            case .skippedIdentical, .skippedExisting:
                result.skipped += 1
            case .overwritten:
                result.overwritten += 1
            case .verifyFailed:
                result.verifyFailed += 1
                result.failed += 1
                result.failures.append((item.src, "verify hash mismatch"))
            case .failed(let msg):
                result.failed += 1
                result.failures.append((item.src, msg))
            }
            if step.verified {
                result.verified += 1
            }
            bytesDone &+= item.sizeBytes
            onProgress(ImportProgress(
                phase: phase,
                itemIndex: i,
                totalItems: totalItems,
                bytesDone: bytesDone,
                bytesTotal: plan.totalBytes,
                currentSrc: item.src,
                currentDst: item.dst,
                outcome: step.outcome
            ))
        }
        return result
    }

    private struct Step {
        var outcome: ImportOutcome
        var verified: Bool
    }

    private static func executeItem(_ item: ImportItem, options: ImportOptions) -> Step {
        let fm = FileManager.default
        guard fm.fileExists(atPath: item.src.path) else {
            return Step(outcome: .failed("source not found"), verified: false)
        }
        let parent = item.dst.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            return Step(outcome: .failed("create parent: \(error.localizedDescription)"), verified: false)
        }

        if !fm.fileExists(atPath: item.dst.path) {
            return copyAndMaybeVerify(src: item.src, dst: item.dst, options: options, onSuccess: .copied)
        }
        switch options.collisionPolicy {
        case .overwrite:
            return copyAndMaybeVerify(src: item.src, dst: item.dst, options: options, onSuccess: .overwritten)
        case .skipAll:
            return Step(outcome: .skippedExisting, verified: false)
        case .renameIfDifferent:
            let alt = nextAvailable(item.dst)
            return copyAndMaybeVerify(src: item.src, dst: alt, options: options, onSuccess: .copiedAs(alt))
        case .skipSameHash:
            // Cheap size gate before two full reads. Different lengths can't
            // be the same file, so this skips ~2x I/O in the common
            // "different photo, same name" case. When either size is
            // unreadable, fall through and let the hashes decide.
            if let srcSize = fileSize(item.src),
               let dstSize = fileSize(item.dst),
               srcSize != dstSize {
                let alt = nextAvailable(item.dst)
                return copyAndMaybeVerify(src: item.src, dst: alt, options: options, onSuccess: .copiedAs(alt))
            }
            // Deliberately SHA-256 regardless of the user's choice. A false
            // "identical" verdict here is destructive: `.skippedIdentical` is
            // delete-eligible, so with delete-after-import a 64-bit collision
            // would erase a photo that was never copied. The speed setting
            // applies to the verify pass, which only ever compares a file
            // against bytes we just wrote, and where a mismatch merely
            // reports a failure.
            guard let srcHash = try? hashFile(item.src, algorithm: .sha256) else {
                return Step(outcome: .failed("hash src"), verified: false)
            }
            guard let dstHash = try? hashFile(item.dst, algorithm: .sha256) else {
                return Step(outcome: .failed("hash dst"), verified: false)
            }
            if srcHash == dstHash {
                return Step(outcome: .skippedIdentical, verified: false)
            }
            let alt = nextAvailable(item.dst)
            return copyAndMaybeVerify(src: item.src, dst: alt, options: options, onSuccess: .copiedAs(alt))
        }
    }

    /// Stream src → dst with a running hash, then verify the destination
    /// against that hash if `options.verify` is set.
    private static func copyAndMaybeVerify(
        src: URL,
        dst: URL,
        options: ImportOptions,
        onSuccess: ImportOutcome
    ) -> Step {
        let srcHash: Data
        do {
            srcHash = try streamingCopyAndHash(
                src: src, dst: dst, algorithm: options.hashAlgorithm
            )
        } catch {
            return Step(outcome: .failed("copy: \(error.localizedDescription)"), verified: false)
        }
        if !options.verify {
            return Step(outcome: onSuccess, verified: false)
        }
        guard let dstHash = try? hashFile(dst, algorithm: options.hashAlgorithm) else {
            return Step(outcome: .failed("verify read"), verified: false)
        }
        if dstHash == srcHash {
            return Step(outcome: onSuccess, verified: true)
        }
        return Step(outcome: .verifyFailed, verified: false)
    }

    /// Byte length of a file, or nil if it can't be read. Callers treat nil
    /// as "unknown" and fall back to hashing rather than assuming a mismatch.
    private static func fileSize(_ url: URL) -> UInt64? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return nil
        }
        return UInt64(size)
    }

    /// Generate a sibling path that doesn't exist yet: `foo.jpg` →
    /// `foo-2.jpg`, `foo-3.jpg`, etc. Caps after 9999 attempts.
    private static func nextAvailable(_ dst: URL) -> URL {
        let stem = dst.deletingPathExtension().lastPathComponent
        let ext = dst.pathExtension
        let parent = dst.deletingLastPathComponent()
        let fm = FileManager.default
        for n in 2...9999 {
            let name = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            let candidate = parent.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return parent.appendingPathComponent(ext.isEmpty ? "\(stem)-9999" : "\(stem)-9999.\(ext)")
    }

    /// Stream bytes src → dst while updating a SHA-256 hasher in a single
    /// pass. Returns the hash of the source content that was written;
    /// `hashFile(dst)` run afterwards gives a true end-to-end integrity
    /// check when verify is enabled.
    ///
    /// Also asserts the byte count matches the source length. That check is
    /// NOT redundant with the hash: a premature EOF (card pulled mid-copy,
    /// failing reader) surfaces as a clean end-of-file, so the truncated
    /// content is what gets hashed *and* written, and the verify comparison
    /// happily agrees with itself. Only length can catch a short read — and
    /// it must live here, because with verify off nothing else looks at all.
    private static func streamingCopyAndHash(
        src: URL,
        dst: URL,
        algorithm: HashAlgorithm
    ) throws -> Data {
        let fm = FileManager.default
        let reader = try FileHandle(forReadingFrom: src)
        defer { try? reader.close() }
        // Length of exactly the file we're about to read, from the same
        // descriptor rather than a separate stat, so nothing can swap the
        // file out in between. Not `item.sizeBytes` — that was measured at
        // scan time and may be stale.
        let expectedBytes = try reader.seekToEnd()
        try reader.seek(toOffset: 0)
        if !fm.fileExists(atPath: dst.path) {
            guard fm.createFile(atPath: dst.path, contents: nil) else {
                throw NSError(
                    domain: "PhotoImporter.copy",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "could not create destination file"]
                )
            }
        }
        let writer = try FileHandle(forWritingTo: dst)
        defer { try? writer.close() }
        // FileHandle writes from offset zero but does not discard old trailing
        // bytes. Without truncation, overwriting a large file with a smaller
        // photo produces a corrupt destination whenever Verify is disabled.
        try writer.truncate(atOffset: 0)

        var sha = SHA256()
        var xx = XXHash64()
        var written: UInt64 = 0
        while true {
            // `read(upToCount:)` bridges -[NSFileHandle readDataOfLength:],
            // whose NSData is autoreleased. The whole phase runs as one
            // Swift concurrency job with no suspension point, so without an
            // explicit pool every chunk of every file would be held until
            // the import finished — one byte of RAM per byte copied.
            let count: Int = try autoreleasepool {
                let chunk = try reader.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { return 0 }
                switch algorithm {
                case .sha256: sha.update(data: chunk)
                case .xxhash64: xx.update(data: chunk)
                }
                try writer.write(contentsOf: chunk)
                return chunk.count
            }
            if count == 0 { break }
            written &+= UInt64(count)
        }
        try writer.synchronize()

        // Short read: we streamed fewer bytes than the source holds. See the
        // note above — the hash cannot detect this, so fail loudly instead of
        // reporting a truncated file as a good copy.
        guard written == expectedBytes else {
            throw NSError(
                domain: "PhotoImporter.copy",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "short read: copied \(written) of \(expectedBytes) bytes"]
            )
        }

        // Belt and braces: confirm the bytes actually landed on disk at the
        // expected length, rather than trusting that every write returned
        // without error. Catches a full disk or a quota cut-off that only
        // shows up at close time.
        let landed = (try? fm.attributesOfItem(atPath: dst.path)[.size] as? Int).flatMap { $0 }
        if let landed, UInt64(landed) != expectedBytes {
            throw NSError(
                domain: "PhotoImporter.copy",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey:
                    "destination is \(landed) bytes, expected \(expectedBytes)"]
            )
        }
        switch algorithm {
        case .sha256: return Data(sha.finalize())
        case .xxhash64: return xx.finalizeData()
        }
    }

    static func hashFile(_ url: URL, algorithm: HashAlgorithm = .sha256) throws -> Data {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        switch algorithm {
        case .sha256:
            var hasher = SHA256()
            try streamChunks(reader) { hasher.update(data: $0) }
            return Data(hasher.finalize())
        case .xxhash64:
            var hasher = XXHash64()
            try streamChunks(reader) { hasher.update(data: $0) }
            return hasher.finalizeData()
        }
    }

    /// Feed a file to `sink` in `chunkSize` pieces.
    ///
    /// Each iteration runs inside an `autoreleasepool` for the reason spelled
    /// out in `streamingCopyAndHash`: `read(upToCount:)` returns autoreleased
    /// NSData and this phase has no suspension point, so without the pool
    /// memory grows one-for-one with bytes read (GitHub #2).
    private static func streamChunks(
        _ reader: FileHandle,
        _ sink: (Data) -> Void
    ) throws {
        while true {
            let done: Bool = try autoreleasepool {
                let chunk = try reader.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { return true }
                sink(chunk)
                return false
            }
            if done { break }
        }
    }
}
