import Testing
import Foundation
@testable import PhotoImporter

/// Regression test for the original bug that started this project: a Canon
/// 5D Mark IV JPEG and a Fuji X-T5 JPEG whose EXIF the old Rust
/// `kamadak-exif` reader silently returned `None` for — sending photos to
/// `unknown/unknown/` folders. macOS's ImageIO framework handles both
/// natively.
@Suite("ExifFixtures")
struct ExifFixturesTests {
    private func fixtureURL(_ name: String) throws -> URL {
        let bundle = Bundle.module
        if let url = bundle.url(forResource: name, withExtension: "jpg", subdirectory: "Fixtures/exif") {
            return url
        }
        if let url = bundle.url(forResource: name, withExtension: "jpg") {
            return url
        }
        throw SkipError("fixture \(name).jpg missing from test bundle")
    }

    @Test func canon5DMarkIVMetadata() throws {
        let url = try fixtureURL("canon_5d_mk_iv")
        let meta = PhotoScanner.extractMeta(from: url)
        #expect(meta.fromExif, "should have read EXIF via ImageIO")
        #expect(meta.cameraMake == "Canon")
        #expect(meta.cameraModel == "Canon EOS 5D Mark IV")
        #expect(meta.date != nil)
    }

    @Test func fujiXT5Metadata() throws {
        let url = try fixtureURL("fuji_xt5")
        let meta = PhotoScanner.extractMeta(from: url)
        #expect(meta.fromExif, "should have read EXIF via ImageIO")
        #expect(meta.cameraMake == "FUJIFILM")
        #expect(meta.cameraModel == "X-T5")
        #expect(meta.date != nil)
    }
}

private struct SkipError: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}
