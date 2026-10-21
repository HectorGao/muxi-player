import Foundation
import Observation
import MuxiCore

@MainActor @Observable final class PlaybackController {
    @ObservationIgnored let engine: MPVEngine?
    var item: MediaItem?
    var plan: PlaybackPlan?
    var sources: [MediaSource] = []
    var mpvTracks: [MPVTrack] = []
    var selectedAudioID: Int?
    var selectedSubtitleID: Int?
    var settings = PlaybackSettings()
    var loading = false
    var isPlaying = false
    var buffering = false
    var networkBytesPerSecond: Double = 0
    var bufferedSeconds: Double = 0
    var position: Double = 0
    var duration: Double = 0
    var speed: Float = 1
    var volume: Float = 1 { didSet { engine?.set("volume", String(volume * 100)) } }
    var error: String?
    var syncError: String?
    var queue: [MediaItem] = []
    var revision = 0
    @ObservationIgnored private var client: EmbyClient?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var reportTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var pendingPause: Bool?
    @ObservationIgnored private var lastReport = Date.distantPast
    @ObservationIgnored private var reportingProgress = false
    @ObservationIgnored private var externalIndices: [Int: Int] = [:]
    @ObservationIgnored private var pendingExternalIndex: Int?
    @ObservationIgnored private var previousExternalIDs: Set<Int> = []

    init(headless: Bool = false) {
        do { engine = try MPVEngine(headless: headless) }
        catch { engine = nil; self.error = error.localizedDescription }
        engine?.onWarning = { [weak self] message in self?.pendingExternalIndex = nil; self?.syncError = message }
        engine?.onLoaded = { [weak self] in self?.didLoad() }
        engine?.onUpdate = { [weak self] in self?.updateTime() }
        engine?.onTracks = { [weak self] in self?.updateTracks() }
        engine?.onEnd = { [weak self] in
            guard let self, self.started else { return }
            self.updateTime(); self.enqueueReport("Stopped")
            self.started = false; self.isPlaying = false; self.revision += 1
        }
        engine?.onFailure = { [weak self] message in
            guard let self, self.item != nil else { return }
            self.stopCurrent(clearPlan: false)
            self.error = message
        }
    }

    var audioTracks: [MPVTrack] { mpvTracks.filter { $0.type == "audio" } }
    var subtitleTracks: [MPVTrack] { mpvTracks.filter { $0.type == "sub" } }
    var externalSubtitles: [MediaStream] { plan?.source.MediaStreams?.filter { $0.Type == "Subtitle" && ($0.IsExternal == true || $0.IsExternalUrl == true || $0.DeliveryMethod == "External") } ?? [] }
    var canConvertVideo: Bool { client?.connection?.user.Policy?.EnableVideoPlaybackTranscoding != false }
    var nextItem: MediaItem? {
        guard let item, let index = queue.firstIndex(where: { $0.id == item.id }), queue.indices.contains(index + 1) else { return nil }
        return queue[index + 1]
    }

    func play(_ item: MediaItem, client: EmbyClient, queue: [MediaItem] = [], fromStart: Bool = false, sourceID: String? = nil) {
        stopCurrent()
        sources = []
        self.queue = queue
        settings = PlaybackSettings()
        load(item: item, client: client, seconds: fromStart ? 0 : Double(item.resumeTicks) / 10_000_000, sourceID: sourceID)
    }

    func changeSettings(_ value: PlaybackSettings) {
        guard let item, let client else { return }
        if value.maxHeight == settings.maxHeight, value.maxBitrate == settings.maxBitrate {
            settings = value
            applyTrackSettings()
            return
        }
        guard canConvertVideo || (value.maxHeight == 0 && value.maxBitrate == 0) else {
            syncError = "此账号未开放视频转码。可以切换已有片源版本，音轨与字幕仍可在本机切换。"; return
        }
        let current = position, sourceID = plan?.source.Id, autoplay = isPlaying
        settings = value
        load(item: item, client: client, seconds: current, sourceID: sourceID, autoplay: autoplay)
    }

    func selectSource(_ id: String) {
        guard let item, let client, id != plan?.source.Id else { return }
        let current = position, autoplay = isPlaying
        settings = PlaybackSettings()
        load(item: item, client: client, seconds: current, sourceID: id, autoplay: autoplay)
    }
    func selectAudio(id: Int) {
        guard let track = audioTracks.first(where: { $0.id == id }) else { return }
        engine?.set("aid", String(id))
        selectedAudioID = id
        if plan?.method == "DirectPlay" { settings.audioIndex = track.streamIndex }
        enqueueReport("Progress")
    }
    func selectSubtitle(id: Int?) {
        guard id == nil || subtitleTracks.contains(where: { $0.id == id }) else { return }
        engine?.set("sid", id.map(String.init) ?? "no")
        selectedSubtitleID = id
        settings.subtitleIndex = id.flatMap { externalIndices[$0] } ?? -1
        if let id, let track = subtitleTracks.first(where: { $0.id == id }), !track.external, plan?.method == "DirectPlay" {
            settings.subtitleIndex = track.streamIndex ?? -1
        }
        enqueueReport("Progress")
    }
    func selectExternalSubtitle(_ stream: MediaStream) {
        guard let client, pendingExternalIndex == nil else { return }
        if let id = externalIndices.first(where: { $0.value == stream.Index })?.key { selectSubtitle(id: id); return }
        do {
            guard let url = try client.externalSubtitleURL(for: stream) else {
                syncError = "服务器未提供此字幕的可访问地址。"; return
            }
            previousExternalIDs = Set(subtitleTracks.filter(\.external).map(\.id))
            pendingExternalIndex = stream.Index
            engine?.command(["sub-add", url.absoluteString, "select", stream.label, stream.Language ?? ""])
        } catch { syncError = EmbyError.message(error) }
    }
    func retry() {
        guard let item, let client else { return }
        load(item: item, client: client, seconds: duration > 0 && position >= duration - 1 ? 0 : position, sourceID: plan?.source.Id)
    }
    func playNext() {
        guard let nextItem, let client else { return }
        play(nextItem, client: client, queue: queue)
    }

    private func load(item: MediaItem, client: EmbyClient, seconds: Double, sourceID: String?, autoplay: Bool = true) {
        stopCurrent()
        guard let engine else { error = "libmpv 播放内核未能初始化，请重新安装完整应用。"; return }
        let currentGeneration = generation
        self.item = item; self.client = client
        position = seconds
        duration = Double(item.RunTimeTicks ?? 0) / 10_000_000
        loading = true; error = nil; syncError = nil
        let requested = settings, pendingStop = reportTask
        loadTask = Task { [weak self] in
            await pendingStop?.value
            guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
            do {
                if self.sources.isEmpty {
                    let detected = try await client.mediaSources(itemID: item.id, engine: .mpv)
                    guard !Task.isCancelled, self.generation == currentGeneration else { return }
                    self.sources = detected
                }
                let plan = try await client.playback(itemID: item.id, settings: requested, sourceID: sourceID, engine: .mpv)
                guard !Task.isCancelled, self.generation == currentGeneration else {
                    if plan.method != "DirectPlay" { try? await client.stopTranscoding(sessionID: plan.sessionID) }
                    return
                }
                self.plan = plan
                engine.set("speed", String(self.speed))
                engine.set("volume", String(self.volume * 100))
                self.pendingPause = !autoplay
                engine.load(url: plan.url, seconds: seconds, paused: !autoplay)
                self.timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled, let self, self.generation == currentGeneration, self.loading else { return }
                    self.stopCurrent(clearPlan: false)
                    self.error = "片源加载超时。请重试或选择其他版本。"
                }
            } catch {
                guard !Task.isCancelled, self.generation == currentGeneration else { return }
                self.loading = false; self.error = EmbyError.message(error)
            }
        }
    }

    private func didLoad() {
        guard loading, plan != nil else { return }
        timeoutTask?.cancel()
        loading = false; started = true
        applyTrackSettings()
        updateTime()
        enqueueReport("")
    }
    private func applyTrackSettings() {
        guard let engine else { return }
        if plan?.method == "DirectPlay" {
            if let index = settings.audioIndex, let track = audioTracks.first(where: { $0.streamIndex == index }) { engine.set("aid", String(track.id)) }
            if settings.subtitleIndex < 0 { engine.set("sid", "no") }
            else if let track = subtitleTracks.first(where: { $0.streamIndex == settings.subtitleIndex && !$0.external }) { engine.set("sid", String(track.id)) }
            else if let stream = externalSubtitles.first(where: { $0.Index == settings.subtitleIndex }) { selectExternalSubtitle(stream) }
        }
        updateTracks()
    }
    private func updateTracks() {
        guard let engine else { return }
        mpvTracks = engine.tracks
        selectedAudioID = engine.selectedAudioID
        selectedSubtitleID = engine.selectedSubtitleID
        if let index = pendingExternalIndex, let id = selectedSubtitleID, !previousExternalIDs.contains(id), subtitleTracks.contains(where: { $0.id == id && $0.external }) {
            externalIndices[id] = index; settings.subtitleIndex = index; pendingExternalIndex = nil
            enqueueReport("Progress")
        }
    }
    private func updateTime() {
        guard started, let engine else { return }
        position = engine.position
        buffering = engine.string("paused-for-cache") == "yes"
        networkBytesPerSecond = engine.number("cache-speed") ?? 0
        bufferedSeconds = engine.number("demuxer-cache-duration") ?? 0
        if engine.duration > 0 { duration = engine.duration }
        if let pendingPause, engine.paused == pendingPause { self.pendingPause = nil }
        isPlaying = !(pendingPause ?? engine.paused) && engine.string("eof-reached") != "yes"
        if selectedAudioID != engine.selectedAudioID || selectedSubtitleID != engine.selectedSubtitleID { updateTracks() }
        if engine.string("eof-reached") == "yes" {
            enqueueReport("Stopped"); started = false; revision += 1
        } else if Date().timeIntervalSince(lastReport) >= 10 { enqueueReport("Progress") }
    }
    func togglePause() {
        guard !loading, plan != nil, let engine else { return }
        if !started || engine.string("eof-reached") == "yes" { retry() }
        else { pendingPause = isPlaying; isPlaying.toggle(); engine.set("pause", isPlaying ? "no" : "yes"); enqueueReport("Progress") }
    }
    func seek(to seconds: Double) {
        guard !loading, started, seconds.isFinite else { return }
        let destination = min(max(0, seconds), max(0, duration))
        engine?.seek(destination); position = destination
        enqueueReport("Progress")
    }
    func setSpeed(_ value: Float) { speed = value; engine?.set("speed", String(value)) }

    private func enqueueReport(_ event: String) {
        guard let item, let plan, let client, started else { return }
        if event == "Progress" { guard !reportingProgress else { return }; reportingProgress = true }
        let ticks = PlaybackTime.ticks(position), paused = pendingPause ?? engine?.paused ?? true
        let settings = settings, previous = reportTask
        lastReport = Date()
        reportTask = Task { [weak self] in
            await previous?.value
            do {
                try await client.report(event, itemID: item.id, plan: plan, ticks: ticks, paused: paused, settings: settings)
                self?.syncError = nil
            } catch { self?.syncError = "观看进度暂未同步：" + EmbyError.message(error) }
            if event == "Progress" { self?.reportingProgress = false }
            if event == "Stopped", plan.method != "DirectPlay" {
                do { try await client.stopTranscoding(sessionID: plan.sessionID) }
                catch { self?.syncError = "服务器未确认结束转码，请检查网络。" }
            }
        }
    }
    private func stopCurrent(clearPlan: Bool = true) {
        loadTask?.cancel(); loadTask = nil
        timeoutTask?.cancel(); timeoutTask = nil
        generation = UUID()
        if started {
            position = engine?.position ?? position
            enqueueReport("Stopped")
        } else if let plan, let client, plan.method != "DirectPlay" {
            let previous = reportTask
            reportTask = Task { await previous?.value; try? await client.stopTranscoding(sessionID: plan.sessionID) }
        }
        started = false; pendingPause = nil; engine?.stop()
        if clearPlan { plan = nil; mpvTracks = []; externalIndices = [:]; pendingExternalIndex = nil }
        isPlaying = false; loading = false; buffering = false
    }
    func stop() async { stopCurrent(); item = nil; revision += 1; await reportTask?.value }
}
