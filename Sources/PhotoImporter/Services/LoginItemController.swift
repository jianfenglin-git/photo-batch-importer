import Foundation
import ServiceManagement
import AppKit

/// Registers (or removes) the bundled card-watcher login item.
///
/// The helper lives at `Contents/Library/LoginItems/PhotoImporterHelper.app`
/// and is the only sandbox-legal route to launch-on-card-insert: it starts at
/// login, watches `NSWorkspace.didMountNotification`, and opens this app when a
/// card appears. See `Sources/PhotoImporterHelper/main.swift`.
///
/// `SMAppService` is the source of truth for whether it's on — there is
/// deliberately nothing persisted here. The user can also flip it in System
/// Settings ▸ General ▸ Login Items, and a local mirror of that state would
/// just drift out of sync with the real setting.
@MainActor
final class LoginItemController: ObservableObject {
    static let helperBundleID = "com.jianfenglin.photoimporter.LoginItemHelper"

    @Published private(set) var status: SMAppService.Status
    /// Set when the last register/unregister failed, for display next to the
    /// toggle. Cleared on the next successful change.
    @Published private(set) var lastError: String?

    private let service: SMAppService
    private let helperIsBundled: Bool

    init() {
        service = SMAppService.loginItem(identifier: Self.helperBundleID)
        status = service.status
        helperIsBundled = FileManager.default.fileExists(
            atPath: Bundle.main.bundleURL
                .appendingPathComponent("Contents/Library/LoginItems")
                .appendingPathComponent("PhotoImporterHelper.app").path
        )
    }

    var isEnabled: Bool { status == .enabled }

    /// True when the helper is actually nested in this bundle — the toggle
    /// hides itself otherwise rather than offering a switch that can only
    /// fail (a dev build assembled without the helper, say).
    ///
    /// Deliberately NOT `status != .notFound`. For a login item, `.notFound`
    /// is what `SMAppService` reports for a helper that is present but has
    /// simply never been registered — which is every first launch. Gating on
    /// it hid the toggle permanently, so the feature could never be turned on.
    var isAvailable: Bool { helperIsBundled }

    /// The user has to approve the background item once, in System Settings.
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = service.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
            } else {
                // `unregister` throws if it was never registered; that's the
                // desired end state anyway, so it isn't worth surfacing.
                try service.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
