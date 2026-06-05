import Foundation

/// Persists per-card security-scoped bookmarks so a sandboxed build can read
/// an SD/CF card after the user has granted access once — without re-prompting
/// on every insert.
///
/// Why this exists: under the App Sandbox there is NO entitlement that grants
/// blanket read access to removable volumes. The only sanctioned path is a
/// user grant through an Open panel (Powerbox), persisted as a security-scoped
/// bookmark. Card *detection* (NSWorkspace mount notifications in
/// `VolumeWatcher`) needs no permission; reading the files does.
///
/// Device-local (UserDefaults), keyed by mount path. Bookmarks don't resolve
/// on other Macs and a card may remount at a different path — both cases just
/// fall back to a fresh grant, mirroring how `FolderRef` destinations behave.
@MainActor
final class CardAccessStore {
    private let defaults: UserDefaults
    private let key = "cardAccess.v1"
    private var refs: [String: FolderRef]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: FolderRef].self, from: data) {
            self.refs = decoded
        } else {
            self.refs = [:]
        }
    }

    /// Save the user's grant for the card mounted at `mountPath`.
    func store(_ ref: FolderRef, forMountPath mountPath: String) {
        refs[mountPath] = ref
        persist()
    }

    /// Resolve a previously-granted bookmark into an access token (security
    /// scope already started — caller must `.stop()` it). Returns nil if
    /// nothing is stored, or if the bookmark no longer resolves (card
    /// reformatted, remounted elsewhere, stale); in the unresolvable case the
    /// dead entry is dropped so the UI re-prompts cleanly.
    func resolve(forMountPath mountPath: String) -> FolderRef.Resolved? {
        guard let ref = refs[mountPath] else { return nil }
        guard let resolved = ref.resolve() else {
            refs[mountPath] = nil
            persist()
            return nil
        }
        return resolved
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(refs) {
            defaults.set(data, forKey: key)
        }
    }
}
