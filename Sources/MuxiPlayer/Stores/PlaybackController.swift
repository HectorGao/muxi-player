import Foundation
import Observation
import MuxiCore
import CryptoKit

struct RecentPlayback: Codable {
    var item: MediaItem
    let baseURL: URL
    let userID: String
    let serverKind: MediaServerKind
    var position: Double
    var duration: Double
    var sourceID: String?
    var settings: PlaybackSettings

    func belongs(to client: EmbyClient) -> Bool {
        baseURL == client.baseURL && userID == client.connection?.user.Id && serverKind == client.serverKind
    }
}

struct OnlineResume: Codable {
    let entry: OnlineItem
    var route: Int
    var episode: Int
    var routeName: String?
    var episodeName: String?
    var position: Double
    var duration: Double
    var settings: PlaybackSettings
}

struct PlaybackHistoryEntry: Codable, Identifiable {
    let id: String
    let watchedAt: Date
    let recent: RecentPlayback?
    let online: OnlineResume?
    var title: String { recent?.item.Name ?? online?.entry.media.Name ?? "影片" }
    var position: Double { recent?.position ?? online?.position ?? 0 }
}

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
    var decoding = "正在识别"
    var droppedFrames = 0
    var position: Double = 0
    var duration: Double = 0
    var speed: Float = 1
    var volume: Float = 1 { didSet { engine?.set("volume", String(volume * 100)) } }
    var error: String?
    var syncError: String?
    var queue: [MediaItem] = []
    var revision = 0
    private(set) var recent: RecentPlayback?
    private(set) var onlineRecent: OnlineResume?
    private(set) var onlineMostRecent = false
    private(set) var history: [PlaybackHistoryEntry] = []
    @ObservationIgnored private var onlineCurrent: OnlineResume?
    @ObservationIgnored private var onlineSource: OnlineSource?
    @ObservationIgnored private var onlineRoutes: [OnlineRoute] = []
    @ObservationIgnored private let onlineClient: OnlineCatalogClient
    @ObservationIgnored private var recentQueue: [MediaItem] = []
    @ObservationIgnored private var client: EmbyClient?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var reportTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var pendingPause: Bool?
    @ObservationIgnored private var pendingSeek: Double?
    @ObservationIgnored private var lastReport = Date.distantPast
    @ObservationIgnored private var reportingProgress = false
    @ObservationIgnored private var externalIndices: [Int: Int] = [:]
    @ObservationIgnored private var pendingExternalIndex: Int?
    @ObservationIgnored private var previousExternalIDs: Set<Int> = []
    @ObservationIgnored private let resumeDefaults: UserDefaults

    init(headless: Bool = false, resumeDefaults: UserDefaults = .standard, onlineClient: OnlineCatalogClient = OnlineCatalogClient()) {
        self.resumeDefaults = resumeDefaults
        self.onlineClient = onlineClient
        if let data = resumeDefaults.data(forKey: "recentPlayback") { recent = try? JSONDecoder().decode(RecentPlayback.self, from: data) }
        if let data = resumeDefaults.data(forKey: "onlineRecentPlayback") { onlineRecent = try? JSONDecoder().decode(OnlineResume.self, from: data) }
        onlineMostRecent = resumeDefaults.bool(forKey: "onlineMostRecent")
        if let data = resumeDefaults.data(forKey: "playbackHistory") {
            history = (try? JSONDecoder().decode([PlaybackHistoryEntry].self, from: data)) ?? []
        }
        do { engine = try MPVEngine(headless: headless) }
        catch { engine = nil; self.error = error.localizedDescription }
        if resumeDefaults.data(forKey: "playbackHistory") == nil {
            if let onlineRecent, !onlineMostRecent { recordHistory(recent: nil, online: onlineRecent) }
            if let recent { recordHistory(recent: recent, online: nil) }
            if let onlineRecent, onlineMostRecent { recordHistory(recent: nil, online: onlineRecent) }
        }
        engine?.onWarning = { [weak self] message in self?.pendingExternalIndex = nil; self?.pendingSeek = nil; self?.syncError = message }
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
    var canConvertVideo: Bool { client != nil && client?.connection?.user.Policy?.EnableVideoPlaybackTranscoding != false }
    var isOnlinePlayback: Bool { onlineCurrent != nil }
    var canPlayNext: Bool {
        if nextItem != nil { return true }
        guard let current = onlineCurrent, onlineRoutes.indices.contains(current.route) else { return false }
        return onlineRoutes[current.route].episodes.indices.contains(current.episode + 1)
    }
    var nextItem: MediaItem? {
        guard let item, let index = queue.firstIndex(where: { $0.id == item.id }), queue.indices.contains(index + 1) else { return nil }
        return queue[index + 1]
    }

    func play(_ item: MediaItem, client: EmbyClient, queue: [MediaItem] = [], fromStart: Bool = false, sourceID: String? = nil) {
        stopCurrent()
        sources = []
        self.queue = queue
        settings = PlaybackSettings()
        let pending = resumeDefaults.object(forKey: resumeKey(item: item, client: client)) as? Double
        load(item: item, client: client, seconds: fromStart ? 0 : pending ?? Double(item.resumeTicks) / 10_000_000, sourceID: sourceID)
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
        let seconds = duration > 0 && position >= duration - 1 ? 0 : position
        if let item, let client { load(item: item, client: client, seconds: seconds, sourceID: plan?.source.Id) }
        else if var current = onlineCurrent, let source = onlineSource {
            current.position = seconds; loadOnline(current, source: source)
        }
    }
    func playNext() {
        if let nextItem, let client { play(nextItem, client: client, queue: queue) }
        else if canPlayNext, let current = onlineCurrent, let source = onlineSource {
            playOnline(current.entry, source: source, route: current.route, episode: current.episode + 1, fromStart: true)
        }
    }

    func playOnline(_ entry: OnlineItem, source: OnlineSource, route: Int, episode: Int, fromStart: Bool = false) {
        let key = "onlinePosition.\(entry.id).\(route).\(episode)"
        let position = fromStart ? 0 : resumeDefaults.double(forKey: key)
        let resume = OnlineResume(entry: entry, route: route, episode: episode, position: position, duration: 0, settings: PlaybackSettings())
        loadOnline(resume, source: source)
    }

    func resumeOnline(source: OnlineSource) {
        guard let current = onlineRecent, current.entry.sourceID == source.id else { return }
        loadOnline(current, source: source)
    }

    func resumeHistory(_ entry: PlaybackHistoryEntry, client: EmbyClient?, source: OnlineSource?) {
        if let recent = entry.recent, let client, recent.belongs(to: client) {
            stopCurrent(); sources = []; queue = []; settings = recent.settings
            load(item: recent.item, client: client, seconds: recent.position, sourceID: recent.sourceID)
        } else if let online = entry.online, let source, online.entry.sourceID == source.id {
            loadOnline(online, source: source)
        }
    }

    func removeHistory(_ id: String) { history.removeAll { $0.id == id }; persistHistory() }
    func clearHistory() { history = []; persistHistory() }

    private func recordHistory(recent: RecentPlayback?, online: OnlineResume?) {
        let identity: String
        if let recent {
            identity = [recent.baseURL.absoluteString, recent.userID, recent.serverKind.rawValue, recent.item.id].joined(separator: "\n")
        } else if let online {
            identity = "\(online.entry.id)\n\(online.route)\n\(online.episode)"
        } else { return }
        let id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        history.removeAll { $0.id == id }
        history.insert(PlaybackHistoryEntry(id: id, watchedAt: Date(), recent: recent, online: online), at: 0)
        history = Array(history.prefix(200))
        persistHistory()
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(history) { resumeDefaults.set(data, forKey: "playbackHistory") }
    }

    private func loadOnline(_ resume: OnlineResume, source: OnlineSource) {
        stopCurrent()
        guard resume.entry.sourceID == source.id, let engine else { return }
        let token = generation
        client = nil; queue = []; sources = []; onlineSource = source; onlineCurrent = resume
        item = resume.entry.media; settings = resume.settings
        position = resume.position; duration = resume.duration
        loading = true; error = nil; syncError = nil
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let routes = try await onlineClient.routes(for: resume.entry, source: source)
                guard !Task.isCancelled, generation == token else { return }
                var route = resume.route
                if let name = resume.routeName {
                    guard let matched = routes.firstIndex(where: { $0.name == name }) else { throw CatalogError("播放线路已经变动，请重新选择。") }
                    route = matched
                }
                guard routes.indices.contains(route) else { throw CatalogError("播放线路已经变动，请重新打开影片选择。") }
                let episodes = routes[route].episodes
                var episode = resume.episode
                if let name = resume.episodeName {
                    guard let matched = episodes.firstIndex(where: { $0.name == name }) else { throw CatalogError("分集列表已经变动，请重新选择。") }
                    episode = matched
                }
                guard episodes.indices.contains(episode) else { throw CatalogError("分集列表已经变动，请重新选择。") }
                let selected = episodes[episode]
                onlineRoutes = routes
                onlineCurrent?.route = route; onlineCurrent?.episode = episode
                onlineCurrent?.routeName = routes[route].name; onlineCurrent?.episodeName = selected.name
                plan = PlaybackPlan(url: selected.url, source: MediaSource(id: selected.id, name: source.name + " · " + selected.name), sessionID: "", method: "DirectPlay")
                engine.set("speed", String(speed)); engine.set("volume", String(volume * 100))
                pendingPause = false
                engine.load(url: selected.url, seconds: resume.position, paused: false)
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(45))
                    guard !Task.isCancelled, let self, self.generation == token, self.loading else { return }
                    self.stopCurrent(clearPlan: false); self.error = "在线片源加载超时，请重试或选择其他线路。"
                }
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                loading = false; self.error = "在线片源暂时无法播放，请检查网络或重新选择线路。"
            }
        }
    }

    func resumeRecent(client: EmbyClient) {
        guard let recent, recent.belongs(to: client) else { return }
        stopCurrent()
        sources = []; queue = recentQueue; settings = recent.settings
        load(item: recent.item, client: client, seconds: recent.position, sourceID: recent.sourceID)
    }

    func clearRecent() {
        recent = nil; recentQueue = []; resumeDefaults.removeObject(forKey: "recentPlayback")
        onlineRecent = nil; onlineMostRecent = false
        resumeDefaults.removeObject(forKey: "onlineRecentPlayback")
        resumeDefaults.set(false, forKey: "onlineMostRecent")
    }

    private func rememberPlayback() {
        if var current = onlineCurrent {
            current.position = position; current.duration = duration; current.settings = settings
            onlineRecent = current; onlineMostRecent = true
            resumeDefaults.set(true, forKey: "onlineMostRecent")
            resumeDefaults.set(position, forKey: "onlinePosition.\(current.entry.id).\(current.route).\(current.episode)")
            if let data = try? JSONEncoder().encode(current) { resumeDefaults.set(data, forKey: "onlineRecentPlayback") }
            recordHistory(recent: nil, online: current)
            return
        }
        guard var item, let client else { return }
        item.MediaStreams = nil
        recent = RecentPlayback(item: item, baseURL: client.baseURL, userID: client.connection?.user.Id ?? "",
                                serverKind: client.serverKind, position: position, duration: duration,
                                sourceID: plan?.source.Id, settings: settings)
        recentQueue = queue
        onlineMostRecent = false; resumeDefaults.set(false, forKey: "onlineMostRecent")
        if let data = try? JSONEncoder().encode(recent) { resumeDefaults.set(data, forKey: "recentPlayback") }
        recordHistory(recent: recent, online: nil)
    }

    private func load(item: MediaItem, client: EmbyClient, seconds: Double, sourceID: String?, autoplay: Bool = true) {
        stopCurrent()
        guard let engine else { error = "libmpv 播放内核未能初始化，请重新安装完整应用。"; return }
        let currentGeneration = generation
        onlineCurrent = nil; onlineSource = nil; onlineRoutes = []
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
        if let pendingSeek, abs(engine.position - pendingSeek) < 1 { self.pendingSeek = nil }
        position = pendingSeek ?? engine.position
        buffering = engine.string("paused-for-cache") == "yes"
        networkBytesPerSecond = engine.number("cache-speed") ?? 0
        bufferedSeconds = engine.number("demuxer-cache-duration") ?? 0
        decoding = engine.string("hwdec-current").map { $0 == "no" ? "软件解码" : "硬件解码 · " + $0 } ?? "正在识别"
        droppedFrames = Int((engine.number("decoder-frame-drop-count") ?? 0) + (engine.number("frame-drop-count") ?? 0))
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
        pendingSeek = destination; engine?.seek(destination); position = destination
        enqueueReport("Progress")
    }
    func setSpeed(_ value: Float) { speed = value; engine?.set("speed", String(value)) }

    private func enqueueReport(_ event: String) {
        guard started else { return }
        rememberPlayback()
        lastReport = Date()
        guard let item, let plan, let client else { return }
        if event == "Progress" { guard !reportingProgress else { return }; reportingProgress = true }
        let ticks = PlaybackTime.ticks(position), paused = pendingPause ?? engine?.paused ?? true
        let resumeKey = resumeKey(item: item, client: client), seconds = Double(ticks) / 10_000_000
        resumeDefaults.set(seconds, forKey: resumeKey)
        let settings = settings, previous = reportTask, reportGeneration = generation
        reportTask = Task { [weak self] in
            await previous?.value
            do {
                try await client.report(event, itemID: item.id, plan: plan, ticks: ticks, paused: paused, settings: settings)
                if self?.resumeDefaults.object(forKey: resumeKey) as? Double == seconds {
                    self?.resumeDefaults.removeObject(forKey: resumeKey)
                }
                if self?.generation == reportGeneration { self?.syncError = nil }
            } catch {
                if self?.generation == reportGeneration { self?.syncError = "进度已保存在本机，暂未同步：" + EmbyError.message(error) }
            }
            if event == "Progress" { self?.reportingProgress = false }
            if event == "Stopped", plan.method != "DirectPlay" {
                do { try await client.stopTranscoding(sessionID: plan.sessionID) }
                catch { if self?.generation == reportGeneration { self?.syncError = "服务器未确认结束转码，请检查网络。" } }
            }
        }
    }
    private func stopCurrent(clearPlan: Bool = true) {
        loadTask?.cancel(); loadTask = nil
        timeoutTask?.cancel(); timeoutTask = nil
        generation = UUID()
        if started {
            position = pendingSeek ?? engine?.position ?? position
            enqueueReport("Stopped")
        } else if let plan, let client, plan.method != "DirectPlay" {
            let previous = reportTask
            reportTask = Task { await previous?.value; try? await client.stopTranscoding(sessionID: plan.sessionID) }
        }
        if item != nil { rememberPlayback() }
        started = false; pendingPause = nil; pendingSeek = nil; engine?.stop()
        if clearPlan { plan = nil; mpvTracks = []; externalIndices = [:]; pendingExternalIndex = nil }
        isPlaying = false; loading = false; buffering = false
        networkBytesPerSecond = 0; bufferedSeconds = 0; droppedFrames = 0; decoding = "正在识别"
    }
    func endPlayback() {
        stopCurrent(); item = nil; sources = []; queue = []
        onlineCurrent = nil; onlineSource = nil; onlineRoutes = []
        revision += 1
    }
    func stop() async { endPlayback(); await reportTask?.value }

    private func resumeKey(item: MediaItem, client: EmbyClient) -> String {
        let identity = [client.baseURL.absoluteString, client.connection?.user.Id ?? "", item.id].joined(separator: "\n")
        return "pendingResume." + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
