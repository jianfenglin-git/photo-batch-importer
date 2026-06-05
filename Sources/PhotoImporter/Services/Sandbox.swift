import Foundation

/// Runtime check for whether the app is running inside the macOS App Sandbox.
/// The Mac App Store build is sandboxed; local dev builds (built via
/// `Scripts/build_app.sh` without the MAS entitlements) are not.
///
/// Used to decide whether reading a removable volume needs an explicit
/// user-granted security-scoped bookmark (sandboxed) or can read the mount
/// path directly (unsandboxed dev builds).
enum Sandbox {
    static var isActive: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }
}
