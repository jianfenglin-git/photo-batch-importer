import Foundation
import AppKit

enum EjectError: Error, LocalizedError {
    case systemError(String)
    var errorDescription: String? {
        switch self {
        case .systemError(let m): return m
        }
    }
}

/// Unmount + eject a removable volume. Uses `NSWorkspace` which wraps
/// DiskArbitration properly on macOS — no subprocess required.
enum Eject {
    static func eject(mountPoint: URL) throws {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: mountPoint)
        } catch {
            // NSWorkspace errors are often not user-friendly. If the user
            // can see the card in Finder, it's usually a "resource busy"
            // case (an app has a file open). Forward the system message.
            throw EjectError.systemError(error.localizedDescription)
        }
    }
}
