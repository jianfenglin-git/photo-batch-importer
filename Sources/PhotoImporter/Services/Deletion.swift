import Foundation

/// Best-effort unlink of every path in the list. A missing file is treated
/// as silent success (invariant: "gone afterwards" is satisfied). Called
/// post-import after the user confirms in the UI — never inline during
/// copy, by design.
enum Deletion {
    static func deleteSources(_ paths: [URL]) -> DeleteResult {
        var result = DeleteResult()
        let fm = FileManager.default
        for path in paths {
            if !fm.fileExists(atPath: path.path) {
                continue
            }
            do {
                try fm.removeItem(at: path)
                result.deleted += 1
            } catch {
                result.failed += 1
                result.failures.append((path, error.localizedDescription))
            }
        }
        return result
    }
}
