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

/// The iCloud sync warning under the naming template is scoped to templates
/// that actually render `{seq}` — otherwise no cross-device collision is
/// possible and the warning would be pure noise.
@Suite("Sequence sync warning scope")
struct SequenceSyncWarningTests {
    private func rule(_ template: String) -> TemplateRule {
        TemplateRule(fileType: .all, template: template)
    }

    @Test func detectsSeqToken() {
        #expect(AppViewModel.anyActiveRuleUsesSequence([rule("{seq:000000}")]))
        #expect(AppViewModel.anyActiveRuleUsesSequence([rule("{date:YYYY}/IMG_{seq:0000}")]))
    }

    @Test func ignoresTemplatesWithoutSeq() {
        #expect(!AppViewModel.anyActiveRuleUsesSequence([rule("{date:YYYY-MM-DD}/{filename}")]))
        #expect(!AppViewModel.anyActiveRuleUsesSequence([rule("{cameraModel}/{filestem}.{fileext}")]))
    }

    @Test func ignoresInactiveAndUnparseableRules() {
        // Blank template = inactive row.
        #expect(!AppViewModel.anyActiveRuleUsesSequence([rule("")]))
        #expect(!AppViewModel.anyActiveRuleUsesSequence([rule("   ")]))
        // `{seq}` without a padding width fails to parse, so it renders
        // nothing and cannot collide.
        #expect(!AppViewModel.anyActiveRuleUsesSequence([rule("{seq}")]))
        // Unterminated brace — also unparseable.
        #expect(!AppViewModel.anyActiveRuleUsesSequence([rule("IMG_{seq:0000")]))
    }

    @Test func detectsSeqInAnyRuleRow() {
        let rules = [
            rule("{date:YYYY}/{filename}"),
            rule("RAW/{seq:00000}"),
        ]
        #expect(AppViewModel.anyActiveRuleUsesSequence(rules))
    }

    @Test func emptyRuleListDoesNotWarn() {
        #expect(!AppViewModel.anyActiveRuleUsesSequence([]))
    }
}

/// Verifies the live iCloud/sequence plumbing rather than just the pure
/// template check: in a test process there is no `ubiquity-kvstore-identifier`
/// entitlement, so `synchronize()` fails and the store must report itself
/// unavailable — which is exactly the state the warning exists to surface.
@Suite("Cloud sync state")
@MainActor
struct CloudSyncStateTests {
    @Test func unentitledProcessReportsCloudUnavailable() {
        // Same probe CloudKVStore uses. Documents the environment assumption
        // the next assertion depends on.
        #expect(NSUbiquitousKeyValueStore.default.synchronize() == false)
    }

    @Test func sequenceStoreFlagsSyncUnreliableWithoutCloud() {
        let store = SequenceStore(cloud: CloudKVStore.shared)
        // The Combine binding delivers the initial combineLatest value
        // synchronously on construction.
        #expect(store.syncUnreliable)
    }

    @Test func counterStillWorksWithoutCloud() {
        let store = SequenceStore(cloud: CloudKVStore.shared)
        let start = store.nextStart()
        // Backed by a real UserDefaults mirror, so the counter survives
        // between runs. (It's the test host's own defaults domain, not the
        // shipped app's, so this can't disturb a dev machine's real counter —
        // but leaving it climbing 10 per run would still make the starting
        // value differ every time.)
        defer { store.setNextStart(start) }

        store.commit(highestUsed: start + 10)
        // Local UserDefaults mirror keeps the counter monotonic even with no
        // iCloud, so degraded sync must not break importing.
        #expect(store.nextStart() == start + 11)
        // commit is idempotent: a lower value is ignored.
        store.commit(highestUsed: start)
        #expect(store.nextStart() == start + 11)
    }
}

/// Adding `hashAlgorithm` to the iCloud-synced options blob must not break
/// blobs written by earlier versions. Swift's synthesized `Codable` throws on
/// a missing key even when the property has a default, so without the
/// hand-written `init(from:)` the whole decode would fail and every synced
/// option would silently reset to its default on upgrade.
@Suite("Synced options migration")
@MainActor
struct SyncedOptionsMigrationTests {
    private static let key = "options.v1"

    @Test func legacyBlobWithoutHashAlgorithmStillRestores() throws {
        let saved = CloudKVStore.shared.data(forKey: Self.key)
        let formKey = "formState.v1"
        let savedForm = UserDefaults.standard.data(forKey: formKey)
        defer {
            CloudKVStore.shared.set(saved, forKey: Self.key)
            if let savedForm {
                UserDefaults.standard.set(savedForm, forKey: formKey)
            } else {
                UserDefaults.standard.removeObject(forKey: formKey)
            }
        }

        // Exactly what 1.0.5 wrote: no `hashAlgorithm` key. Non-default
        // values so a silent reset is visible rather than coincidental.
        let legacy = """
        {
          "collisionPolicy" : "overwrite",
          "verify" : true,
          "deleteAfter" : true,
          "autoEject" : true
        }
        """
        CloudKVStore.shared.set(Data(legacy.utf8), forKey: Self.key)

        let vm = AppViewModel.makeDefault()
        // Every pre-existing option survived...
        #expect(vm.collisionPolicy == .overwrite)
        #expect(vm.verify)
        #expect(vm.deleteAfter)
        #expect(vm.autoEject)
        // ...and the new field falls back to the safe default.
        #expect(vm.hashAlgorithm == .sha256)
    }

    @Test func roundTripPreservesHashAlgorithm() throws {
        let saved = CloudKVStore.shared.data(forKey: Self.key)
        let formKey = "formState.v1"
        let savedForm = UserDefaults.standard.data(forKey: formKey)
        defer {
            CloudKVStore.shared.set(saved, forKey: Self.key)
            if let savedForm {
                UserDefaults.standard.set(savedForm, forKey: formKey)
            } else {
                UserDefaults.standard.removeObject(forKey: formKey)
            }
        }

        let blob = """
        {
          "collisionPolicy" : "skipSameHash",
          "verify" : true,
          "deleteAfter" : false,
          "autoEject" : false,
          "hashAlgorithm" : "xxhash64"
        }
        """
        CloudKVStore.shared.set(Data(blob.utf8), forKey: Self.key)

        let vm = AppViewModel.makeDefault()
        #expect(vm.hashAlgorithm == .xxhash64)
        #expect(vm.verify)
    }
}

/// End-to-end check of the warning flag through a real view model, so the
/// live `CloudKVStore` -> `SequenceStore` -> `AppViewModel` read path is
/// exercised rather than just the pure template helper.
///
/// Only the "sync is unreliable" half can be driven here: `syncUnreliable` is
/// `private(set)` and in an unentitled test process `synchronize()` always
/// fails, so the flag is pinned true and no test-visible route flips it back.
/// Rather than add a mutator to shipping code, the healthy-sync case is left
/// to the `Cloud sync state` suite above.
@Suite("Sequence sync warning end to end")
@MainActor
struct SequenceSyncWarningIntegrationTests {
    @Test func warningFollowsTemplateWhenSyncIsUnreliable() async throws {
        // makeDefault() restores persisted form state and rewrites it when
        // `rules` changes. That lands in the test host's own defaults domain
        // rather than the shipped app's, so it can't disturb a real install,
        // but restore it anyway so runs don't inherit each other's rules.
        let key = "formState.v1"
        let saved = UserDefaults.standard.data(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let vm = AppViewModel.makeDefault()
        // Precondition: no iCloud entitlement in a test process.
        #expect(vm.sequenceStore.syncUnreliable)

        vm.rules = [TemplateRule(fileType: .all, template: "{date:YYYY}/IMG_{seq:0000}")]
        #expect(vm.usesSequenceToken)
        #expect(vm.showSequenceSyncWarning)

        // No {seq} anywhere — nothing can collide, so the warning must go
        // even though sync is still broken.
        vm.rules = [TemplateRule(fileType: .all, template: "{date:YYYY}/{file.name}")]
        #expect(!vm.usesSequenceToken)
        #expect(!vm.showSequenceSyncWarning)

        // The persist sink is dispatched async on main, so let it run before
        // the deferred restore — otherwise it writes after the restore and
        // the snapshot is lost.
        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}
