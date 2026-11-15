import Testing
import Foundation
@testable import PhotoImporter

@Suite("Sidecars")
struct SidecarTests {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("pi-sc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// iPhone exports copied to a card or drive keep IMG_0001.AAE next to
    /// IMG_0001.HEIC; the scan attaches it to the photo instead of listing
    /// it as a file of its own, and drops one with no photo.
    @Test func cardScanAttachesAAEToItsPhoto() throws {
        let dir = tempDir()
        let dcim = dir.appendingPathComponent("DCIM/100APPLE")
        try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)
        for name in ["IMG_0001.HEIC", "IMG_0001.DNG", "IMG_0001.AAE", "IMG_0002.JPG", "ORPHAN.AAE"] {
            try Data(name.utf8).write(to: dcim.appendingPathComponent(name))
        }
        let rows = PhotoScanner.scan(at: dir)
        #expect(rows.map { $0.path.lastPathComponent }.sorted() == ["IMG_0001.DNG", "IMG_0001.HEIC", "IMG_0002.JPG"])
        let heic = try #require(rows.first { $0.path.lastPathComponent == "IMG_0001.HEIC" })
        #expect(heic.companions.map { $0.path.lastPathComponent } == ["IMG_0001.AAE"])
        #expect(heic.companions[0].suffix == "")
        #expect(rows.filter { !$0.companions.isEmpty }.count == 1)
    }

    /// iOS keeps a second edit record, IMG_O5539.AAE, next to IMG_5539.AAE.
    /// Both must survive the rename under distinct names (on the test phone
    /// they collided as IMG_000007.AAE and duplicated on every re-import).
    @Test func secondEditRecordGetsItsOwnName() {
        #expect(CompanionFile.sidecarSuffix(photoStem: "IMG_5539", sidecarStem: "IMG_5539") == "")
        #expect(CompanionFile.sidecarSuffix(photoStem: "IMG_5539", sidecarStem: "img_5539") == "")
        #expect(CompanionFile.sidecarSuffix(photoStem: "IMG_5539", sidecarStem: "IMG_O5539") == "_O")
        #expect(CompanionFile.sidecarSuffix(photoStem: "KYMH1509", sidecarStem: "notes") == "_notes")
    }

    @Test func deviceRowKeepsBothEditRecords() throws {
        let rows = DeviceCatalog.photos(from: [DeviceFileInfo(
            folderPath: "DCIM/202404_a", name: "IMG_5539.HEIC", sizeBytes: 10, captureDate: nil, modificationDate: nil,
            sidecars: [
                DeviceFileInfo(folderPath: "DCIM/202404_a", name: "IMG_5539.AAE", sizeBytes: 1, captureDate: nil, modificationDate: nil),
                DeviceFileInfo(folderPath: "DCIM/202404_a", name: "IMG_O5539.AAE", sizeBytes: 1, captureDate: nil, modificationDate: nil),
            ]
        )], deviceID: "dev")
        let dst = URL(fileURLWithPath: "/out/IMG_000007.HEIC")
        let names = rows[0].companions.map { ImportEngine.companionDestination(for: dst, companion: $0).lastPathComponent }
        #expect(names == ["IMG_000007.AAE", "IMG_000007_O.AAE"])
    }

    @Test func companionsThatWouldCollideAreNumbered() {
        let a = CompanionFile(path: URL(fileURLWithPath: "/c/A.AAE"), sizeBytes: 1, suffix: "")
        let b = CompanionFile(path: URL(fileURLWithPath: "/c/B.aae"), sizeBytes: 1, suffix: "")
        #expect(CompanionFile.uniquified([a, b]).map { $0.suffix } == ["", "-2"])
    }

    @Test func cardScanAttachesSecondEditRecord() throws {
        let dir = tempDir()
        for name in ["IMG_0001.HEIC", "IMG_0001.AAE", "IMG_O0001.AAE"] {
            try Data(name.utf8).write(to: dir.appendingPathComponent(name))
        }
        let rows = PhotoScanner.scan(at: dir)
        #expect(rows.count == 1)
        #expect(rows[0].companions.map { $0.suffix }.sorted() == ["", "_O"])
    }

    @Test func attachIsCaseInsensitiveOnStem() {
        var photos = [PhotoFile(
            path: URL(fileURLWithPath: "/card/DCIM/IMG_0001.heic"),
            sizeBytes: 1,
            meta: PhotoMeta(date: nil, cameraMake: nil, cameraModel: nil, cameraSerial: nil, cameraOwner: nil,
                            lens: nil, iso: nil, shutter: nil, aperture: nil, focalLength: nil, subSecond: nil,
                            fromExif: false)
        )]
        PhotoScanner.attachSidecars([(URL(fileURLWithPath: "/card/DCIM/img_0001.AAE"), 5)], to: &photos)
        #expect(photos[0].companions.count == 1)
        #expect(photos[0].totalBytes == 6)
    }

    /// Delete-after covers companions, judged by their own outcome and with
    /// their photo's backup requirement.
    @Test func deleteEligibilityIncludesCompanions() {
        let photo = URL(fileURLWithPath: "/card/IMG_1.HEIC")
        let aae = URL(fileURLWithPath: "/card/IMG_1.AAE")
        let item = ImportItem(
            src: photo, dst: URL(fileURLWithPath: "/out/IMG_000001.HEIC"), seq: 1, sizeBytes: 1,
            backupDst: URL(fileURLWithPath: "/backup/IMG_000001.HEIC"),
            companions: [CompanionFile(path: aae, sizeBytes: 1, suffix: "")]
        )
        let plan = ImportPlan(items: [item], totalBytes: 2)
        #expect(AppViewModel.deleteEligibleSources(plan: plan, primaryEligible: [photo, aae], backupEligible: [photo, aae]) == [photo, aae])
        // The .AAE's backup copy failed: keep it on the card.
        #expect(AppViewModel.deleteEligibleSources(plan: plan, primaryEligible: [photo, aae], backupEligible: [photo]) == [photo])
        // The photo's primary copy failed: keep the photo (its .AAE was never attempted).
        #expect(AppViewModel.deleteEligibleSources(plan: plan, primaryEligible: [], backupEligible: []).isEmpty)
    }
}

@Suite("Support prompt")
struct SupportPromptTests {
    @Test func showsOncePerVersion() {
        #expect(AppViewModel.shouldShowSupportPrompt(lastShownVersion: nil, currentVersion: "1.0.9"))
        #expect(AppViewModel.shouldShowSupportPrompt(lastShownVersion: "1.0.8", currentVersion: "1.0.9"))
        #expect(!AppViewModel.shouldShowSupportPrompt(lastShownVersion: "1.0.9", currentVersion: "1.0.9"))
        #expect(AppViewModel.shouldShowSupportPrompt(lastShownVersion: "1.0.9", currentVersion: "1.0.10"))
    }
}
