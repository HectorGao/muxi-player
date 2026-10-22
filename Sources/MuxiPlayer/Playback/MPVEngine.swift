import AppKit
import CMPV

struct MPVTrack: Identifiable {
    let id: Int
    let type: String
    let streamIndex: Int?
    let title: String?
    let language: String?
    let codec: String?
    let external: Bool
    var label: String {
        let parts = [title, language, codec?.uppercased()].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "轨道 \(id)" : parts.joined(separator: " · ")
    }
}

@MainActor final class MPVEngine {
    let handle: OpaquePointer
    private var timer: Timer?
    private var acceptingEvents = false
    private enum Operation { case property(String, String), command([String]) }
    private struct Request { let id: UInt64; let generation: UInt64; let operation: Operation }
    private var generation: UInt64 = 0
    private var nextID: UInt64 = 1
    private var requests: [Request] = []
    private var inFlight: Request?
    private var properties: [String: String] = [:]
    var onLoaded: (() -> Void)?
    var onUpdate: (() -> Void)?
    var onTracks: (() -> Void)?
    var onEnd: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onWarning: ((String) -> Void)?
    private(set) var tracks: [MPVTrack] = []

    init(headless: Bool = false) throws {
        guard let handle = mpv_create() else { throw EngineError("无法创建 libmpv 播放器。") }
        self.handle = handle
        for (name, value) in ["config": "no", "load-scripts": "no", "ytdl": "no", "tls-verify": "yes", "vo": headless ? "null" : "libmpv", "hwdec": "auto-safe",
                              "terminal": "no", "input-default-bindings": "no", "input-vo-keyboard": "no",
                              "video-timing-offset": "0", "osc": "no", "keep-open": "yes", "idle": "yes", "network-timeout": "30",
                              "user-agent": "MuxiPlayer/0.1.0", "sub-auto": "no", "audio-file-auto": "no"] {
            guard mpv_set_option_string(handle, name, value) >= 0 else { throw EngineError("播放内核选项失败：\(name)") }
        }
        if headless { mpv_set_option_string(handle, "ao", "null") }
        guard mpv_initialize(handle) >= 0 else { throw EngineError("libmpv 初始化失败。") }
        for name in ["time-pos", "duration", "pause", "speed", "aid", "sid", "video-params/h", "eof-reached", "paused-for-cache", "idle-active", "cache-speed", "demuxer-cache-duration", "hwdec-current", "decoder-frame-drop-count", "frame-drop-count"] {
            mpv_observe_property(handle, 0, name, MPV_FORMAT_STRING)
        }
        mpv_observe_property(handle, 0, "track-list", MPV_FORMAT_NODE)
        timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    deinit { timer?.invalidate(); mpv_terminate_destroy(handle) }

    var position: Double { number("time-pos") ?? 0 }
    var duration: Double { number("duration") ?? 0 }
    var paused: Bool { string("pause") != "no" }
    var videoHeight: Int { Int(number("video-params/h") ?? 0) }
    var rate: Double { number("speed") ?? 1 }
    var selectedAudioID: Int? { string("aid").flatMap(Int.init) }
    var selectedSubtitleID: Int? { string("sid").flatMap(Int.init) }
    func string(_ name: String) -> String? { properties[name] }
    func number(_ name: String) -> Double? { string(name).flatMap(Double.init) }

    // Completion chains preserve command order without blocking the GL thread.
    func set(_ name: String, _ value: String) { enqueue(.property(name, value)) }
    func command(_ args: [String]) { enqueue(.command(args)) }
    private func enqueue(_ operation: Operation) {
        requests.append(Request(id: nextID, generation: generation, operation: operation))
        nextID += 1
        sendNext()
    }
    private func sendNext() {
        guard inFlight == nil, !requests.isEmpty else { return }
        let request = requests.removeFirst()
        inFlight = request
        let status: Int32
        switch request.operation {
        case let .property(name, value):
            status = value.withCString { text in
                var pointer: UnsafePointer<CChar>? = text
                return mpv_set_property_async(handle, request.id, name, MPV_FORMAT_STRING, &pointer)
            }
        case let .command(args):
            if args.first == "loadfile" { acceptingEvents = true }
            let strings = args.map { strdup($0) }
            defer { for pointer in strings { free(pointer) } }
            var pointers = strings.map { UnsafePointer<CChar>($0) } + [nil]
            status = pointers.withUnsafeMutableBufferPointer { mpv_command_async(handle, request.id, $0.baseAddress) }
        }
        if status < 0 { complete(id: request.id, error: status) }
    }
    private func complete(id: UInt64, error: Int32) {
        guard let request = inFlight, request.id == id else { return }
        inFlight = nil
        if error < 0, request.generation == generation {
            if case let .command(args) = request.operation, args.first == "loadfile" {
                onFailure?("无法加载片源，请重试或选择其他版本。")
            } else { onWarning?("操作未成功，当前片源继续保留。请重试或选择其他轨道。") }
        }
        sendNext()
    }
    func load(url: URL, seconds: Double, paused: Bool) {
        tracks = []
        set("pause", paused ? "yes" : "no")
        set("start", String(max(0, seconds)))
        set("aid", "auto")
        set("sid", "no")
        command(["loadfile", url.absoluteString])
    }
    func stop() {
        generation += 1
        acceptingEvents = false
        requests.removeAll()
        command(["stop"])
        tracks = []
    }
    func seek(_ seconds: Double) { command(["seek", String(max(0, seconds)), "absolute+exact"]) }

    private func updateProperty(_ property: mpv_event_property) {
        guard let namePointer = property.name else { return }
        let name = String(cString: namePointer)
        if name == "track-list" {
            guard property.format == MPV_FORMAT_NODE, let data = property.data else { return }
            let values = Self.value(data.assumingMemoryBound(to: mpv_node.self).pointee) as? [[String: Any]] ?? []
            tracks = values.compactMap { entry in
                guard let id = entry["id"] as? Int, let type = entry["type"] as? String else { return nil }
                return MPVTrack(id: id, type: type, streamIndex: entry["ff-index"] as? Int,
                                title: entry["title"] as? String, language: entry["lang"] as? String,
                                codec: entry["codec"] as? String, external: entry["external"] as? Bool ?? false)
            }
            if acceptingEvents { onTracks?() }
        } else if property.format == MPV_FORMAT_STRING, let data = property.data,
                  let string = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee {
            properties[name] = String(cString: string)
        } else { properties[name] = nil }
    }

    private static func value(_ node: mpv_node) -> Any? {
        switch node.format {
        case MPV_FORMAT_STRING: return node.u.string.map { String(cString: $0) }
        case MPV_FORMAT_FLAG: return node.u.flag != 0
        case MPV_FORMAT_INT64: return Int(node.u.int64)
        case MPV_FORMAT_DOUBLE: return node.u.double_
        case MPV_FORMAT_NODE_ARRAY, MPV_FORMAT_NODE_MAP:
            guard let list = node.u.list?.pointee, let values = list.values, list.num >= 0 else { return nil }
            if node.format == MPV_FORMAT_NODE_ARRAY { return (0..<Int(list.num)).compactMap { value(values[$0]) } }
            guard let keys = list.keys else { return nil }
            var result: [String: Any] = [:]
            for index in 0..<Int(list.num) { if let key = keys[index] { result[String(cString: key)] = value(values[index]) } }
            return result
        default: return nil
        }
    }

    private func poll() {
        var loaded = false
        while let event = mpv_wait_event(handle, 0), event.pointee.event_id != MPV_EVENT_NONE {
            if event.pointee.event_id == MPV_EVENT_PROPERTY_CHANGE, let data = event.pointee.data {
                updateProperty(data.assumingMemoryBound(to: mpv_event_property.self).pointee)
                continue
            }
            if event.pointee.event_id == MPV_EVENT_COMMAND_REPLY || event.pointee.event_id == MPV_EVENT_SET_PROPERTY_REPLY {
                complete(id: event.pointee.reply_userdata, error: event.pointee.error)
                continue
            }
            guard acceptingEvents else { continue }
            switch event.pointee.event_id {
            case MPV_EVENT_FILE_LOADED: loaded = true
            case MPV_EVENT_END_FILE:
                if let ended = event.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee {
                    if ended.reason == MPV_END_FILE_REASON_ERROR {
                        let reason = String(cString: mpv_error_string(ended.error))
                        onFailure?("libmpv 无法打开此片源（\(reason)）。请检查服务器连接或选择其他版本。")
                    } else if ended.reason == MPV_END_FILE_REASON_EOF { onEnd?() }
                }
            default: break
            }
        }
        if loaded, acceptingEvents { onLoaded?() }
        onUpdate?()
    }
    struct EngineError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
