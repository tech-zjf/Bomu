import XCTest

final class PlaybackKeyboardActionTests: XCTestCase {
    func testEscapeDismissesOneLayerAtATimeBeforeFullscreenAndBrowsing() {
        var context = PlaybackKeyboardAction.Context(owner: .playerControl,
            mediaInfoPresented: true, failureDetailsPresented: true,
            commandFailurePresented: true, isFullScreen: true)
        XCTAssertEqual(PlaybackKeyboardAction.resolve(.escape, in: context), .dismissMediaInfo)
        context.mediaInfoPresented = false
        XCTAssertEqual(PlaybackKeyboardAction.resolve(.escape, in: context), .dismissFailureDetails)
        context.failureDetailsPresented = false
        XCTAssertEqual(PlaybackKeyboardAction.resolve(.escape, in: context), .dismissCommandFailure)
        context.commandFailurePresented = false
        XCTAssertEqual(PlaybackKeyboardAction.resolve(.escape, in: context), .leaveFullScreen)
        context.isFullScreen = false
        XCTAssertEqual(PlaybackKeyboardAction.resolve(.escape, in: context), .returnToLibrary)
    }

    func testTextCompositionSheetsAndHiddenPlayerNeverClaimKeys() {
        for owner in [PlaybackKeyboardAction.Owner.editingText, .systemPresentation, .outsidePlayer] {
            let context = PlaybackKeyboardAction.Context(owner: owner,
                mediaInfoPresented: true, isFullScreen: true, canTogglePlayback: true, canSeek: true)
            for key in [PlaybackKeyboardAction.Key.escape, .space, .left, .right] {
                XCTAssertNil(PlaybackKeyboardAction.resolve(key, in: context))
            }
        }
    }

    func testControlsKeepTheirSpaceAndArrowSemanticsWhileSurfaceControlsPlayback() {
        var context = PlaybackKeyboardAction.Context(owner: .playerControl,
            canTogglePlayback: true, canSeek: true)
        for key in [PlaybackKeyboardAction.Key.space, .left, .right] {
            XCTAssertNil(PlaybackKeyboardAction.resolve(key, in: context))
        }
        context.owner = .playerSurface
        XCTAssertEqual(PlaybackKeyboardAction.resolve(.space, in: context), .togglePlayback)
        XCTAssertEqual(PlaybackKeyboardAction.resolve(.left, in: context), .skipBackward)
        XCTAssertEqual(PlaybackKeyboardAction.resolve(.right, in: context), .skipForward)
        context.canSeek = false
        XCTAssertNil(PlaybackKeyboardAction.resolve(.left, in: context))
        context.canTogglePlayback = false
        XCTAssertNil(PlaybackKeyboardAction.resolve(.space, in: context))
    }

    func testHeldEscapeAndSpaceDoNotRepeatActionsAndModifiedKeysPassThrough() {
        let context = PlaybackKeyboardAction.Context(owner: .playerSurface,
            isFullScreen: true, canTogglePlayback: true, canSeek: true)
        XCTAssertEqual(PlaybackKeyboardAction.resolve(.escape, in: context, isRepeat: true), .consumeRepeat)
        XCTAssertEqual(PlaybackKeyboardAction.resolve(.space, in: context, isRepeat: true), .consumeRepeat)
        XCTAssertEqual(PlaybackKeyboardAction.resolve(.right, in: context, isRepeat: true), .skipForward)
        for key in [PlaybackKeyboardAction.Key.escape, .space, .left, .right] {
            XCTAssertNil(PlaybackKeyboardAction.resolve(key, in: context, hasModifiers: true))
        }
    }
}
