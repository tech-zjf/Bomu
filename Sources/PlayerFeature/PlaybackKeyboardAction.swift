/// The focused view supplies ownership; this policy never observes global keyboard events.
enum PlaybackKeyboardAction: Equatable {
    enum Key { case escape, space, left, right }
    enum Owner { case playerSurface, playerControl, editingText, systemPresentation, outsidePlayer }

    struct Context {
        var owner: Owner
        var mediaInfoPresented = false
        var failureDetailsPresented = false
        var commandFailurePresented = false
        var isFullScreen = false
        var canTogglePlayback = false
        var canSeek = false
    }

    case dismissMediaInfo, dismissFailureDetails, dismissCommandFailure
    case leaveFullScreen, returnToLibrary, togglePlayback, skipBackward, skipForward
    case consumeRepeat

    static func resolve(_ key: Key, in context: Context,
                        isRepeat: Bool = false, hasModifiers: Bool = false) -> Self? {
        guard !hasModifiers else { return nil }
        switch context.owner {
        case .editingText, .systemPresentation, .outsidePlayer: return nil
        case .playerSurface, .playerControl: break
        }
        if key == .escape {
            // Holding Escape must not dismiss multiple layers or repeatedly toggle full screen.
            if isRepeat { return .consumeRepeat }
            if context.mediaInfoPresented { return .dismissMediaInfo }
            if context.failureDetailsPresented { return .dismissFailureDetails }
            if context.commandFailurePresented { return .dismissCommandFailure }
            if context.isFullScreen { return .leaveFullScreen }
            return .returnToLibrary
        }
        // Buttons, sliders and menus own Space/arrow behavior whenever they have focus.
        guard context.owner == .playerSurface else { return nil }
        switch key {
        case .space:
            guard context.canTogglePlayback else { return nil }
            return isRepeat ? .consumeRepeat : .togglePlayback
        case .left: return context.canSeek ? .skipBackward : nil
        case .right: return context.canSeek ? .skipForward : nil
        case .escape: return nil
        }
    }
}
