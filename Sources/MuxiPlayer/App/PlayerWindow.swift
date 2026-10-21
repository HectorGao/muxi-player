import SwiftUI

private struct PlayerWindowKey: FocusedValueKey { typealias Value = PlayerWindow }
extension FocusedValues {
    var playerWindow: PlayerWindow? {
        get { self[PlayerWindowKey.self] }
        set { self[PlayerWindowKey.self] = newValue }
    }
}

@MainActor @Observable final class PlayerWindow {
    @ObservationIgnored weak var window: NSWindow?
    var isFullScreen = false
    var isWindowFullScreen = false
    var showingOptions = false
    var isImmersive: Bool { isFullScreen || isWindowFullScreen }

    func toggleFullScreen() { window?.toggleFullScreen(nil) }
    func toggleWindowFullScreen() {
        if isFullScreen {
            isWindowFullScreen = true
            toggleFullScreen()
        } else {
            isWindowFullScreen.toggle()
        }
    }
    func exitPresentation() {
        if showingOptions { showingOptions = false }
        else if isFullScreen { exitFullScreen() }
        else { isWindowFullScreen = false }
    }
    func exitFullScreen() {
        if isFullScreen { toggleFullScreen() }
    }
}

// Observe the owning window without replacing SwiftUI's window delegate.
struct PlayerWindowReader: NSViewRepresentable {
    let state: PlayerWindow

    func makeNSView(context: Context) -> Probe { Probe(state: state) }
    func updateNSView(_ view: Probe, context: Context) {}

    final class Probe: NSView {
        let state: PlayerWindow
        private var escapeMonitor: Any?
        init(state: PlayerWindow) { self.state = state; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            escapeMonitor = nil
            state.window = window
            if let window {
                // SwiftUI's exit command can miss Escape when the video owns focus.
                escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, event.window === self.window, event.keyCode == 53,
                          self.state.isImmersive else { return event }
                    self.state.exitPresentation()
                    return nil
                }
                for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(sync), name: name, object: window)
                }
            }
            DispatchQueue.main.async { [weak self] in self?.sync() }
        }

        @objc private func sync() { state.isFullScreen = window?.styleMask.contains(.fullScreen) == true }
        deinit {
            NotificationCenter.default.removeObserver(self)
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        }
    }
}
