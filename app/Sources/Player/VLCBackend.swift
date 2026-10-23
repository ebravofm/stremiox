#if STREMIOX_VLC
import SwiftUI
import SwiftVLC
import UIKit

/// libVLC behind MPVMetalViewController's interface, for devices where mpv's video output can't
/// run (see PlayerEngine). The controller forwards each public call here, and this reports state
/// back through the same mpv property names the player UI already handles (time-pos, duration,
/// pause, paused-for-cache, track-list, end-file), so the UI does not know which engine is playing.
///
/// libVLC state is read by polling rather than observed: the UI wants mpv-style edge events at a
/// few Hz, and a timer gives exactly that with no observation plumbing.
@MainActor
final class VLCBackend {
    let player = Player()
    private let emit: (String, Any?) -> Void
    private var host: UIViewController?
    private var poll: Timer?

    // Last values reported, so each property is emitted only when it changes.
    private var lastTime = -1.0
    private var lastDuration = -1.0
    private var lastPaused: Bool?
    private var lastBuffering: Bool?
    private var lastTrackSignature = ""
    private var endReported = false
    /// When the play head last moved, to tell a stall (buffering) from steady playback.
    private var lastAdvance = Date.distantPast
    /// A seek requested before libVLC could seek (the resume position arrives with the duration).
    private var pendingSeek: Double?

    /// Same Safari user agent mpv presents: debrid resolvers 500/504 on library user agents.
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// Copies libVLC's warnings and errors into diagnostics.log while the player is open.
    private var logTask: Task<Void, Never>?

    init(emit: @escaping (String, Any?) -> Void) {
        self.emit = emit
        logTask = Task.detached(priority: .utility) {
            for await entry in VLCInstance.shared.logStream(minimumLevel: .warning) {
                DiagnosticsLog.log("vlc-log", "[\(entry.level)] \(entry.module ?? "-"): \(entry.message)")
            }
        }
    }

    /// Put VLC's video surface under everything else in `parent`'s view.
    func attach(to parent: UIViewController) {
        let host = UIHostingController(rootView: VideoView(player).ignoresSafeArea())
        host.view.backgroundColor = .black
        host.view.isUserInteractionEnabled = false   // the player's RemoteCatcher owns all input
        host.view.frame = parent.view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        parent.addChild(host)
        parent.view.insertSubview(host.view, at: 0)
        host.didMove(toParent: parent)
        self.host = host
    }

    /// Waits for the video surface to be on screen before a load starts (see `load`).
    private var surfaceWait: Timer?

    /// SwiftVLC hands its surface to libVLC only once the view is in a window with a size. Started
    /// before that (the controller loads from viewDidLoad), libVLC opens with nowhere to draw: no
    /// video output starts, the decoders fill up, the demuxer stops reading and playback hangs on
    /// the spinner. So the load waits for the surface, lays it out, and starts on the next turn.
    func load(_ url: URL, headers: [String: String]?) {
        surfaceWait?.invalidate(); surfaceWait = nil
        guard let view = host?.view, view.window != nil, view.bounds.width > 0 else {
            surfaceWait = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.load(url, headers: headers) }
            }
            return
        }
        view.layoutIfNeeded()
        DispatchQueue.main.async { [weak self] in self?.start(url, headers: headers) }
    }

    private func start(_ url: URL, headers: [String: String]?) {
        guard host != nil else { return }   // stopped while waiting
        lastTime = -1; lastDuration = -1; lastPaused = nil; lastBuffering = nil
        lastTrackSignature = ""; endReported = false; pendingSeek = nil; lastAdvance = .distantPast
        do {
            let media = try Media(url: url)
            media.addOption(":network-caching=5000")
            var userAgent = Self.userAgent
            for (name, value) in headers ?? [:] {
                switch name.lowercased() {
                case "user-agent": userAgent = value
                case "referer", "referrer": media.addOption(":http-referrer=\(value)")
                default: DiagnosticsLog.log("vlc", "header \(name) not supported by VLC, ignored")
                }
            }
            media.addOption(":http-user-agent=\(userAgent)")
            try player.play(media)
            DiagnosticsLog.log("vlc", "load \(url.host ?? "")\(url.path.suffix(40))")
            startPolling()
        } catch {
            DiagnosticsLog.log("vlc", "load failed: \(error)")
            emit(MPVProperty.endFileError, "\(error)")
        }
    }

    func stop() {
        logTask?.cancel(); logTask = nil
        surfaceWait?.invalidate(); surfaceWait = nil
        poll?.invalidate(); poll = nil
        player.stop()
        host?.willMove(toParent: nil)
        host?.view.removeFromSuperview()
        host?.removeFromParent()
        host = nil
    }

    // MARK: - Transport

    var isPaused: Bool { player.state == .paused }
    func play() { player.resume() }
    func pause() { player.pause() }
    func togglePause() { player.togglePlayPause() }

    func seek(to seconds: Double) {
        guard player.isSeekable else { pendingSeek = seconds; return }
        pendingSeek = nil
        do {
            try player.seek(to: .milliseconds(Int64(max(0, seconds) * 1000)))
        } catch {
            DiagnosticsLog.log("vlc", "seek failed: \(error)")
        }
    }

    func seek(by seconds: Double) {
        _ = player.jump(by: .milliseconds(Int64(seconds * 1000)))
    }

    func setSpeed(_ speed: Double) {
        try? player.setPlaybackRate(PlaybackRate(Float(speed)))
    }

    func setAudioDelay(_ seconds: Double) {
        try? player.setAudioDelay(.milliseconds(Int64(seconds * 1000)))
    }

    func setSubDelay(_ seconds: Double) {
        try? player.setSubtitleDelay(.milliseconds(Int64(seconds * 1000)))
    }

    /// "original" keeps the aspect with bars, "zoom"/"fill" crops to fill, "stretch" distorts.
    func setVideoSize(_ mode: String) {
        switch mode {
        case "zoom", "fill": player.aspectRatio = .fill
        case "stretch": player.aspectRatio = .ratio(16, 9)
        default: player.aspectRatio = .default
        }
    }

    // MARK: - Tracks

    /// mpv-style tracks: ids are 1-based positions in VLC's list, -1 (in the setters) means none.
    func tracks(ofType type: String) -> [MPVTrack] {
        let list: [Track]
        switch type {
        case "audio": list = player.audioTracks
        case "sub": list = player.subtitleTracks
        case "video": list = player.videoTracks
        default: return []
        }
        return list.enumerated().map { i, t in
            MPVTrack(id: i + 1, type: type, title: t.name, lang: t.language ?? "", selected: t.isSelected)
        }
    }

    func setAudioTrack(_ id: Int) {
        let list = player.audioTracks
        player.selectedAudioTrack = list.indices.contains(id - 1) ? list[id - 1] : nil
    }

    func setSubtitleTrack(_ id: Int) {
        let list = player.subtitleTracks
        player.selectedSubtitleTrack = list.indices.contains(id - 1) ? list[id - 1] : nil
    }

    func addExternalSubtitle(url: String) {
        guard let u = URL(string: url) else { return }
        do {
            try player.addExternalTrack(from: u, type: .subtitle, select: true)
        } catch {
            DiagnosticsLog.log("vlc", "external subtitle failed: \(error)")
        }
    }

    func chapters() -> [MPVChapter] {
        player.chapters().map { MPVChapter(title: $0.name ?? "", start: Double($0.timeOffset.milliseconds) / 1000) }
    }

    // MARK: - Info

    func mediaSummary() -> (height: Int, audioCodec: String) {
        let height = Int(player.videoSize?.height ?? 0)
        let audio = player.selectedAudioTrack?.codecString ?? ""
        return (height, audio)
    }

    func playbackStats() -> [(String, String)] {
        var rows: [(String, String)] = []
        if let size = player.videoSize, size.width > 0 {
            let codec = player.videoTracks.first(where: \.isSelected)?.codecString ?? ""
            rows.append(("Video", "\(Int(size.width))×\(Int(size.height))  \(codec)"))
        }
        rows.append(("Decode", "VLC"))
        if let stats = player.statistics { rows.append(("Dropped", "\(stats.lostPictures)")) }
        if let audio = player.selectedAudioTrack {
            let codec = audio.codecString ?? ""
            rows.append(("Audio", audio.channels.map { "\(codec)  \($0)ch" } ?? codec))
        }
        rows.append(("Buffer", "\(Int(player.bufferFill * 100))%"))
        return rows
    }

    // MARK: - State polling

    private func startPolling() {
        poll?.invalidate()
        let interval = PerformanceMode.reduced ? 0.5 : 0.25
        poll = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let state = player.state

        if state == .error {
            if !endReported {
                endReported = true
                emit(MPVProperty.endFileError, "VLC could not play this stream")
            }
            return
        }
        if player.didReachEnd {
            if !endReported {
                endReported = true
                emit(MPVProperty.endFileEof, nil)
            }
            return
        }

        if let pendingSeek, player.isSeekable { seek(to: pendingSeek) }

        if let d = player.duration.map({ Double($0.milliseconds) / 1000 }), d > 0, abs(d - lastDuration) > 0.5 {
            lastDuration = d
            emit(MPVProperty.duration, d)
        }

        let t = Double(player.currentTime.milliseconds) / 1000
        if state == .playing || state == .paused, abs(t - lastTime) >= 0.2 {
            if state == .playing, lastTime >= 0, t > lastTime { lastAdvance = Date() }
            if lastTime < 0, t > 0 { lastAdvance = Date() }
            lastTime = t
            emit(MPVProperty.timePos, t)
        }

        let paused = state == .paused
        if paused != lastPaused {
            lastPaused = paused
            emit(MPVProperty.pause, paused)
        }

        // mpv's paused-for-cache: true until the play head moves, and again when it stalls while
        // playing. A deliberate pause is not buffering.
        let buffering = !paused && Date().timeIntervalSince(lastAdvance) > 1.5
        if buffering != lastBuffering {
            lastBuffering = buffering
            emit(MPVProperty.pausedForCache, buffering)
        }

        let signature = (player.audioTracks + player.subtitleTracks + player.videoTracks)
            .map { "\($0.id)\($0.isSelected ? "*" : "")" }.joined(separator: ",")
        if signature != lastTrackSignature {
            lastTrackSignature = signature
            emit(MPVProperty.trackList, nil)
        }
    }
}
#endif
