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
        let backupItems = plan.items.filter { $0.backupDst != nil }
        guard !backupItems.isEmpty else { return nil }
        // Rewrite each item so `dst` points at the backup destination for
        // the shared per-item executor. `backupDst` cleared to keep the
        // executor single-target.
        let mapped = backupItems.map { item in
            ImportItem(
                src: item.src,
                dst: item.backupDst!,
                seq: item.seq,
                sizeBytes: item.sizeBytes,
                backupDst: nil
            )
        }
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
            let step = executeItem(item, options: options)
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
            guard let srcHash = try? hashFile(item.src) else {
                return Step(outcome: .failed("hash src"), verified: false)
            }
            guard let dstHash = try? hashFile(item.dst) else {
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
            srcHash = try streamingCopyAndHash(src: src, dst: dst)
        } catch {
            return Step(outcome: .failed("copy: \(error.localizedDescription)"), verified: false)
        }
        if !options.verify {
            return Step(outcome: onSuccess, verified: false)
        }
        guard let dstHash = try? hashFile(dst) else {
            return Step(outcome: .failed("verify read"), verified: false)
        }
        if dstHash == srcHash {
            return Step(outcome: onSuccess, verified: true)
        }
        return Step(outcome: .verifyFailed, verified: false)
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
    private static func streamingCopyAndHash(src: URL, dst: URL) throws -> Data {
        let reader = try FileHandle(forReadingFrom: src)
        defer { try? reader.close() }
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let writer = try FileHandle(forWritingTo: dst)
        defer { try? writer.close() }

        var hasher = SHA256()
        while true {
            let chunk = try reader.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            try writer.write(contentsOf: chunk)
        }
        try writer.synchronize()
        return Data(hasher.finalize())
    }

    static func hashFile(_ url: URL) throws -> Data {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        var hasher = SHA256()
        while true {
            let chunk = try reader.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }
}
