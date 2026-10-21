import AppKit

@main struct WindowCheck {
    @MainActor static func main() {
        _ = NSApplication.shared
        let state = PlayerWindow()
        let owner = TestWindow()
        let other = TestWindow()
        let probe = PlayerWindowReader.Probe(state: state)
        owner.contentView?.addSubview(probe)
        precondition(state.window === owner)
        let originalFrame = owner.frame
        state.toggleWindowFullScreen()
        precondition(state.isWindowFullScreen && state.isImmersive && !state.isFullScreen)
        precondition(owner.frame == originalFrame && owner.toggles == 0)
        state.toggleFullScreen()
        precondition(owner.toggles == 1 && other.toggles == 0)
        owner.simulatedFullScreen = true
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: owner)
        precondition(state.isFullScreen)
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: other)
        precondition(state.isFullScreen)
        state.exitFullScreen()
        precondition(owner.toggles == 2)
        owner.simulatedFullScreen = false
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: owner)
        precondition(!state.isFullScreen)
        precondition(state.isWindowFullScreen && state.isImmersive)
        state.showingOptions = true
        state.exitPresentation()
        precondition(!state.showingOptions && state.isWindowFullScreen)
        state.exitFullScreen()
        precondition(owner.toggles == 2)
        state.exitPresentation()
        precondition(!state.isImmersive && !state.isWindowFullScreen)
        state.isFullScreen = true
        state.toggleWindowFullScreen()
        precondition(state.isWindowFullScreen && owner.toggles == 3)
        state.isFullScreen = false
        state.toggleWindowFullScreen()
        precondition(!state.isWindowFullScreen && owner.frame == originalFrame)
        probe.removeFromSuperview()
        precondition(state.window == nil)
        print("Window checks passed: owning window, scoped notifications, enter/exit state, guarded Escape, detach")
    }
}

private final class TestWindow: NSWindow {
    var toggles = 0
    var simulatedFullScreen = false
    override var styleMask: NSWindow.StyleMask {
        get { simulatedFullScreen ? super.styleMask.union(.fullScreen) : super.styleMask }
        set { super.styleMask = newValue }
    }
    override func toggleFullScreen(_ sender: Any?) { toggles += 1 }
}
