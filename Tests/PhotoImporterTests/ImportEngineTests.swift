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
            cameraMake: nil, cameraModel: nil, lens: nil,
            iso: nil, shutter: nil, aperture: nil, focalLength: nil,
            fromExif: true
        )
    )
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
            segments: tmpl,
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
            segments: tmpl,
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
            segments: tmpl,
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
        let result = ImportEngine.execute(
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
        let r = ImportEngine.execute(
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
        let r = ImportEngine.execute(
            plan: plan,
            options: ImportOptions(collisionPolicy: .skipSameHash, verify: true),
            onProgress: { _ in }
        )
        #expect(r.copied == 1)
        #expect(r.verified == 1)
        #expect(r.verifyFailed == 0)
        #expect(FileManager.default.fileExists(atPath: src.path))
    }
}
