import Foundation

public enum PlaybackRequest {
    public static func body(userID: String, settings: PlaybackSettings, sourceID: String?,
                            engine: PlaybackEngine = .avPlayer, isPlayback: Bool = true) -> [String: Any] {
        let bitrate = settings.maxBitrate == 0 ? 200_000_000 : settings.maxBitrate
        var transcoding: [String: Any] = [
            "Container": "ts", "Type": "Video", "VideoCodec": "h264", "AudioCodec": "aac",
            "Protocol": "hls", "Context": "Streaming", "MaxAudioChannels": "2",
            "MinSegments": 2, "BreakOnNonKeyFrames": true
        ]
        if settings.maxHeight > 0 { transcoding["MaxHeight"] = settings.maxHeight }
        var conditions: [[String: Any]] = [
            ["Condition": "LessThanEqual", "Property": "VideoBitDepth", "Value": "8", "IsRequired": false]
        ]
        if settings.maxHeight > 0 {
            conditions.append(["Condition": "LessThanEqual", "Property": "Height", "Value": String(settings.maxHeight), "IsRequired": true])
        }
        let direct: [String: Any] = engine == .mpv
            ? ["Container": "mkv,mp4,m4v,mov,webm,avi,ts,mpegts,m2ts,flv,asf,wmv,mpeg,mpg,ogv,vob", "Type": "Video",
               "VideoCodec": "h264,hevc,av1,vp8,vp9,mpeg1video,mpeg2video,mpeg4,vc1,wmv3,theora,prores",
               "AudioCodec": "aac,ac3,eac3,dts,dca,truehd,flac,opus,vorbis,mp3,mp2,alac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,wmav1,wmav2,wmapro"]
            : ["Container": "mp4,m4v,mov", "Type": "Video", "VideoCodec": "h264,hevc", "AudioCodec": "aac,ac3,eac3,alac,mp3"]
        let subtitleMethods = engine == .mpv ? ["Embed", "External"] : ["Encode"]
        let profile: [String: Any] = [
            "Name": engine == .mpv ? "Muxi mpv" : "Muxi AVPlayer", "MaxStreamingBitrate": bitrate,
            "DirectPlayProfiles": [direct],
            "TranscodingProfiles": [transcoding],
            "CodecProfiles": engine == .mpv ? [] : [["Type": "Video", "Codec": "h264", "Conditions": conditions]],
            "SubtitleProfiles": ["srt", "subrip", "ass", "ssa", "vtt", "pgs", "pgssub", "dvdsub"].flatMap { format in
                subtitleMethods.map { ["Format": format, "Method": $0] }
            }
        ]
        var body: [String: Any] = [
            "UserId": userID, "DeviceProfile": profile, "MaxStreamingBitrate": bitrate,
            "StartTimeTicks": 0, "IsPlayback": isPlayback, "AutoOpenLiveStream": false,
            "EnableDirectPlay": !settings.requiresServerConversion(engine: engine), "EnableDirectStream": true,
            "EnableTranscoding": engine == .avPlayer || settings.requiresServerConversion(engine: engine),
            "AllowVideoStreamCopy": settings.maxHeight == 0, "AllowAudioStreamCopy": true
        ]
        // mpv selects tracks locally; omitting stream selection keeps the original file intact.
        if engine == .avPlayer {
            body["SubtitleStreamIndex"] = settings.subtitleIndex
            if let index = settings.audioIndex { body["AudioStreamIndex"] = index }
        }
        if let sourceID { body["MediaSourceId"] = sourceID }
        return body
    }

    public static func plan(info: PlaybackInfo, itemID: String, settings: PlaybackSettings,
                            base: URL, token: String, deviceID: String, sourceID: String? = nil,
                            engine: PlaybackEngine = .avPlayer, serverKind: MediaServerKind = .emby) throws -> PlaybackPlan {
        guard info.ErrorCode == nil, let session = info.PlaySessionId, !session.isEmpty else { throw EmbyError.noPlayableSource }
        let needsVideoConversion = settings.maxHeight > 0 || settings.maxBitrate > 0 || (engine == .avPlayer && settings.subtitleIndex >= 0)
        for source in info.MediaSources ?? [] where source.RequiresOpening != true && (sourceID == nil || source.Id == sourceID) {
            let raw: String
            let method: String
            if !settings.requiresServerConversion(engine: engine), source.SupportsDirectPlay == true {
                raw = ServerAddress.endpoint(base: base, path: "Videos/\(itemID)/stream", query: [
                    .init(name: "Static", value: "true"), .init(name: "MediaSourceId", value: source.Id),
                    .init(name: "DeviceId", value: deviceID), .init(name: "PlaySessionId", value: session)
                ]).absoluteString
                method = "DirectPlay"
            } else if !needsVideoConversion, source.SupportsDirectStream == true, let direct = source.DirectStreamUrl, !direct.isEmpty {
                raw = direct
                method = "DirectStream"
            } else if engine == .avPlayer || settings.requiresServerConversion(engine: engine),
                      source.SupportsTranscoding == true, let transcode = source.TranscodingUrl, !transcode.isEmpty {
                raw = transcode
                method = "Transcode"
            } else { continue }
            var url = try ServerAddress.stream(raw, base: base, token: token, serverKind: serverKind)
            if method != "DirectPlay", ServerAddress.sameOrigin(base, url) {
                var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                var query = parts.queryItems ?? []
                func set(_ key: String, _ value: String) {
                    query.removeAll { $0.name.caseInsensitiveCompare(key) == .orderedSame }
                    query.append(.init(name: key, value: value))
                }
                set("StartTimeTicks", "0")
                if settings.maxHeight > 0 { set("MaxHeight", String(settings.maxHeight)); set("AllowVideoStreamCopy", "false") }
                if settings.maxBitrate > 0 { set("MaxStreamingBitrate", String(settings.maxBitrate)) }
                parts.queryItems = query
                url = parts.url!
            }
            return PlaybackPlan(url: url, source: source, sessionID: session, method: method)
        }
        throw EmbyError.noPlayableSource
    }
}
