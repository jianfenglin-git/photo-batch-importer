import AppKit
import Foundation

// Background login item for Photo Batch Importer.
//
// Why this exists: the App Sandbox offers no way for the main app to be
// launched when a card is inserted. `NSWorkspace.didMountNotification` only
// reaches a process that is *already running*, and a launchd agent with
// `StartOnMount` would have to be written to ~/Library/LaunchAgents, which the
// sandbox forbids. A login item, however, is explicitly sanctioned in the Mac
// App Store: this tiny agent starts at login, sits idle observing mount
// notifications, and opens the main app when a card shows up.
//
// It is registered/unregistered from the main app via SMAppService
// (`LoginItemController`), so the user just flips a switch — no Terminal, no
// files to install by hand.
//
// Sandboxed, LSUIElement, no windows, no network. The only thing it ever does
// is call `NSWorkspace.openApplication` on its own containing app bundle.

@MainActor
final class CardWatchHelper: NSObject, NSApplicationDelegate {
    private static let mainAppBundleID = "com.jianfenglin.photoimporter"

    private var observer: NSObjectProtocol?

    /// One physical card can mount more than one volume (multi-partition
    /// cards, or a card plus its EFI-ish companion), firing `didMount` once
    /// per volume a few milliseconds apart. Without coalescing that opens —
    /// or at least re-activates — the app several times in a row.
    private var lastOpen = Date.distantPast
    private let coalesceWindow: TimeInterval = 3

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Deliberately does NOT scan already-mounted volumes at startup. This
        // process starts at login, and a card left sitting in the reader would
        // otherwise pop the app open on every single login — which reads as a
        // misbehaving app, not a feature. Only *new* mounts count.
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            Task { @MainActor in self?.handleMount(note) }
        }
        NSLog("[PhotoImporterHelper] watching for card mounts")
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Mount handling

    private func handleMount(_ note: Notification) {
        guard let volume = Self.volumeURL(from: note) else { return }
        guard Self.isRemovableVolume(volume) else { return }

        switch Self.photoFolderVerdict(volume) {
        case .hasPhotos, .undetermined:
            // `.undetermined` means the sandbox refused to tell us whether
            // there's a DCIM folder. Erring toward opening is the right call:
            // a spurious launch is a mild annoyance, a card that silently
            // fails to trigger the feature makes the feature look broken.
            break
        case .noPhotos:
            NSLog("[PhotoImporterHelper] ignoring %@ — no DCIM", volume.lastPathComponent)
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastOpen) > coalesceWindow else { return }
        lastOpen = now
        openMainApp(for: volume)
    }

    private static func volumeURL(from note: Notification) -> URL? {
        if let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
            return url
        }
        // Pre-10.13 key, still populated on current systems.
        if let path = note.userInfo?["NSDevicePath"] as? String {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Same predicate `VolumeWatcher` uses in the main app, kept deliberately
    /// identical: a volume this helper opens the app for should be a volume
    /// the app then actually lists.
    private static func isRemovableVolume(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIsRemovableKey, .volumeIsInternalKey]
        let values = try? url.resourceValues(forKeys: keys)
        let isRemovable = values?.volumeIsRemovable ?? false
        let isInternal = values?.volumeIsInternal ?? false
        return isRemovable || (url.path.hasPrefix("/Volumes/") && !isInternal)
    }

    enum PhotoFolderVerdict {
        case hasPhotos
        case noPhotos
        /// We were not allowed to look. Not the same as "there are none".
        case undetermined
    }

    /// Best-effort check for a camera card, so plugging in a backup drive or a
    /// USB stick doesn't open a photo importer.
    ///
    /// The subtlety: `fileExists` returns false both for "no such folder" and
    /// for "the sandbox denied me the answer", which demand opposite responses.
    ///
    /// Measured behaviour of a sandboxed agent with no file entitlements at
    /// all: `fileExists(atPath:)` on a removable volume **succeeds**, while
    /// `contentsOfDirectory` on the same volume **fails**. So enumeration is
    /// the wrong probe — it fails even when we can see the card perfectly
    /// well, and using it made every non-camera volume look "undetermined".
    ///
    /// Probing the volume root with the same call that answered the question
    /// is the honest disambiguation: a denial hides the whole volume, whereas
    /// a card without photos hides only the one name.
    private static func photoFolderVerdict(_ volume: URL) -> PhotoFolderVerdict {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: volume.appendingPathComponent("DCIM").path, isDirectory: &isDir) {
            return isDir.boolValue ? .hasPhotos : .noPhotos
        }
        return fm.fileExists(atPath: volume.path) ? .noPhotos : .undetermined
    }

    // MARK: - Launching the app

    private func openMainApp(for volume: URL) {
        guard let appURL = Self.mainAppURL() else {
            NSLog("[PhotoImporterHelper] cannot locate the main app bundle")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSLog("[PhotoImporterHelper] opening app for %@", volume.lastPathComponent)
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
            if let error {
                NSLog("[PhotoImporterHelper] open failed: %@", error.localizedDescription)
            }
        }
    }

    /// This helper lives at
    ///   Photo Batch Importer.app/Contents/Library/LoginItems/PhotoImporterHelper.app
    /// so the app it belongs to is four directories up. Walking the bundle
    /// beats a LaunchServices lookup as the primary path: it opens *the copy
    /// that installed this helper*, not whichever build LaunchServices happens
    /// to have registered for the bundle id (a stale build/ copy, say).
    private static func mainAppURL() -> URL? {
        let containing = Bundle.main.bundleURL
            .deletingLastPathComponent()   // LoginItems
            .deletingLastPathComponent()   // Library
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()   // <main>.app
        if containing.pathExtension == "app",
           FileManager.default.fileExists(atPath: containing.path) {
            return containing
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: mainAppBundleID)
    }
}

// Top-level code in main.swift is not actor-isolated, but it does run on the
// main thread, so asserting that is sound. The `delegate` local must outlive
// the setup because NSApplication holds its delegate weakly — keeping `run()`
// inside the same scope is what retains it.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = CardWatchHelper()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
