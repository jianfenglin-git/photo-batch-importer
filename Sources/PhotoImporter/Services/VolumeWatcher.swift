import Foundation
import AppKit

/// Lists removable volumes and publishes changes when cards are inserted or
/// ejected. Uses `NSWorkspace` notifications — no polling.
@MainActor
final class VolumeWatcher: ObservableObject {
    @Published private(set) var volumes: [Volume] = []

    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let nc = NSWorkspace.shared.notificationCenter
        let refreshHandler: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        observers.append(nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: nil, using: refreshHandler))
        observers.append(nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: nil, using: refreshHandler))
        observers.append(nc.addObserver(forName: NSWorkspace.didRenameVolumeNotification, object: nil, queue: nil, using: refreshHandler))
    }

    deinit {
        let nc = NSWorkspace.shared.notificationCenter
        for observer in observers {
            nc.removeObserver(observer)
        }
    }

    func refresh() {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeIsRemovableKey,
            .volumeIsInternalKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []
        let list: [Volume] = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            // Consider a volume removable when the OS says so, OR when it's
            // mounted under /Volumes/ and not internal (covers the common
            // SD/CF case where `volumeIsRemovableKey` is false but the card
            // is still obviously removable).
            let isRemovable = values?.volumeIsRemovable ?? false
            let isInternal = values?.volumeIsInternal ?? false
            let underVolumes = url.path.hasPrefix("/Volumes/")
            guard isRemovable || (underVolumes && !isInternal) else { return nil }
            let label = values?.volumeName ?? url.lastPathComponent
            return Volume(
                label: label,
                mountPoint: url,
                totalBytes: Int64(values?.volumeTotalCapacity ?? 0),
                availableBytes: Int64(values?.volumeAvailableCapacity ?? 0)
            )
        }
        volumes = list
    }
}
