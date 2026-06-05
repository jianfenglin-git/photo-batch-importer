import SwiftUI
import AppKit

@main
struct PhotoImporterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel: AppViewModel

    init() {
        _viewModel = StateObject(wrappedValue: AppViewModel.makeDefault())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 600, minHeight: 560)
                .background(WindowAccessor { window in
                    // Device-local frame persistence: NSWindow's autosave
                    // writes to UserDefaults (not iCloud), so each Mac
                    // remembers its own size. `.defaultSize` only governs
                    // the very first launch before any frame has been saved.
                    window.setFrameAutosaveName("MainWindow")
                })
        }
        .defaultSize(width: 750, height: 1000)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

/// Treat Photo Importer as a single-window document-less app: when the user
/// closes the last window, the process exits. Without this, SwiftUI's default
/// macOS behavior keeps the app alive with no visible window, requiring
/// ⌘Q to fully quit — confusing for a utility-style app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Bridge for grabbing the underlying `NSWindow` that hosts a SwiftUI view.
/// Runs the `onWindow` closure exactly once, when the view first attaches.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let win = view.window {
                onWindow(win)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
