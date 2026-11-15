import Testing
import Foundation
@testable import PhotoImporter

// iPhone / camera import without hardware: the catalog mapping is pure, and
// the engine is driven through an in-memory `ImportSource` standing in for
// `DeviceImportSource`.

private let deviceID = "30303030-3831-3230-2D30-303432384145"

private func file(
    _ folder: String,
    _ name: String,
    size: Int64 = 100,
    captured: Date? = Date(timeIntervalSince1970: 1_750_000_000),
    sidecars: [DeviceFileInfo] = []
) -> DeviceFileInfo {
    DeviceFileInfo(
        folderPath: folder,
        name: name,
        sizeBytes: size,
        captureDate: captured,
        modificationDate: nil,
        sidecars: sidecars
    )
}

/// Serves fixed byte buffers, `chunk` bytes per read, optionally claiming a
/// different length than it actually holds (a device misreporting size).
private final class MemorySource: ImportSource {
    var contents: [String: Data] = [:]
    var claimedLength: [String: UInt64] = [:]
    var fileDates: [String: SourceDates] = [:]
    var chunk = 3

    func add(_ url: URL, _ data: Data) { contents[url.absoluteString] = data }

    func exists(_ url: URL) -> Bool { contents[url.absoluteString] != nil }

    func size(of url: URL) -> UInt64? { contents[url.absoluteString].map { UInt64($0.count) } }

    func dates(of url: URL) -> SourceDates { fileDates[url.absoluteString] ?? SourceDates() }

    func open(_ url: URL) throws -> SourceReader {
        guard let data = contents[url.absoluteString] else { throw CameraDeviceError.fileMissing }
        return MemoryReader(data: data, length: claimedLength[url.absoluteString] ?? UInt64(data.count), chunk: chunk)
    }
}

private final class MemoryReader: SourceReader {
    let data: Data
    let length: UInt64
    let chunk: Int
    var offset = 0

    init(data: Data, length: UInt64, chunk: Int) {
        self.data = data
        self.length = length
        self.chunk = chunk
    }

    func read() throws -> Data {
        guard offset < data.count else { return Data() }
        let end = min(data.count, offset + chunk)
        defer { offset = end }
        return data.subdata(in: offset..<end)
    }

    func close() {}
}

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("pi-dev-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func deviceURL(_ folder: String, _ name: String) -> URL {
    DeviceCatalog.url(deviceID: deviceID, file: file(folder, name))!
}

@Suite("Device catalog")
struct DeviceCatalogTests {
    @Test func livePhotoVideoAndEditsBecomeCompanionsNotRows() {
        let heic = file("DCIM/202508_a", "IMG_0920.HEIC", size: 1_500_000, sidecars: [
            file("DCIM/202508_a", "IMG_0920.MOV", size: 2_000_000),
            file("DCIM/202508_a", "IMG_0920.AAE", size: 900),
            file("DCIM/202508_a", "IMG_0920.XMP", size: 10),
        ])
        let rows = DeviceCatalog.photos(from: [heic], deviceID: deviceID)
        #expect(rows.count == 1)
        #expect(rows[0].path.lastPathComponent == "IMG_0920.HEIC")
        #expect(rows[0].companions.map { $0.path.lastPathComponent } == ["IMG_0920.MOV", "IMG_0920.AAE"])
        #expect(rows[0].companions.map { $0.suffix } == ["_live", ""])
        #expect(rows[0].totalBytes == 3_500_900)
    }

    /// An edited video or a plain edited photo carries its .AAE too.
    @Test func aaeRidesWithVideosAndPlainPhotos() {
        let rows = DeviceCatalog.photos(from: [
            file("DCIM/100APPLE", "IMG_1234.MOV", sidecars: [file("DCIM/100APPLE", "IMG_1234.AAE")]),
            file("DCIM/100APPLE", "IMG_6104.PNG", sidecars: [file("DCIM/100APPLE", "IMG_6104.AAE")]),
        ], deviceID: deviceID)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.companions.count == 1 && $0.companions[0].suffix == "" })
        #expect(rows.allSatisfy { !$0.companions[0].isLivePhotoVideo })
    }

    @Test func videoListedBothWaysIsImportedOnceAsCompanion() {
        let heic = file("DCIM/100APPLE", "IMG_1.HEIC", sidecars: [file("DCIM/100APPLE", "IMG_1.MOV")])
        let alsoTopLevel = file("DCIM/100APPLE", "IMG_1.MOV")
        let rows = DeviceCatalog.photos(from: [alsoTopLevel, heic], deviceID: deviceID)
        #expect(rows.map { $0.path.lastPathComponent } == ["IMG_1.HEIC"])
        #expect(rows[0].companions.count == 1)
    }

    @Test func videoSidecarOfAVideoIsNotALivePhoto() {
        let mov = file("DCIM/100APPLE", "IMG_E1234.MOV", sidecars: [file("DCIM/100APPLE", "IMG_E1234.MP4")])
        let rows = DeviceCatalog.photos(from: [mov], deviceID: deviceID)
        #expect(rows.count == 1)
        #expect(rows[0].companions.isEmpty)
    }

    /// A PTP camera can hide the RAW of a RAW+JPEG pair behind the JPEG. It
    /// must still be imported, and pair with the JPEG for `{seq}`.
    @Test func rawSidecarBecomesRowAndPairsWithJpeg() throws {
        let jpg = file("DCIM/100_FUJI", "DSCF0001.JPG", sidecars: [file("DCIM/100_FUJI", "DSCF0001.RAF")])
        let rows = DeviceCatalog.photos(from: [jpg], deviceID: deviceID)
        #expect(rows.map { $0.path.lastPathComponent }.sorted() == ["DSCF0001.JPG", "DSCF0001.RAF"])
        let plan = ImportEngine.plan(
            photos: rows,
            rules: [CompiledRule(fileType: .all, segments: try Template.parse("IMG_{seq:0000}.{file.ext}"), backupFolder: nil)],
            destination: URL(fileURLWithPath: "/out"),
            cardLabel: "X-T5",
            seqStart: 7
        )
        #expect(Set(plan.items.map { $0.seq }) == [7])
    }

    @Test func unknownExtensionsAreSkipped() {
        let rows = DeviceCatalog.photos(from: [file("DCIM", "notes.txt"), file("DCIM", "IMG_1.PNG")], deviceID: deviceID)
        #expect(rows.map { $0.path.lastPathComponent } == ["IMG_1.PNG"])
    }

    /// iPhone numbering wraps at 9999, so the same name recurs in different
    /// folders (454 times on the test phone). Each must stay its own row.
    @Test func sameNameInDifferentFoldersStaysDistinct() {
        let rows = DeviceCatalog.photos(from: [
            file("DCIM/201710_a", "IMG_0247.JPG"),
            file("DCIM/202410_a", "IMG_0247.JPG"),
        ], deviceID: deviceID)
        #expect(rows.count == 2)
        #expect(Set(rows.map { $0.id }).count == 2)
    }

    @Test func urlsAreDeviceSchemeAndKeepNamesIntact() throws {
        let u = try #require(DeviceCatalog.url(deviceID: deviceID, file: file("DCIM/Some Folder", "My 50% photo.jpg")))
        #expect(u.scheme == "icdevice")
        #expect(!u.isFileURL)
        #expect(u.lastPathComponent == "My 50% photo.jpg")
        #expect(u.deletingLastPathComponent().lastPathComponent == "Some Folder")
        #expect(u.pathExtension == "jpg")

        let slash = try #require(DeviceCatalog.url(deviceID: deviceID, file: file("DCIM", "a/b.jpg")))
        #expect(slash.pathComponents.count == 3)  // "/", "DCIM", "a/b.jpg"
    }

    @Test func captureDateWinsAndModificationDateIsFallback() {
        let captured = Date(timeIntervalSince1970: 1_700_000_000)
        let modified = Date(timeIntervalSince1970: 1_800_000_000)
        var f = file("DCIM", "IMG_1.JPG", captured: captured)
        f.modificationDate = modified
        #expect(DeviceCatalog.placeholderMeta(f).date == captured)
        f.captureDate = nil
        #expect(DeviceCatalog.placeholderMeta(f).date == modified)
    }

    /// Fetching details must never move a photo to another date folder.
    @Test func mergingMetadataKeepsCaptureDate() {
        let captured = Date(timeIntervalSince1970: 1_700_000_000)
        var base = DeviceCatalog.placeholderMeta(file("DCIM", "IMG_1.HEIC", captured: captured))
        base.date = captured
        let props: [String: Any] = [
            "{TIFF}": ["Make": "Apple", "Model": "iPhone 14 Pro Max"],
            "{Exif}": [
                "DateTimeOriginal": "2001:01:01 00:00:00",
                "LensModel": "iPhone 14 Pro Max back triple camera 6.86mm f/1.78",
                "ISOSpeedRatings": [125],
                "SubsecTimeOriginal": "496",
            ],
        ]
        let merged = DeviceCatalog.merging(props, into: base)
        #expect(merged.date == captured)
        #expect(merged.cameraMake == "Apple")
        #expect(merged.cameraModel == "iPhone 14 Pro Max")
        #expect(merged.iso == 125)
        #expect(merged.subSecond == "496")
        #expect(merged.fromExif)
    }

    @Test func onlyCameraTokensNeedFullMetadata() {
        let dateOnly = [TemplateRule(fileType: .all, template: "{date:YYYY}/{date:YYYY-MM-DD}/IMG_{seq:000000}.{file.ext}")]
        #expect(!AppViewModel.anyActiveRuleNeedsFullMetadata(dateOnly))
        let withModel = [TemplateRule(fileType: .all, template: "{camera.model}/{file.name}")]
        #expect(AppViewModel.anyActiveRuleNeedsFullMetadata(withModel))
        let inactive = [TemplateRule(fileType: .all, template: "{file.name}"), TemplateRule(fileType: .raw, template: "")]
        #expect(!AppViewModel.anyActiveRuleNeedsFullMetadata(inactive))
    }
}

@Suite("Device import")
struct DeviceImportTests {
    private func livePhotoPlan(dest: URL, source: MemorySource, backup: URL? = nil) throws -> ImportPlan {
        let heic = deviceURL("DCIM/202508_a", "IMG_0920.HEIC")
        let mov = deviceURL("DCIM/202508_a", "IMG_0920.MOV")
        source.add(heic, Data("still-image-bytes".utf8))
        source.add(mov, Data("live-video-bytes!!".utf8))
        let rows = DeviceCatalog.photos(from: [
            file("DCIM/202508_a", "IMG_0920.HEIC", size: 17, sidecars: [file("DCIM/202508_a", "IMG_0920.MOV", size: 18)]),
        ], deviceID: deviceID)
        return ImportEngine.plan(
            photos: rows,
            rules: [CompiledRule(fileType: .all, segments: try Template.parse("{date:YYYY}/IMG_{seq:000000}.{file.ext}"), backupFolder: backup)],
            destination: dest,
            cardLabel: "iPhone",
            seqStart: 123
        )
    }

    @Test func livePhotoLandsAsPhotoPlusLiveMov() throws {
        let dest = tempDir()
        let source = MemorySource()
        let plan = try livePhotoPlan(dest: dest, source: source)
        #expect(plan.totalBytes == 35)
        let r = ImportEngine.executePrimary(plan: plan, options: ImportOptions(collisionPolicy: .skipSameHash, verify: true), source: source) { _ in }
        #expect(r.copied == 2)
        #expect(r.verified == 2)
        #expect(r.failed == 0)
        let year = try #require(try FileManager.default.contentsOfDirectory(atPath: dest.path).first)
        let names = try FileManager.default.contentsOfDirectory(atPath: dest.appendingPathComponent(year).path).sorted()
        #expect(names == ["IMG_000123.HEIC", "IMG_000123_live.MOV"])
        #expect(try Data(contentsOf: dest.appendingPathComponent(year).appendingPathComponent("IMG_000123_live.MOV")) == Data("live-video-bytes!!".utf8))
    }

    /// When the photo is renamed on collision, its video follows the new name.
    @Test func companionFollowsRenamedPhoto() throws {
        let dest = tempDir()
        let source = MemorySource()
        let plan = try livePhotoPlan(dest: dest, source: source)
        let target = plan.items[0].dst
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("someone else's photo".utf8).write(to: target)

        let r = ImportEngine.executePrimary(plan: plan, options: ImportOptions(collisionPolicy: .renameIfDifferent, verify: false), source: source) { _ in }
        #expect(r.copied == 2)
        let names = try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path).sorted()
        #expect(names == ["IMG_000123-2.HEIC", "IMG_000123-2_live.MOV", "IMG_000123.HEIC"])
    }

    /// Re-importing the same Live Photo skips both halves as identical.
    @Test func reimportSkipsBothHalves() throws {
        let dest = tempDir()
        let source = MemorySource()
        let plan = try livePhotoPlan(dest: dest, source: source)
        let opts = ImportOptions(collisionPolicy: .skipSameHash, verify: false)
        _ = ImportEngine.executePrimary(plan: plan, options: opts, source: source) { _ in }
        var outcomes: [ImportOutcome] = []
        let r = ImportEngine.executePrimary(plan: plan, options: opts, source: source) { outcomes.append($0.outcome) }
        #expect(r.skipped == 2)
        #expect(r.copied == 0)
        #expect(outcomes == [.skippedIdentical, .skippedIdentical])
    }

    @Test func companionIsReportedWhenItsPhotoFails() throws {
        let dest = tempDir()
        let source = MemorySource()
        let plan = try livePhotoPlan(dest: dest, source: source)
        source.contents.removeValue(forKey: plan.items[0].src.absoluteString)  // photo vanished
        let r = ImportEngine.executePrimary(plan: plan, options: ImportOptions(collisionPolicy: .skipSameHash, verify: false), source: source) { _ in }
        #expect(r.failed == 2)
        #expect(r.failures.map { $0.1 } == ["source not found", "not copied because its photo failed"])
    }

    @Test func backupPhaseCopiesCompanionsToo() throws {
        let dest = tempDir()
        let backup = tempDir()
        let source = MemorySource()
        let plan = try livePhotoPlan(dest: dest, source: source, backup: backup)
        let opts = ImportOptions(collisionPolicy: .skipSameHash, verify: true)
        _ = ImportEngine.executePrimary(plan: plan, options: opts, source: source) { _ in }
        let r = try #require(ImportEngine.executeBackup(plan: plan, options: opts, source: source) { _ in })
        #expect(r.copied == 2)
        #expect(r.verified == 2)
        let year = try #require(try FileManager.default.contentsOfDirectory(atPath: backup.path).first)
        let names = try FileManager.default.contentsOfDirectory(atPath: backup.appendingPathComponent(year).path).sorted()
        #expect(names == ["IMG_000123.HEIC", "IMG_000123_live.MOV"])
    }

    /// A source that delivers fewer bytes than it claims must fail, not
    /// produce a "verified" truncated copy.
    @Test func shortReadFromDeviceFails() throws {
        let dest = tempDir()
        let source = MemorySource()
        let src = deviceURL("DCIM", "IMG_1.JPG")
        source.add(src, Data("only-part".utf8))
        source.claimedLength[src.absoluteString] = 50
        let plan = ImportPlan(items: [ImportItem(src: src, dst: dest.appendingPathComponent("IMG_1.JPG"), seq: 1, sizeBytes: 50)], totalBytes: 50)
        let r = ImportEngine.executePrimary(plan: plan, options: ImportOptions(collisionPolicy: .overwrite, verify: true), source: source) { _ in }
        #expect(r.failed == 1)
        #expect(r.failures.first?.1.contains("short read") == true)
    }

    /// Finder must show when the photo was taken, not when it was imported:
    /// the copy (and its Live Photo video) carries the device's dates.
    @Test func copiesKeepDeviceDates() throws {
        let dest = tempDir()
        let source = MemorySource()
        let plan = try livePhotoPlan(dest: dest, source: source)
        let taken = Date(timeIntervalSince1970: 1_754_772_794)       // 2025-08-09
        let edited = Date(timeIntervalSince1970: 1_754_859_194)      // a day later
        source.fileDates[plan.items[0].src.absoluteString] = SourceDates(created: taken, modified: edited)
        source.fileDates[plan.items[0].companions[0].path.absoluteString] = SourceDates(created: taken, modified: taken)
        _ = ImportEngine.executePrimary(plan: plan, options: ImportOptions(collisionPolicy: .skipSameHash, verify: true), source: source) { _ in }

        let photo = try FileManager.default.attributesOfItem(atPath: plan.items[0].dst.path)
        #expect(photo[.modificationDate] as? Date == edited)
        #expect(photo[.creationDate] as? Date == taken)
        let video = ImportEngine.companionDestination(for: plan.items[0].dst, companion: plan.items[0].companions[0])
        #expect(try FileManager.default.attributesOfItem(atPath: video.path)[.modificationDate] as? Date == taken)
    }

    /// Same for a card: the copy keeps the source file's dates.
    @Test func cardCopiesKeepSourceDates() throws {
        let dir = tempDir()
        let src = dir.appendingPathComponent("DSC0001.JPG")
        try Data("jpeg".utf8).write(to: src)
        let shot = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: shot, .creationDate: shot], ofItemAtPath: src.path)
        let dst = dir.appendingPathComponent("out/IMG_000001.JPG")
        let plan = ImportPlan(items: [ImportItem(src: src, dst: dst, seq: 1, sizeBytes: 4)], totalBytes: 4)
        let r = ImportEngine.executePrimary(plan: plan, options: ImportOptions(collisionPolicy: .overwrite, verify: true)) { _ in }
        #expect(r.copied == 1)
        let attrs = try FileManager.default.attributesOfItem(atPath: dst.path)
        #expect(attrs[.modificationDate] as? Date == shot)
        #expect(attrs[.creationDate] as? Date == shot)
    }

    /// The .AAE keeps the photo's exact final name — including a collision
    /// rename — so Photos can re-apply the edit to the right original.
    @Test func aaeTakesPhotosFinalName() throws {
        let dest = tempDir()
        let source = MemorySource()
        let heic = deviceURL("DCIM/100APPLE", "IMG_0078.HEIC")
        let aae = deviceURL("DCIM/100APPLE", "IMG_0078.AAE")
        source.add(heic, Data("original".utf8))
        source.add(aae, Data("<plist/>".utf8))
        let rows = DeviceCatalog.photos(from: [
            file("DCIM/100APPLE", "IMG_0078.HEIC", size: 8, sidecars: [file("DCIM/100APPLE", "IMG_0078.AAE", size: 8)]),
        ], deviceID: deviceID)
        let plan = ImportEngine.plan(
            photos: rows,
            rules: [CompiledRule(fileType: .all, segments: try Template.parse("IMG_{seq:000000}.{file.ext}"), backupFolder: nil)],
            destination: dest,
            cardLabel: "iPhone",
            seqStart: 123
        )
        try Data("other photo".utf8).write(to: plan.items[0].dst)   // force a rename
        let r = ImportEngine.executePrimary(plan: plan, options: ImportOptions(collisionPolicy: .renameIfDifferent, verify: true), source: source) { _ in }
        #expect(r.copied == 2)
        let names = try FileManager.default.contentsOfDirectory(atPath: dest.path).sorted()
        #expect(names == ["IMG_000123-2.AAE", "IMG_000123-2.HEIC", "IMG_000123.HEIC"])
    }

    @Test func templateTokensWorkOnDeviceURLs() throws {
        let photo = PhotoFile(path: deviceURL("DCIM/202508_a", "IMG_0920.HEIC"), sizeBytes: 1, meta: DeviceCatalog.placeholderMeta(file("DCIM", "x.HEIC")))
        let rel = Template.evaluate(try Template.parse("{card.label}/{file.stem}-{file.ext}/{file.name}"), photo: photo, seq: 1, cardLabel: "iPhone")
        #expect(rel == "iPhone/IMG_0920-HEIC/IMG_0920.HEIC")
    }
}
