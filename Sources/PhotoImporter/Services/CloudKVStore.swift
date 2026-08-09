import Foundation
import Combine
import Network

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

    /// Whether the iCloud key-value store is actually usable right now.
    ///
    /// Published so views can warn about state that silently falls back to
    /// device-local storage — most importantly the `{seq}` counter, which
    /// relies on cloud sync to stay unique across a user's Macs.
    ///
    /// `false` means writes are landing in `UserDefaults` only. Causes:
    /// no iCloud entitlement (dev builds), the user is signed out of
    /// iCloud, or iCloud Drive is switched off.
    ///
    /// This is availability, NOT reachability: `NSUbiquitousKeyValueStore` is
    /// offline-tolerant by design and queues writes for later upload, so a
    /// plain "no Wi-Fi" moment does not flip this to `false`. See
    /// `hasPendingUnsyncedWrites` for the offline case.
    @Published private(set) var isCloudAvailable: Bool = false

    /// True when we've written a value while offline, so iCloud has queued it
    /// locally and other devices can't have seen it yet. Cleared once the
    /// network is back AND the daemon has reconciled.
    ///
    /// Tracked separately from `isCloudAvailable` because
    /// `NSUbiquitousKeyValueStore` is offline-tolerant: it happily accepts
    /// writes with no network and reports success, so availability alone
    /// never reveals the offline collision window.
    @Published private(set) var hasPendingUnsyncedWrites: Bool = false

    /// Whether the network is currently usable. Sampled by `NWPathMonitor`.
    ///
    /// Published because being offline is itself a collision risk for the
    /// `{seq}` counter: nothing can reach iCloud, so a second Mac importing
    /// right now would hand out the same numbers. Availability alone doesn't
    /// reveal this — `NSUbiquitousKeyValueStore` is offline-tolerant and
    /// `synchronize()` keeps returning true with no network — so without this
    /// the warning wouldn't appear until the first write went out, i.e. one
    /// import too late.
    ///
    /// Starts `true` so a launch doesn't flash the warning before
    /// `NWPathMonitor` delivers its first path update.
    @Published private(set) var isOnline: Bool = true

    private let cloud: NSUbiquitousKeyValueStore
    private let local: UserDefaults
    private var observer: NSObjectProtocol?
    private var accountObserver: NSObjectProtocol?
    private let pathMonitor = NWPathMonitor()

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
            let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            Task { @MainActor in
                guard let self else { return }
                // Hearing from the daemon at all proves the pipe works, so
                // any queued writes have been reconciled. A quota violation
                // is the exception — that change was rejected.
                if reason != NSUbiquitousKeyValueStoreQuotaViolationChange {
                    self.hasPendingUnsyncedWrites = false
                    self.isCloudAvailable = true
                }
                self.externalChanges.send(Set(keys))
            }
        }
        // Signing in or out of iCloud changes store availability.
        accountObserver = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshCloudAvailability() }
        }
        // Watch connectivity so we can tell "iCloud queued this write while
        // offline" from "iCloud isn't usable at all".
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(online: online) }
        }
        pathMonitor.start(queue: .global(qos: .utility))

        // Pull the latest from iCloud on launch. `synchronize()` is
        // misnamed: it doesn't block, it just hints the daemon to reconcile.
        // Doubles as the initial availability probe. Deliberately not
        // `flush()` — launch is a read, so it must not mark anything as an
        // unsynced local write.
        refreshCloudAvailability()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
        pathMonitor.cancel()
    }

    /// Connectivity changed. Coming back online, ask the daemon to reconcile
    /// and clear the pending flag if it accepts — the queued writes are on
    /// their way, so the collision window has closed.
    private func networkChanged(online: Bool) {
        let wasOnline = isOnline
        if isOnline != online { isOnline = online }
        guard online, !wasOnline else { return }
        let ok = cloud.synchronize()
        setAvailable(ok)
        if ok && hasPendingUnsyncedWrites {
            hasPendingUnsyncedWrites = false
        }
    }

    /// Re-probe whether iCloud is usable. Cheap; safe to call on demand.
    ///
    /// `synchronize()` is the authoritative probe: it returns `false` exactly
    /// when the store can't reconcile — no `ubiquity-kvstore-identifier`
    /// entitlement (unsandboxed dev builds), or the user is signed out.
    /// Verified empirically that `FileManager.ubiquityIdentityToken` is NOT a
    /// usable substitute: it reports iCloud *Drive* status and stays non-nil
    /// in a build whose KV store is entirely dead (writes vanish,
    /// `dictionaryRepresentation` is empty), which would suppress this
    /// warning precisely when it's needed.
    func refreshCloudAvailability() {
        setAvailable(cloud.synchronize())
    }

    private func setAvailable(_ available: Bool) {
        if isCloudAvailable != available {
            isCloudAvailable = available
        }
        // With no working store there is nothing to sync to, so a separate
        // "pending write" flag would be redundant with the unavailable state.
        if !available && hasPendingUnsyncedWrites {
            hasPendingUnsyncedWrites = false
        }
    }

    /// Record that a write went out and ask the daemon to reconcile.
    ///
    /// `synchronize() == false` means the write never left this device, which
    /// also tells us the store is unavailable. When it succeeds while offline
    /// the value has merely been queued locally, so it's flagged pending —
    /// that's the window in which a second Mac can reuse the same numbers.
    private func flush() {
        let ok = cloud.synchronize()
        setAvailable(ok)
        // Only an offline write is knowably unsynced. A successful online
        // flush is NOT marked pending: with a single Mac no external change
        // ever arrives to clear it, so doing so would pin the warning on
        // permanently for the most common setup.
        if ok && !isOnline {
            hasPendingUnsyncedWrites = true
        }
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
        flush()
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
        flush()
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
        flush()
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
        flush()
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
