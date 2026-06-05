import Testing
import Foundation
@testable import PhotoImporter

private func photo(path: String, date: Date? = nil, cameraModel: String? = "Canon EOS R5") -> PhotoFile {
    var meta = PhotoMeta(
        date: date,
        cameraMake: "Canon",
        cameraModel: cameraModel,
        lens: nil,
        iso: 400,
        shutter: nil,
        aperture: nil,
        focalLength: nil,
        fromExif: date != nil
    )
    meta.fromExif = true
    return PhotoFile(
        path: URL(fileURLWithPath: path),
        sizeBytes: 4_200_000,
        meta: meta
    )
}

private func dt(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0) -> Date {
    var comps = DateComponents()
    comps.year = y; comps.month = m; comps.day = d
    comps.hour = h; comps.minute = min; comps.second = s
    comps.timeZone = TimeZone.current
    return Calendar(identifier: .gregorian).date(from: comps)!
}

@Suite("Template")
struct TemplateTests {
    @Test func literalPassthrough() throws {
        let segs = try Template.parse("just-literal.jpg")
        let p = photo(path: "/card/IMG.JPG")
        #expect(Template.evaluate(segs, photo: p, seq: 1, cardLabel: "C") == "just-literal.jpg")
    }

    @Test func dateSubdirs() throws {
        let segs = try Template.parse("{date:YYYY}/{date:YYYY-MM-DD}_{card.label}/{camera.model}_{seq:0000}.{file.ext}")
        let p = photo(path: "/card/DCIM/100CANON/IMG_0001.CR3", date: dt(2026, 4, 30, 14, 22, 1))
        let out = Template.evaluate(segs, photo: p, seq: 42, cardLabel: "CANON_SD")
        #expect(out == "2026/2026-04-30_CANON_SD/Canon EOS R5_0042.CR3")
    }

    @Test func missingDateYieldsUnknown() throws {
        let segs = try Template.parse("{date:YYYY-MM-DD}")
        let p = photo(path: "/card/IMG.JPG", date: nil)
        #expect(Template.evaluate(segs, photo: p, seq: 1, cardLabel: "") == "unknown")
    }

    @Test func unicodeFilenamesPreserved() throws {
        let segs = try Template.parse("{file.stem}.{file.ext}")
        var p = photo(path: "/card/écurie/Тест.jpg", date: nil)
        p.meta.cameraModel = nil
        #expect(Template.evaluate(segs, photo: p, seq: 1, cardLabel: "") == "Тест.jpg")
    }

    @Test func pathTraversalScrubbed() throws {
        let segs = try Template.parse("../evil/{file.name}")
        let p = photo(path: "/card/IMG.JPG", date: nil)
        #expect(Template.evaluate(segs, photo: p, seq: 1, cardLabel: "") == "_/evil/IMG.JPG")
    }

    @Test func forbiddenCharsReplaced() throws {
        let segs = try Template.parse("{camera.model}_{seq:00}.{file.ext}")
        let p = photo(path: "/card/IMG.JPG", date: dt(2026, 4, 30), cameraModel: "DSC: Model/2")
        #expect(Template.evaluate(segs, photo: p, seq: 42, cardLabel: "") == "DSC_ Model-2_42.JPG")
    }

    @Test func slashInLensValueDoesNotCreateSubdir() throws {
        // Regression: lens name "AF 27/1.2" used to create an "AF 27" folder.
        let segs = try Template.parse("{lens}/{file.name}")
        var p = photo(path: "/card/IMG.JPG", date: dt(2026, 4, 30))
        p.meta.lens = "AF 27/1.2"
        #expect(Template.evaluate(segs, photo: p, seq: 1, cardLabel: "") == "AF 27-1.2/IMG.JPG")
    }

    @Test(arguments: [(1, "42"), (3, "042"), (6, "000042")])
    func seqPadding(pad: Int, expected: String) throws {
        let tmpl = "{seq:\(String(repeating: "0", count: pad))}"
        let segs = try Template.parse(tmpl)
        let p = photo(path: "/card/x.jpg", date: nil)
        #expect(Template.evaluate(segs, photo: p, seq: 42, cardLabel: "") == expected)
    }

    @Test func unterminatedThrows() {
        #expect(throws: TemplateError.unterminated) {
            _ = try Template.parse("{date")
        }
    }

    @Test func unknownTokenThrows() {
        #expect(throws: TemplateError.self) {
            _ = try Template.parse("{banana}")
        }
    }

    @Test func seqRequiresPadding() {
        #expect(throws: TemplateError.seqRequiresPadding) {
            _ = try Template.parse("{seq}")
        }
    }
}
