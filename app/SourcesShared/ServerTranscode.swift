import Foundation

/// Route playback through a remote streaming server's HLS transcoder (`/hlsv2`) when the stream is
/// something this device can't decode well, so a weak Apple TV plays what its hardware handles
/// instead of choking on a software decode.
///
/// Only active with a custom (remote / dedicated) server: the embedded server can't transcode
/// (no ffmpeg in the tvOS sandbox), and a home server with a GPU can. In auto mode the server
/// probes the stream first and anything the device decodes in hardware still plays directly, at
/// full quality and with every embedded track; only the rest is transcoded to H.264. The server
/// decides per track: video in a supported codec and audio in a supported codec are copied, the
/// rest re-encoded. If the probe fails or times out, the stream plays directly as before.
enum ServerTranscode {
    /// UserDefaults key: "auto" (default), "always" (every stream through the server), "off".
    static let modeKey = "stremiox.serverTranscode"

    enum Mode: String, CaseIterable {
        case auto, always, off

        var label: String {
            switch self {
            case .auto: return "Auto"
            case .always: return "Always"
            case .off: return "Off"
            }
        }
    }

    static var mode: Mode {
        Mode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .auto
    }
    static func setMode(_ m: Mode) { UserDefaults.standard.setValue(m.rawValue, forKey: modeKey) }

    /// Port the server listens on inside its own host; torrent URLs are rewritten to it so the
    /// server reads its own files over loopback instead of hairpinning through the LAN address.
    private static let serverLocalBase = "http://127.0.0.1:11470"

    /// Video codecs the device decodes in hardware. The Apple TV HD (A8) has no HEVC decoder;
    /// every Apple TV 4K decodes HEVC, so only H.264 is safe on the constrained device.
    private static var videoCodecs: [String] {
        PerformanceMode.isConstrainedDevice ? ["h264"] : ["h264", "hevc"]
    }
    /// Audio codecs that fit the fMP4 segments the server writes; anything else becomes AAC.
    private static let audioCodecs = ["aac", "ac3", "eac3", "mp3"]

    /// The Apple TV HD decodes H.264 in hardware up to 1080p60; beyond that it falls to software.
    private static let maxWidth = 1920, maxHeight = 1080, maxFrameRate = 60.0

    /// The URL mpv should open for a stream: the server's HLS master playlist when transcoding
    /// applies, otherwise the stream URL unchanged.
    static func playbackURL(for url: URL, headers: [String: String]?, live: Bool) async -> URL {
        guard StremioServer.isCustom, mode != .off, !live,
              headers?.isEmpty ?? true,   // the transcoder can't apply add-on request headers
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              !url.path.contains("/hlsv2/"),
              let base = URL(string: StremioServer.base) else { return url }
        let media = serverSideURL(for: url, base: base)

        let force: Bool
        switch mode {
        case .always:
            force = true
        case .auto, .off:
            guard let info = await probe(media) else {
                DiagnosticsLog.log("transcode", "probe failed, playing directly")
                return url
            }
            switch decide(info) {
            case .direct:
                DiagnosticsLog.log("transcode", "direct play (\(info.summary))")
                return url
            case .transcode(let f):
                DiagnosticsLog.log("transcode", "via server, force=\(f) (\(info.summary))")
                force = f
            }
        }
        return hlsURL(media: media, force: force) ?? url
    }

    // MARK: - Decision

    private enum Decision { case direct, transcode(force: Bool) }

    /// Direct play when the video is in a hardware codec and within the device's limits. A codec
    /// outside the list is transcoded by the server on its own; a supported codec over the limits
    /// (resolution, frame rate, HDR on the HD) needs `forceTranscoding`, since the server only
    /// checks the codec.
    private static func decide(_ info: ProbeInfo) -> Decision {
        guard let v = info.video else { return .direct }   // audio-only: mpv handles it
        let codecOK = videoCodecs.contains(v.codec)
        var overLimits = false
        if PerformanceMode.isConstrainedDevice {
            overLimits = (v.width ?? 0) > maxWidth || (v.height ?? 0) > maxHeight
                || (v.frameRate ?? 0) > maxFrameRate || v.isHdr || v.isDoVi
        }
        if codecOK && !overLimits { return .direct }
        return .transcode(force: codecOK && overLimits)
    }

    // MARK: - Server API

    private struct ProbeInfo {
        struct Video { let codec: String; let width: Int?; let height: Int?; let frameRate: Double?; let isHdr: Bool; let isDoVi: Bool }
        let video: Video?
        var summary: String {
            guard let v = video else { return "no video" }
            return "\(v.codec) \(v.width ?? 0)x\(v.height ?? 0)@\(v.frameRate ?? 0)\(v.isHdr ? " HDR" : "")\(v.isDoVi ? " DV" : "")"
        }
    }

    /// `GET /hlsv2/probe?mediaURL=`: ffprobe run on the server. A torrent may need a while for its
    /// metadata, so allow 20 s; the player's own 30 s load timeout starts after this.
    private static func probe(_ media: String) async -> ProbeInfo? {
        guard let url = URL(string: "\(StremioServer.base)/hlsv2/probe?mediaURL=\(encode(media))") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]] else { return nil }
        let video = streams.first { $0["track"] as? String == "video" }.map {
            ProbeInfo.Video(codec: ($0["codec"] as? String ?? "").lowercased(),
                            width: $0["width"] as? Int, height: $0["height"] as? Int,
                            frameRate: ($0["frameRate"] as? NSNumber)?.doubleValue,
                            isHdr: $0["isHdr"] as? Bool ?? false, isDoVi: $0["isDoVi"] as? Bool ?? false)
        }
        return ProbeInfo(video: video)
    }

    /// `GET /hlsv2/{id}/master.m3u8?...`. The id is derived from the media URL and options, so a
    /// reload or retry of the same stream reuses the server's converter instead of starting over.
    private static func hlsURL(media: String, force: Bool) -> URL? {
        var q = ["mediaURL=\(encode(media))"]
        q += videoCodecs.map { "videoCodecs=\($0)" }
        q += audioCodecs.map { "audioCodecs=\($0)" }
        q.append("maxWidth=\(maxWidth)")
        if force { q.append("forceTranscoding=1") }
        let query = q.joined(separator: "&")
        let id = "stremiox-" + fnv1a(query)
        return URL(string: "\(StremioServer.base)/hlsv2/\(id)/master.m3u8?\(query)")
    }

    /// A torrent served by the remote server itself is read back over the server's loopback.
    private static func serverSideURL(for url: URL, base: URL) -> String {
        let s = url.absoluteString
        let b = base.absoluteString
        guard url.host == base.host, url.port == base.port, s.hasPrefix(b) else { return s }
        return serverLocalBase + s.dropFirst(b.count)
    }

    private static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func fnv1a(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}
