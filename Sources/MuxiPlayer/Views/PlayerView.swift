import SwiftUI
import MuxiCore

struct PlayerView: View {
    @Bindable var playback: PlaybackController
    @Bindable var window: PlayerWindow
    let exit: () -> Void
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @ViewState private var scrubbing = false
    @ViewState private var seekPosition = 0.0
    @ViewState private var controlsHovered = false
    @ViewState private var controlsVisible = true
    @ViewState private var keyboardInteracting = false
    @ViewState private var lastInteraction = Date()
    private var showControls: Bool {
        controlsVisible || !playback.isPlaying || controlsHovered || window.showingOptions || scrubbing || keyboardInteracting || voiceOverEnabled
    }

    var body: some View {
        if playback.item == nil {
            ContentUnavailableView("挑一部，开始放映", systemImage: "play.rectangle",
                                   description: Text("从左侧媒体库选择电影或剧集。播放时可在下方切换字幕、音轨和画质。"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if let engine = playback.engine { MPVVideo(engine: engine) }
                    if playback.loading || playback.buffering {
                        VStack(spacing: 14) {
                            ProgressView()
                            Text(playback.loading ? "正在准备播放…" : "正在缓冲…").font(.callout)
                            if playback.buffering {
                                Text(String(format: "接收 %.1f Mbps · 已缓冲约 %.1f 秒", playback.networkBytesPerSecond * 8 / 1_000_000, playback.bufferedSeconds))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(playback.canConvertVideo ? "可调低码率，或选择较小片源版本。" : "此源未开放转码。请选择较小版本，或暂停等待缓冲；本机降画质无法减少下载带宽。")
                                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 360).multilineTextAlignment(.center)
                            }
                        }
                            .padding(25).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let error = playback.error {
                        VStack(spacing: 16) {
                            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(Theme.accent)
                            Text(error).multilineTextAlignment(.center).frame(maxWidth: 440)
                            HStack {
                                Button("重试") { playback.retry() }
                                if playback.settings.requiresServerConversion(engine: .mpv) {
                                    Button("恢复原始播放") { playback.changeSettings(PlaybackSettings()) }
                                } else if playback.canConvertVideo {
                                    Button("尝试兼容画质") {
                                        var settings = playback.settings
                                        settings.maxHeight = 1080
                                        settings.maxBitrate = 10_000_000
                                        playback.changeSettings(settings)
                                    }
                                }
                            }
                        }.padding(32).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { window.toggleFullScreen() }
                    .overlay(alignment: .topLeading) {
                        Button(action: exit) { Label("退出播放", systemImage: "xmark").padding(10) }
                            .buttonStyle(.plain).background(.regularMaterial, in: Capsule())
                            .environment(\.colorScheme, .dark).padding(20)
                            .help("停止下载并保存进度，返回媒体库（⌘.）")
                            .opacity(!window.isImmersive || showControls ? 1 : 0)
                            .allowsHitTesting(!window.isImmersive || showControls)
                            .accessibilityHidden(window.isImmersive && !showControls)
                    }
                    .overlay(alignment: .bottom) {
                        if window.isImmersive {
                            transport
                                .environment(\.colorScheme, .dark)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .padding(24)
                                .opacity(showControls ? 1 : 0)
                                .allowsHitTesting(showControls)
                                .onHover { controlsHovered = $0; lastInteraction = Date() }
                        }
                    }
                if !window.isImmersive {
                    transport
                    Divider().opacity(0.35)
                    options
                }
            }
            .onContinuousHover { phase in
                if case .active = phase {
                    keyboardInteracting = false
                    controlsVisible = true
                    lastInteraction = Date()
                }
            }
            .onKeyPress { _ in keyboardInteracting = true; return .ignored }
            .task(id: lastInteraction) {
                guard window.isImmersive else { return }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                controlsVisible = false
            }
            .onChange(of: window.isImmersive) { _, _ in
                window.showingOptions = false
                controlsVisible = true
                lastInteraction = Date()
            }
            .onExitCommand {
                window.exitPresentation()
            }
        }
    }

    private var transport: some View {
        VStack(spacing: 15) {
            Slider(value: Binding(get: { scrubbing ? seekPosition : playback.position }, set: { seekPosition = $0 }),
                   in: 0...max(playback.duration, 1), onEditingChanged: { editing in
                scrubbing = editing
                if !editing { playback.seek(to: seekPosition) }
            }).accessibilityLabel("播放进度").disabled(playback.loading || playback.duration <= 0)
            HStack(spacing: 12) {
                Group {
                    Text("\(PlaybackTime.label(scrubbing ? seekPosition : playback.position)) / \(PlaybackTime.label(playback.duration))")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
                    Spacer(minLength: 0)
                    control("后退 10 秒", symbol: "gobackward.10") { playback.seek(to: playback.position - 10) }
                    Button { playback.togglePause() } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 28)).frame(width: 35, height: 32)
                    }.help("播放 / 暂停（空格）").accessibilityLabel(playback.isPlaying ? "暂停" : "播放")
                    control("前进 10 秒", symbol: "goforward.10") { playback.seek(to: playback.position + 10) }
                    if playback.nextItem != nil { control("下一集", symbol: "forward.end.fill") { playback.playNext() } }
                    Spacer(minLength: 0)
                    HStack(spacing: 7) {
                        Button { playback.volume = playback.volume > 0 ? 0 : 1 } label: { Image(systemName: playback.volume > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill") }.help("静音 / 恢复音量")
                        Slider(value: $playback.volume, in: 0...1).frame(width: 60).accessibilityLabel("音量")
                    }
                    Menu {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                            Button("\(rate.formatted())×") { playback.setSpeed(Float(rate)) }
                        }
                    } label: { Text("\(Double(playback.speed).formatted())×").monospacedDigit() }
                        .menuStyle(.borderlessButton).frame(width: 44).help("播放速度")
                }.disabled(playback.loading)
                if window.isImmersive {
                    control("音轨、字幕与画质", symbol: "slider.horizontal.3") { window.showingOptions.toggle() }
                        .popover(isPresented: $window.showingOptions) { options.frame(width: 850).environment(\.colorScheme, .dark) }
                }
                HStack(spacing: 8) {
                    displayModeButton(window.isWindowFullScreen && !window.isFullScreen ? "退出窗口全屏" : "窗口全屏",
                                      caption: "窗口全屏", symbol: "rectangle.inset.filled",
                                      active: window.isWindowFullScreen && !window.isFullScreen) { window.toggleWindowFullScreen() }
                        .help("窗口全屏（⌘↩）：视频铺满当前窗口；再次点击恢复媒体库布局。")
                    displayModeButton(window.isFullScreen ? "退出系统全屏" : "进入系统全屏",
                                      caption: "系统全屏",
                                      symbol: window.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                      active: window.isFullScreen) { window.toggleFullScreen() }
                        .help("系统全屏（⌃⌘F）：进入或退出 macOS 独立全屏空间。")
                }
            }.buttonStyle(.plain)
        }.padding(.horizontal, 26).padding(.vertical, 20).background(window.isImmersive ? Color.black.opacity(0.78) : Theme.canvas)
    }

    private func displayModeButton(_ title: String, caption: String, symbol: String, active: Bool,
                                   action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 18)).frame(height: 22)
                Text(caption).font(.system(size: 10)).fixedSize()
            }.frame(width: 52, height: 42)
                .foregroundStyle(active ? Theme.accent : Color.primary)
                .background(active ? Theme.accent.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }.accessibilityLabel(title).accessibilityValue(active ? "开启" : "关闭")
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 20) {
                optionMenu("版本", value: playback.plan?.source.Name ?? "自动选择") {
                    ForEach(playback.sources) { source in
                        choice(source.playbackLabel, selected: source.Id == playback.plan?.source.Id) { playback.selectSource(source.Id) }
                    }
                }.frame(maxWidth: 420).disabled(playback.loading || playback.sources.isEmpty)
                Text(sourceDescription).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                Label("libmpv", systemImage: "play.rectangle").font(.caption).foregroundStyle(Theme.accent)
                    .help("与 IINA 同源的开源播放内核，在本机解码视频、音轨和字幕")
            }
            HStack(spacing: 20) {
                optionMenu("字幕", value: subtitleLabel) {
                    choice("关闭", selected: playback.selectedSubtitleID == nil) { playback.selectSubtitle(id: nil) }
                    ForEach(playback.subtitleTracks) { track in
                        choice(track.label, selected: playback.selectedSubtitleID == track.id) { playback.selectSubtitle(id: track.id) }
                    }
                    if !playback.externalSubtitles.isEmpty {
                        Divider()
                        ForEach(playback.externalSubtitles) { stream in
                            Button("外挂 · " + stream.label) { playback.selectExternalSubtitle(stream) }
                        }
                    }
                }
                Divider().frame(height: 24)
                optionMenu("音轨", value: audioLabel) {
                    ForEach(playback.audioTracks) { track in
                        choice(track.label, selected: playback.selectedAudioID == track.id) { playback.selectAudio(id: track.id) }
                    }
                }
                Divider().frame(height: 24)
                optionMenu("分辨率", value: playback.settings.maxHeight == 0 ? "原始" : "\(playback.settings.maxHeight)p") {
                    ForEach(PlaybackSettings.resolutions, id: \.self) { height in
                        choice(height == 0 ? "原始" : "\(height)p", selected: playback.settings.maxHeight == height) { change { $0.maxHeight = height } }.disabled(height > 0 && !playback.canConvertVideo)
                    }
                }
                Divider().frame(height: 24)
                optionMenu("码率", value: playback.settings.maxBitrate == 0 ? "原始" : "\(playback.settings.maxBitrate / 1_000_000) Mbps") {
                    ForEach(PlaybackSettings.bitrates, id: \.self) { bitrate in
                        choice(bitrate == 0 ? "原始" : "\(bitrate / 1_000_000) Mbps", selected: playback.settings.maxBitrate == bitrate) { change { $0.maxBitrate = bitrate } }.disabled(bitrate > 0 && !playback.canConvertVideo)
                    }
                }
            }.disabled(playback.loading || playback.plan == nil)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                Text(playback.syncError ?? (playback.canConvertVideo ? "低带宽时可降低码率与分辨率，由服务器转换后传输；切换画质或片源版本会保留位置。" : "此账号未开放转码。低带宽请选较小片源版本，或暂停等待缓冲；本机降画质不能减少原片下载量。"))
                Spacer(minLength: 0)
                if let plan = playback.plan {
                    Text(plan.method == "DirectPlay" ? "直接播放" : plan.method == "DirectStream" ? "转封装" : "服务器转码")
                        .foregroundStyle(Theme.accent)
                }
            }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if playback.plan != nil, !playback.loading {
                Text(String(format: "接收 %.1f Mbps · 缓存 %.1f 秒 · %@ · 累计丢帧 %d", playback.networkBytesPerSecond * 8 / 1_000_000, playback.bufferedSeconds, playback.decoding, playback.droppedFrames))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .help("缓存耗尽时需等待网络；丢帧还可能来自解码、渲染或跳转，不能单凭累计数判断网络速度。")
            }
        }.padding(.horizontal, 26).padding(.top, 24).padding(.bottom, 28).background(Theme.surface)
    }

    private var subtitleLabel: String { playback.subtitleTracks.first { $0.id == playback.selectedSubtitleID }?.label ?? "关闭" }
    private var audioLabel: String { playback.audioTracks.first { $0.id == playback.selectedAudioID }?.label ?? "正在识别" }
    private var sourceDescription: String {
        guard let source = playback.plan?.source else { return "自动识别片源编码和轨道" }
        let video = source.MediaStreams?.first { $0.Type == "Video" }
        return [source.Container?.uppercased(), video?.Codec?.uppercased(), video?.Height.map { "\($0)p" },
                source.Bitrate.map { String(format: "%.1f Mbps", Double($0) / 1_000_000) }].compactMap { $0 }.joined(separator: " · ")
    }

    private func change(_ update: (inout PlaybackSettings) -> Void) {
        var value = playback.settings
        update(&value)
        if value != playback.settings { playback.changeSettings(value) }
    }

    private func control(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 20)).frame(minWidth: 24, minHeight: 28) }.help(title).accessibilityLabel(title)
    }

    private func optionMenu<Items: View>(_ title: String, value: String, @ViewBuilder items: () -> Items) -> some View {
        HStack(spacing: 10) {
            Text(title + ":").foregroundStyle(.secondary).fixedSize()
            Menu(content: items) {
                HStack { Text(value).lineLimit(1); Spacer(minLength: 4); Image(systemName: "chevron.down").font(.caption2) }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10).frame(height: 34)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 5))
                    .overlay { RoundedRectangle(cornerRadius: 5).stroke(Theme.border) }
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).accessibilityLabel(title).accessibilityValue(value).help(value)
        }.font(.system(size: 13)).frame(maxWidth: .infinity)
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { if selected { Label(title, systemImage: "checkmark") } else { Text(title) } }
    }
}
