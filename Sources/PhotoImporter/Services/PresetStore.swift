import Foundation
import Combine

/// Named, user-saved import configurations, synced across the user's Macs
/// via iCloud key-value store. The whole preset list is a single JSON blob
/// under the `presets` key — small enough (a handful of entries, each a
/// few hundred bytes) to fit comfortably within the 1 MB quota.
@MainActor
final class PresetStore: ObservableObject {
    @Published private(set) var presets: [Preset]

    private let cloud: CloudKVStore
    private let key = "presets"
    private var cancellables: Set<AnyCancellable> = []

    init(cloud: CloudKVStore) {
        self.cloud = cloud
        self.presets = cloud.codable([Preset].self, forKey: key) ?? []
        cloud.externalChanges
            .sink { [weak self] keys in
                guard let self = self, keys.contains(self.key) else { return }
                self.presets = self.cloud.codable([Preset].self, forKey: self.key) ?? []
            }
            .store(in: &cancellables)
    }

    /// Insert a new preset (empty id → generates a UUID) or update one by id.
    /// Returns the canonical stored copy.
    @discardableResult
    func upsert(_ preset: Preset) -> Preset {
        var p = preset
        if p.id.isEmpty {
            p.id = UUID().uuidString
        }
        if let idx = presets.firstIndex(where: { $0.id == p.id }) {
            presets[idx] = p
        } else {
            presets.append(p)
        }
        persist()
        return p
    }

    @discardableResult
    func remove(id: String) -> Bool {
        let before = presets.count
        presets.removeAll { $0.id == id }
        let changed = presets.count != before
        if changed { persist() }
        return changed
    }

    /// Insert the built-in starter presets exactly once, on first run when
    /// the user has no existing presets (neither local nor iCloud-synced).
    /// Returns true if anything was seeded.
    @discardableResult
    func seedBuiltInPresetsIfEmpty(_ defaults: [Preset]) -> Bool {
        guard presets.isEmpty else { return false }
        for var d in defaults {
            if d.id.isEmpty { d.id = UUID().uuidString }
            presets.append(d)
        }
        persist()
        return true
    }

    private func persist() {
        cloud.setCodable(presets, forKey: key)
    }
}

enum AppPaths {
    /// Legacy path kept only for bookmark-resolution fallbacks. Under the
    /// App Sandbox this resolves to the app container automatically.
    static var appSupportDir: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return base.appendingPathComponent("PhotoImporter", isDirectory: true)
    }
}
