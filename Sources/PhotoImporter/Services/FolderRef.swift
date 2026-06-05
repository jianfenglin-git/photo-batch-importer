import Foundation

/// Sandbox-friendly reference to a user-chosen folder. Stores a
/// security-scoped bookmark (so access survives app restarts under the
/// sandbox) and a separate display path (so the UI can show a readable
/// value even when the bookmark can't be resolved on the current device).
///
/// When a preset is synced across devices via iCloud, the bookmark may
/// not resolve on the receiving device — volume paths differ, the folder
/// may not exist yet, etc. Callers that can't resolve should surface a
/// "please re-select this folder" affordance rather than silently
/// substituting a wrong path.
struct FolderRef: Hashable, Codable {
    /// `bookmarkData(options: .withSecurityScope)` output. Base64-encoded
    /// opaque payload when crossing JSON boundaries.
    var bookmark: Data
    /// Human-readable path the user picked (for tooltip / error text).
    /// Won't resolve on another device, but helps the user remember what
    /// folder they meant.
    var displayPath: String

    /// Build from a freshly-picked URL (e.g. from NSOpenPanel).
    init?(url: URL) {
        guard let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            return nil
        }
        self.bookmark = data
        self.displayPath = url.path
    }

    /// Resolve the bookmark back into a URL + start security-scoped access.
    /// The returned `Resolved` token must be kept alive during I/O, then
    /// released via `.stop()` (which calls `stopAccessingSecurityScopedResource`).
    func resolve() -> Resolved? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            return nil
        }
        let started = url.startAccessingSecurityScopedResource()
        return Resolved(url: url, stale: stale, needsStop: started)
    }

    /// RAII-ish wrapper: holds the resolved URL and stops the security
    /// scope on `stop()` or deinit. Not thread-safe — call from one actor.
    final class Resolved {
        let url: URL
        let stale: Bool
        private var needsStop: Bool

        init(url: URL, stale: Bool, needsStop: Bool) {
            self.url = url
            self.stale = stale
            self.needsStop = needsStop
        }

        func stop() {
            if needsStop {
                url.stopAccessingSecurityScopedResource()
                needsStop = false
            }
        }

        deinit {
            if needsStop {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }
}
