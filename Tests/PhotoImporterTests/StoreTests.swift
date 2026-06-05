import Testing
import Foundation
@testable import PhotoImporter

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-store-\(UUID().uuidString).json")
}

private func sample(_ name: String) -> Preset {
    Preset(
        id: "",
        name: name,
        template: "{date:YYYY}/{file.name}",
        destination: URL(fileURLWithPath: "/tmp/out"),
        collisionPolicy: .skipSameHash,
        verify: true,
        deleteAfter: false,
        autoEject: true
    )
}

@MainActor
@Suite("SequenceStore")
struct SequenceStoreTests {
    @Test func startsAtOne() {
        let s = SequenceStore(fileURL: nil)
        #expect(s.nextStart() == 1)
    }

    @Test func commitRaisesWatermark() {
        let s = SequenceStore(fileURL: nil)
        s.commit(highestUsed: 10)
        #expect(s.nextStart() == 11)
        s.commit(highestUsed: 8)
        #expect(s.nextStart() == 11)
        s.commit(highestUsed: 42)
        #expect(s.nextStart() == 43)
    }

    @Test func persistsAcrossInstances() throws {
        let path = tempFile()
        let a = SequenceStore(fileURL: path)
        a.commit(highestUsed: 100)
        let b = SequenceStore(fileURL: path)
        #expect(b.nextStart() == 101)
        try? FileManager.default.removeItem(at: path)
    }

    @Test func corruptFileStartsFresh() throws {
        let path = tempFile()
        try "not json".data(using: .utf8)!.write(to: path)
        let s = SequenceStore(fileURL: path)
        #expect(s.nextStart() == 1)
        try? FileManager.default.removeItem(at: path)
    }
}

@MainActor
@Suite("PresetStore")
struct PresetStoreTests {
    @Test func upsertGeneratesID() {
        let s = PresetStore(fileURL: nil)
        let stored = s.upsert(sample("A"))
        #expect(!stored.id.isEmpty)
    }

    @Test func upsertUpdatesExisting() {
        let s = PresetStore(fileURL: nil)
        let a = s.upsert(sample("A"))
        var a2 = a
        a2.name = "A-renamed"
        s.upsert(a2)
        #expect(s.presets.count == 1)
        #expect(s.presets[0].name == "A-renamed")
    }

    @Test func remove() {
        let s = PresetStore(fileURL: nil)
        let a = s.upsert(sample("A"))
        _ = s.upsert(sample("B"))
        #expect(s.remove(id: a.id))
        #expect(s.presets.count == 1)
        #expect(!s.remove(id: "nonexistent"))
    }

    @Test func persistsAcrossInstances() throws {
        let path = tempFile()
        let aID: String = {
            let s = PresetStore(fileURL: path)
            return s.upsert(sample("keeper")).id
        }()
        let reloaded = PresetStore(fileURL: path)
        #expect(reloaded.presets.count == 1)
        #expect(reloaded.presets[0].id == aID)
        #expect(reloaded.presets[0].name == "keeper")
        try? FileManager.default.removeItem(at: path)
    }
}
