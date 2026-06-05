import Foundation

/// Free-space check before an import runs. Walks up ancestors if the
/// destination folder doesn't exist yet (common when the template has a
/// future-dated subdir that hasn't been created). Applies a 128 MiB headroom
/// on top of the raw byte sum to cover filesystem metadata and partially-
/// full blocks.
enum PreflightService {
    private static let headroomBytes: Int64 = 128 * 1024 * 1024

    static func check(destination: URL, requiredBytes: Int64) throws -> Preflight {
        let available = try availableSpace(on: destination)
        let ok = available >= requiredBytes &+ headroomBytes
        return Preflight(requiredBytes: requiredBytes, availableBytes: available, ok: ok)
    }

    private static func availableSpace(on url: URL) throws -> Int64 {
        var current = url
        let fm = FileManager.default
        while !fm.fileExists(atPath: current.path) {
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                throw NSError(
                    domain: "PhotoImporter.preflight",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No existing ancestor for \(url.path)"]
                )
            }
            current = parent
        }
        let vals = try current.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(vals.volumeAvailableCapacity ?? 0)
    }
}
