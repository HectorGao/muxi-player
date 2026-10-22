import SwiftUI
import MuxiCore

@main struct MuxiPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ViewState private var connection = ConnectionStore()
    @ViewState private var playback = PlaybackController()
    @FocusedValue(\.playerWindow) private var playerWindow
    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.dark.rawValue

    private var appearance: AppearanceMode { AppearanceMode(rawValue: appearanceMode) ?? .dark }

    var body: some Scene {
        WindowGroup("muxi · 幕汐") {
            ContentView(connection: connection, playback: playback)
                .frame(minWidth: 960, minHeight: 640)
                .preferredColorScheme(appearance.colorScheme)
                .tint(Theme.accent)
                .task { delegate.playback = playback; await connection.restore() }
        }
        .defaultSize(width: 1320, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("播放") {
                Button("播放 / 暂停") { playback.togglePause() }.keyboardShortcut(.space, modifiers: [])
                Button("后退 10 秒") { playback.seek(to: playback.position - 10) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("前进 10 秒") { playback.seek(to: playback.position + 10) }.keyboardShortcut(.rightArrow, modifiers: [])
                Divider()
                Button("下一集") { playback.playNext() }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(playback.nextItem == nil)
                Button("停止播放") { Task { await playback.stop() } }.keyboardShortcut(".")
                Divider()
                Button(playerWindow?.isWindowFullScreen == true && playerWindow?.isFullScreen == false ? "退出窗口全屏" : "窗口全屏") {
                    playerWindow?.toggleWindowFullScreen()
                }.keyboardShortcut(.return, modifiers: [.command]).disabled(playerWindow == nil || playback.item == nil)
                Button(playerWindow?.isFullScreen == true ? "退出系统全屏" : "进入系统全屏") {
                    playerWindow?.toggleFullScreen()
                }.keyboardShortcut("f", modifiers: [.command, .control]).disabled(playerWindow == nil)
                Button("退出全屏") { playerWindow?.exitPresentation() }
                    .keyboardShortcut(.escape, modifiers: []).disabled(playerWindow?.isImmersive != true)
            }
            CommandGroup(replacing: .help) {
                Link("项目主页与使用说明", destination: URL(string: "https://github.com/HectorGao/muxi-player")!)
            }
        }
        Settings {
            SettingsView(connection: connection, playback: playback)
                .preferredColorScheme(appearance.colorScheme).tint(Theme.accent)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var playback: PlaybackController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let playback else { return .terminateNow }
        Task { await playback.stop(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
