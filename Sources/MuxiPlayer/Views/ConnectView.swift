import SwiftUI
import MuxiCore

struct ConnectView: View {
    @Bindable var connection: ConnectionStore
    @ViewState private var address = ""
    @ViewState private var username = ""
    @ViewState private var password = ""
    @ViewState private var serverKind = MediaServerKind.emby
    @ViewState private var clientIdentity = EmbyClientIdentity.senPlayer
    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.dark.rawValue
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            HStack(spacing: 70) {
                VStack(alignment: .leading, spacing: 22) {
                    if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                       let icon = NSImage(contentsOf: url) {
                        Image(nsImage: icon).resizable().interpolation(.high)
                            .frame(width: 80, height: 80).accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("muxi").font(.system(size: 64, weight: .semibold, design: .rounded)).tracking(-3)
                        Text("幕汐").font(.title3).tracking(6).foregroundStyle(.secondary)
                    }
                    Text("播放器 · 私人影视库").font(.title3).foregroundStyle(.secondary)
                    Text("连接 Emby 或 Jellyfin，\n在一面海报墙里发现下一部好片。")
                        .font(.body).foregroundStyle(.secondary).lineSpacing(8).padding(.top, 12)
                    Spacer().frame(height: 26)
                    HStack(spacing: 18) {
                        Label("原生 macOS", systemImage: "macwindow")
                        Label("免费开源", systemImage: "curlybraces")
                    }.font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("外观").font(.caption).foregroundStyle(.secondary)
                        Picker("外观", selection: $appearanceMode) {
                            ForEach(AppearanceMode.allCases, id: \.rawValue) { mode in Text(mode.label).tag(mode.rawValue) }
                        }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("appearance-mode")
                    }.padding(.top, 18)
                }.frame(width: 300, alignment: .leading)
                VStack(alignment: .leading, spacing: 20) {
                    Text("连接 \(serverKind.label)").font(.title2.weight(.semibold))
                    Text("输入服务器地址和你的 \(serverKind.label) 账号。").foregroundStyle(.secondary)
                    Picker("服务器类型", selection: $serverKind) {
                        ForEach(MediaServerKind.allCases, id: \.self) { kind in Text(kind.label).tag(kind) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("server-kind")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("服务器地址").font(.callout)
                        TextField(serverKind == .emby ? "https://emby.example.com" : "https://jellyfin.example.com", text: $address).focused($focused)
                            .textContentType(.URL).accessibilityIdentifier("server-address")
                        Text("支持端口和反向代理路径，例如 /\(serverKind.rawValue)。").font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("用户名").font(.callout)
                        TextField("\(serverKind.label) 用户名", text: $username).textContentType(.username).accessibilityIdentifier("username")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("密码").font(.callout)
                        SecureField("\(serverKind.label) 密码", text: $password).textContentType(.password).accessibilityIdentifier("password")
                    }
                    if serverKind == .emby {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("客户端标识", selection: $clientIdentity) {
                                ForEach(EmbyClientIdentity.allCases, id: \.self) { identity in
                                    Text(identity.label).tag(identity)
                                }
                            }.accessibilityIdentifier("client-identity")
                            if clientIdentity != .muxi {
                                Text("使用 \(clientIdentity.rawValue) 兼容标识连接；若受限，可按服务商说明切换。").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if address.lowercased().hasPrefix("http://") {
                        Label("HTTP 连接不加密，请只在可信网络使用。", systemImage: "lock.open")
                            .font(.caption).foregroundStyle(Theme.accent)
                    }
                    if let error = connection.error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                    Button(action: connect) {
                        HStack { Spacer(); if connection.connecting { ProgressView().controlSize(.small) }; Text(connection.connecting ? "正在连接…" : "连接媒体库"); Spacer() }
                            .padding(.vertical, 5)
                    }.buttonStyle(.borderedProminent).disabled(connection.connecting || address.isEmpty || username.isEmpty)
                        .keyboardShortcut(.defaultAction)
                    Label("登录令牌保存在 macOS 钥匙串，密码不会保存。", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.textFieldStyle(.roundedBorder).controlSize(.large).frame(width: 365).disabled(connection.connecting)
                    .padding(26).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                    .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(Theme.border, lineWidth: 1) }
            }.padding(.horizontal, 48).padding(.vertical, 40).frame(maxWidth: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.canvas)
            .onSubmit(connect).onAppear { focused = true }
            .onChange(of: serverKind) { _, _ in connection.error = nil }
    }

    private func connect() {
        guard !connection.connecting, !address.isEmpty, !username.isEmpty else { return }
        Task {
            await connection.connect(address: address, username: username, password: password, clientIdentity: clientIdentity, serverKind: serverKind)
            if connection.connection != nil { password = "" }
        }
    }
}

struct SettingsView: View {
    @Bindable var connection: ConnectionStore
    let playback: PlaybackController
    @ViewState private var disconnecting = false
    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.dark.rawValue
    @AppStorage("ambientMotion") private var ambientMotion = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Form {
            Section("muxi · 幕汐") {
                Text("播放器与私人影视库。免费、开源，连接你的 Emby / Jellyfin 媒体收藏。")
                LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "MuxiReleaseVersion") as? String ?? "开发版")
                Link("GitHub · HectorGao/muxi-player", destination: URL(string: "https://github.com/HectorGao/muxi-player")!)
            }
            Section("外观") {
                Picker("主题", selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.rawValue) { mode in Text(mode.label).tag(mode.rawValue) }
                }.pickerStyle(.segmented).accessibilityIdentifier("appearance-mode")
                Toggle("动态毛玻璃背景", isOn: $ambientMotion).accessibilityIdentifier("ambient-motion")
                Text(reduceMotion ? "系统已开启“减少动态效果”，背景保持静止。" : "播放时背景保持静止，并遵循系统“减少动态效果”设置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let current = connection.connection {
                Section("当前连接") {
                    LabeledContent("类型", value: (current.serverKind ?? .emby).label)
                    LabeledContent("服务器", value: current.baseURL.absoluteString)
                    LabeledContent("账号", value: current.user.Name)
                    LabeledContent("客户端标识", value: (current.serverKind == .jellyfin ? EmbyClientIdentity.muxi : current.clientIdentity ?? .muxi).rawValue)
                    Button(disconnecting ? "正在断开…" : "断开连接并移除本机登录", role: .destructive) {
                        disconnecting = true
                        Task { await playback.stop(); await connection.disconnect(); disconnecting = false }
                    }.disabled(disconnecting)
                }
            }
            if let error = connection.error { Text(error).foregroundStyle(.red) }
            Section("播放兼容性") {
                Text("libmpv 在本机播放并切换音轨、字幕；降低分辨率或码率仍需服务器允许转码。")
                Text("当前支持一个已保存的 Emby 或 Jellyfin 连接。连接新的服务器前请先断开。")
            }.foregroundStyle(.secondary)
        }.formStyle(.grouped).frame(width: 540, height: 560)
    }
}
