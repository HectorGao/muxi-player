import SwiftUI
import Sparkle
import Combine

@MainActor final class AppUpdater: ObservableObject {
    let controller: SPUStandardUpdaterController
    @Published private(set) var canCheck = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyDownloads = false
    private var started = false

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).assign(to: &$canCheck)
        updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: RunLoop.main).assign(to: &$automaticallyChecks)
        updater.publisher(for: \.automaticallyDownloadsUpdates).receive(on: RunLoop.main).assign(to: &$automaticallyDownloads)
    }
    func start() {
        guard !started, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        started = true
        controller.startUpdater()
    }
    func check() { controller.checkForUpdates(nil) }
    func setAutomaticChecks(_ value: Bool) { controller.updater.automaticallyChecksForUpdates = value }
    func setAutomaticDownloads(_ value: Bool) { controller.updater.automaticallyDownloadsUpdates = value }
}

struct UpdateSettingsView: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        Section("软件更新") {
            Toggle("自动检查 GitHub 新版本", isOn: Binding(get: { updater.automaticallyChecks }, set: updater.setAutomaticChecks))
            Toggle("自动下载并在退出后安装", isOn: Binding(get: { updater.automaticallyDownloads }, set: updater.setAutomaticDownloads))
                .disabled(!updater.automaticallyChecks)
            Button("检查更新…", action: updater.check).disabled(!updater.canCheck)
            Text("每天检查已发布的版本（含预览版），验证签名后下载；退出 muxi 时安装，保留媒体源与设置。代码提交不会直接触发安装。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
