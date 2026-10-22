import AppKit
import Foundation
import MuxiCore

@main @MainActor struct PlaybackCheck {
    static func wait(_ description: String, _ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw failure("Timed out: \(description)")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "PlaybackCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw failure(message) }
    }

    static func fixtureEvents() -> [[String: Any]] {
        let data = (try? Data(contentsOf: URL(fileURLWithPath: ".local/smoke/events.jsonl"))) ?? Data()
        return data.split(separator: 10).compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
        }
        // MPVEngine uses the same main-run-loop timers as the native app.
        app.run()
    }

    static func run() async throws {
        let base = URL(string: "http://127.0.0.1:18796/emby")!
        let login = EmbyClient(baseURL: base, deviceID: "automated-playback-check")
        let connection = try await login.authenticate(username: "demo", password: "demo")
        let client = EmbyClient(baseURL: base, deviceID: "automated-playback-check", connection: connection)
        let item = try await client.item(id: "mkv")
        let controller = PlaybackController(headless: true)
        guard let engine = controller.engine else { throw failure(controller.error ?? "No libmpv engine") }
        controller.volume = 0
        controller.play(item, client: client, fromStart: true)
        try await wait("MKV load") { !controller.loading }
        try check(controller.error == nil, "MKV failed: \(controller.error ?? "")")
        try await wait("MKV decode and playback clock") { controller.isPlaying && engine.position > 0.3 && engine.videoHeight == 720 }
        try check(controller.plan?.source.Container == "mkv" && controller.plan?.method == "DirectPlay", "MKV must play directly")
        try check(controller.sources.count == 1, "Source discovery failed")
        try check(controller.audioTracks.count == 2 && controller.subtitleTracks.count == 2, "Expected actual double audio and embedded subtitles")
        print("PASS: MKV direct decode, source discovery, two audio and two subtitle tracks")

        controller.seek(to: 24)
        try await wait("actual seek") { abs(engine.position - 24) < 1 }
        controller.togglePause()
        try await wait("pause") { engine.paused && !controller.isPlaying }
        var before = engine.position
        let session = controller.plan!.sessionID
        let audio = controller.audioTracks.first { $0.streamIndex == 2 }!
        let subtitle = controller.subtitleTracks.first { $0.streamIndex == 4 }!
        try check(subtitle.id != subtitle.streamIndex, "Fixture must distinguish mpv track id and Emby stream index")
        controller.selectAudio(id: audio.id)
        controller.selectSubtitle(id: subtitle.id)
        try await wait("local track switch") { engine.selectedAudioID == audio.id && engine.selectedSubtitleID == subtitle.id }
        try check(controller.settings.audioIndex == 2 && controller.settings.subtitleIndex == 4, "Reports must use Emby stream indices")
        try check(controller.plan!.sessionID == session && engine.paused && abs(engine.position - before) < 1,
                  "Local track switches must keep the session, pause and position")
        let external = controller.externalSubtitles.first { $0.Index == 5 }!
        controller.selectExternalSubtitle(external)
        try await wait("external subtitle load") { controller.settings.subtitleIndex == 5 && controller.subtitleTracks.contains { $0.external && $0.id == engine.selectedSubtitleID } }
        controller.selectSubtitle(id: nil)
        try await wait("subtitles off") { engine.selectedSubtitleID == nil && controller.settings.subtitleIndex == -1 }
        try check(controller.plan!.sessionID == session && engine.paused && abs(engine.position - before) < 1,
                  "External subtitles must preserve the playback session")
        print("PASS: local audio/subtitle mapping, external SRT, subtitles off, pause/position/session preservation")

        let missingSubtitle = try JSONDecoder().decode(MediaStream.self, from: Data("""
        {"Index":99,"Type":"Subtitle","Codec":"srt","IsExternal":true,"DeliveryMethod":"External","DeliveryUrl":"/emby/media/missing.srt"}
        """.utf8))
        var sawSubtitleWarning = false
        let originalWarning = engine.onWarning
        engine.onWarning = { message in sawSubtitleWarning = true; originalWarning?(message) }
        controller.togglePause()
        try await wait("resume before missing subtitle") { controller.isPlaying && !engine.paused }
        controller.selectExternalSubtitle(missingSubtitle)
        try await wait("missing subtitle warning") { sawSubtitleWarning }
        try await wait("video continues after subtitle failure") { engine.position > before + 0.5 }
        try check(controller.error == nil && controller.isPlaying && controller.plan?.sessionID == session,
                  "A bad external subtitle must not stop playback or replace its session")
        controller.selectExternalSubtitle(external)
        try await wait("subtitle recovery") { controller.settings.subtitleIndex == 5 }
        controller.selectSubtitle(id: nil)
        controller.togglePause()
        try await wait("pause after subtitle recovery") { engine.paused && !controller.isPlaying }
        before = engine.position
        engine.onWarning = originalWarning
        print("PASS: failed external subtitle preserves video and permits another selection")

        var settings = controller.settings
        settings.maxHeight = 480
        settings.maxBitrate = 2_000_000
        controller.changeSettings(settings)
        try await wait("HLS quality change") { !controller.loading }
        try check(controller.error == nil, "HLS failed: \(controller.error ?? "")")
        try await wait("actual 480p HLS stream") { engine.videoHeight == 480 }
        try check(!controller.isPlaying && engine.paused, "Quality changes must preserve pause")
        try check(abs(engine.position - before) < 1, "Position changed during quality switch")
        try check(controller.plan!.method == "Transcode", "Expected server-transcoded HLS")
        try check(controller.settings.maxBitrate == 2_000_000 && controller.settings.audioIndex == 2, "Quality and audio request lost")
        controller.setSpeed(1.5)
        controller.togglePause()
        try await wait("1.5x playback") { controller.isPlaying && engine.position > before + 0.5 }
        try check(engine.rate == 1.5, "Actual mpv rate differs from selected speed")
        let qualitySession = controller.plan!.sessionID
        let pauseEventStart = fixtureEvents().count
        controller.togglePause()
        try check(!controller.isPlaying, "Pause intent must update immediately")
        let qualityPosition = engine.position
        // Deliberately switch quality before the async pause command has completed.
        controller.changeSettings(PlaybackSettings())
        try await wait("return to original") { !controller.loading && engine.videoHeight == 720 }
        try check(controller.error == nil && engine.paused && abs(engine.position - qualityPosition) < 1, "Returning to original must preserve pause and position")
        try await wait("pause progress reports requested pause") {
            fixtureEvents().dropFirst(pauseEventStart).contains {
                $0["event"] as? String == "/Sessions/Playing/Progress" && $0["PlaySessionId"] as? String == qualitySession && $0["IsPaused"] as? Bool == true
            }
        }
        try check(controller.subtitleTracks.count == 2, "Original embedded subtitles were not rediscovered")
        await controller.stop()
        try await wait("engine stop") { engine.string("idle-active") == "yes" }
        try check(controller.item == nil && controller.plan == nil && !controller.isPlaying, "Stop did not clear controller state")
        try check(controller.syncError == nil, "Progress failed: \(controller.syncError ?? "")")
        print("PASS: actual 480p HLS, 2 Mbps request, seek/resume, 1.5x, rapid pause/quality change, correct pause report, stop/sync")

        let mp4 = try await client.item(id: "movie")
        controller.play(mp4, client: client, fromStart: true)
        try await wait("MP4 decode") { !controller.loading && engine.videoHeight == 720 && engine.position > 0.3 }
        try check(controller.error == nil && controller.plan?.method == "DirectPlay", "MP4 regression")
        try check(controller.audioTracks.count == 2 && controller.subtitleTracks.isEmpty && controller.externalSubtitles.count == 2,
                  "MP4 embedded and external tracks must reflect the actual source")
        let mp4Session = controller.plan!.sessionID
        controller.seek(to: controller.duration - 0.3)
        try await wait("end of file") { engine.string("eof-reached") == "yes" && !controller.isPlaying }
        controller.togglePause()
        try await wait("replay after EOF") { !controller.loading && controller.isPlaying && engine.position > 0.2 && engine.position < 2 }
        try check(controller.error == nil && controller.plan?.sessionID != mp4Session, "EOF replay must negotiate a fresh session from the start")
        await controller.stop()
        try check(controller.syncError == nil, "MP4 stop progress failed")
        print("PASS: MP4 direct playback, actual embedded/external tracks, EOF and replay")

        let slow = try await client.item(id: "slow")
        let eventStart = fixtureEvents().count
        controller.play(slow, client: client, fromStart: true)
        try await wait("throttled stream playback") { !controller.loading && controller.isPlaying }
        controller.seek(to: 25)
        controller.endPlayback()
        try check(controller.item == nil && !controller.loading && !controller.isPlaying, "Exit must clear playback synchronously")
        try await wait("exit closes throttled HTTP transfer") {
            engine.string("idle-active") == "yes" && fixtureEvents().dropFirst(eventStart).contains {
                $0["event"] as? String == "StreamClosed" && $0["complete"] as? Bool == false
            }
        }
        await controller.stop()
        let savedStop = try await client.item(id: slow.id)
        try check(abs(Double(savedStop.resumeTicks) / 10_000_000 - 25) < 1, "Exit immediately after seek lost requested position")

        controller.play(slow, client: client)
        controller.endPlayback()
        try await Task.sleep(for: .milliseconds(500))
        try check(controller.item == nil && controller.plan == nil && !controller.loading && engine.string("idle-active") == "yes", "Cancelled preparation restarted background playback")
        print("PASS: exit interrupts active HTTP transfer, immediate-seek position is saved, cancelled loading stays stopped")

        let defaultsName = "muxi-playback-check-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let offlineReportClient = EmbyClient(baseURL: base, deviceID: "report-failure", connection: connection)
        let offline = PlaybackController(headless: true, resumeDefaults: defaults)
        offline.play(mp4, client: offlineReportClient, fromStart: true)
        try await wait("failed-report fixture playback") { offline.isPlaying && !offline.loading }
        offline.seek(to: 34)
        await offline.stop()
        try check(offline.syncError != nil && defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("pendingResume.") }, "Failed server sync did not retain local resume position")
        let reopened = PlaybackController(headless: true, resumeDefaults: defaults)
        reopened.play(mp4, client: client)
        try await wait("local resume after new controller") { reopened.isPlaying && !reopened.loading && abs(reopened.position - 34) < 2 }
        await reopened.stop()
        try check(reopened.syncError == nil && !defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("pendingResume.") }, "Successful sync did not clear the pending local position")
        print("PASS: offline progress fallback survives controller recreation and clears after confirmed server sync")
        print("Boundary: headless decode/control checks; native video rendering is verified separately.")
    }
}
