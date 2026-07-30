import Testing
import Foundation
@testable import PhotoImporter

@Suite("Card access validation")
struct CardAccessValidationTests {
    @Test func acceptsOriginalBookmarkTarget() {
        let stored = "/Volumes/CAMERA"
        #expect(CardAccessStore.resolvedURL(URL(fileURLWithPath: stored), matchesStoredPath: stored))
    }

    @Test func rejectsTahoeNoFollowTarget() {
        let stored = "/Volumes/CAMERA"
        let broken = URL(fileURLWithPath: "/Volumes/CAMERA/.nofollow")
        #expect(!CardAccessStore.resolvedURL(broken, matchesStoredPath: stored))
    }

    @Test func tahoeWorkaroundEndsAtTwentySixPointTwo() {
        #expect(AppViewModel.needsTahoeVolumeBookmarkWorkaround(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        ))
        #expect(AppViewModel.needsTahoeVolumeBookmarkWorkaround(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 9)
        ))
        #expect(!AppViewModel.needsTahoeVolumeBookmarkWorkaround(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 2, patchVersion: 0)
        ))
        #expect(!AppViewModel.needsTahoeVolumeBookmarkWorkaround(
            OperatingSystemVersion(majorVersion: 15, minorVersion: 7, patchVersion: 0)
        ))
    }

    @Test func emptyDirectoryIsStillEnumerable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-card-access-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(CardAccessStore.canEnumerateDirectory(directory))
    }
}
