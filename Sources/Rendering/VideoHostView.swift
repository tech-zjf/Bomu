import AppKit
import SwiftUI

/// Layout adapter only. The app session, not this representable, owns the native surface.
struct VideoHostView: NSViewRepresentable {
    let surface: NSView
    let isVisible: Bool

    func makeNSView(context: Context) -> NSView { surface }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard context.coordinator.lastVisibility != isVisible else { return }
        context.coordinator.lastVisibility = isVisible
        (nsView as? BMVideoSurface)?.setPresentationVisible(isVisible)
    }

    final class Coordinator {
        var lastVisibility: Bool?
    }
}
