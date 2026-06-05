import Foundation
import Combine

/// Thin wrapper over `NSUbiquitousKeyValueStore` that also mirrors every
/// write through `UserDefaults` as a local fallback. Behavior:
///
/// - If iCloud is available (user signed in, app has the
///   `com.apple.developer.ubiquity-kvstore-identifier` entitlement) then
///   reads and writes go to the iCloud key-value store and changes made on
///   another device fire `externalChanges`.
/// - If iCloud is NOT available, reads fall through to `UserDefaults` and
///   writes are local-only — the app stays functional without a cloud
///   account.
///
/// Quota: 1 MB / 1024 keys / 1 MB per value. Photo Importer's settings are
/// well under this — a preset blob is a few hundred bytes.
@MainActor
final class CloudKVStore: ObservableObject {
    /// Emits whenever another device pushed a change for any key.
    let externalChanges = PassthroughSubject<Set<String>, Never>()

    private let cloud: NSUbiquitousKeyValueStore
    private let local: UserDefaults
    private var observer: NSObjectProtocol?

    static let shared = CloudKVStore()

    private init() {
        self.cloud = NSUbiquitousKeyValueStore.default
        self.local = .standard
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] note in
            let keys = (note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]) ?? []
            Task { @MainActor in
                self?.externalChanges.send(Set(keys))
            }
        }
        // Pull the latest from iCloud on launch. `synchronize()` is
        // misnamed: it doesn't block, it just hints the daemon to reconcile.
        cloud.synchronize()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Raw accessors

    /// Read a string. iCloud first; falls back to UserDefaults if nil.
    func string(forKey key: String) -> String? {
        cloud.string(forKey: key) ?? local.string(forKey: key)
    }

    func set(_ value: String?, forKey key: String) {
        if let value {
            cloud.set(value, forKey: key)
            local.set(value, forKey: key)
        } else {
            cloud.removeObject(forKey: key)
            local.removeObject(forKey: key)
        }
        cloud.synchronize()
    }

    func int(forKey key: String) -> Int64? {
        // NSUbiquitousKeyValueStore returns 0 for missing keys, which is
        // ambiguous. Check object presence first.
        if cloud.object(forKey: key) != nil {
            return cloud.longLong(forKey: key)
        }
        if local.object(forKey: key) != nil {
            return Int64(local.integer(forKey: key))
        }
        return nil
    }

    func set(_ value: Int64?, forKey key: String) {
        if let value {
            cloud.set(value, forKey: key)
            local.set(Int(value), forKey: key)
        } else {
            cloud.removeObject(forKey: key)
            local.removeObject(forKey: key)
        }
        cloud.synchronize()
    }

    func bool(forKey key: String) -> Bool? {
        if cloud.object(forKey: key) != nil {
            return cloud.bool(forKey: key)
        }
        if local.object(forKey: key) != nil {
            return local.bool(forKey: key)
        }
        return nil
    }

    func set(_ value: Bool?, forKey key: String) {
        if let value {
            cloud.set(value, forKey: key)
            local.set(value, forKey: key)
        } else {
            cloud.removeObject(forKey: key)
            local.removeObject(forKey: key)
        }
        cloud.synchronize()
    }

    func data(forKey key: String) -> Data? {
        cloud.data(forKey: key) ?? local.data(forKey: key)
    }

    func set(_ value: Data?, forKey key: String) {
        if let value {
            cloud.set(value, forKey: key)
            local.set(value, forKey: key)
        } else {
            cloud.removeObject(forKey: key)
            local.removeObject(forKey: key)
        }
        cloud.synchronize()
    }

    // MARK: - Codable convenience

    /// Try decoding from cloud first; if that fails (missing / corrupt /
    /// dev-build where the iCloud entitlement is absent and cloud returns
    /// a stale blob that can't decode), fall through to the UserDefaults
    /// mirror. Prevents silent "restore didn't restore" surprises.
    func codable<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        let decoder = JSONDecoder()
        if let cd = cloud.data(forKey: key),
           let v = try? decoder.decode(T.self, from: cd) {
            return v
        }
        if let ld = local.data(forKey: key),
           let v = try? decoder.decode(T.self, from: ld) {
            return v
        }
        return nil
    }

    func setCodable<T: Encodable>(_ value: T?, forKey key: String) {
        if let value {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(value) {
                set(data, forKey: key)
            }
        } else {
            set(nil as Data?, forKey: key)
        }
    }
}
