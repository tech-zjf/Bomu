import AppKit
import SwiftUI

/// Layout adapter only. The app session, not this representable, owns the native surface.
struct VideoHostView: NSViewRepresentable {
    let surface: NSView

    func makeNSView(context: Context) -> NSView { surface }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
