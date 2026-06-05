import SwiftUI
import AppKit

/// NSTextView-backed text editor that exposes the cursor / selection range
/// via a binding. Used by the template section so chip buttons can insert
/// tokens at the user's cursor position.
struct CursorTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange
    /// Called when this editor gains first-responder status. Lets the parent
    /// know which of several editors should receive chip-inserted tokens.
    var onFocus: (() -> Void)? = nil
    var font: NSFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        let text = scroll.documentView as! NSTextView
        text.delegate = context.coordinator
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.font = font
        text.allowsUndo = true
        text.textContainerInset = NSSize(width: 4, height: 4)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let text = scroll.documentView as! NSTextView
        if text.string != self.text {
            // Preserve the user's typing state when we're not the source of
            // change. Only overwrite the buffer when the SwiftUI binding
            // really has a different value (e.g. preset application or chip
            // insertion).
            let range = selectedRange
            text.string = self.text
            let clamped = NSRange(
                location: min(range.location, (self.text as NSString).length),
                length: 0
            )
            text.setSelectedRange(clamped)
        } else if text.selectedRange() != selectedRange {
            text.setSelectedRange(selectedRange)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CursorTextEditor
        init(_ parent: CursorTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            parent.selectedRange = tv.selectedRange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.selectedRange = tv.selectedRange()
            // Selection changes imply the text view is (becoming) the
            // first responder — good signal that the user is editing
            // THIS row, so claim focus for chip routing.
            parent.onFocus?()
        }
    }
}
