import Foundation

/// Which engine plays video: libmpv (the default everywhere it can render) or libVLC.
///
/// mpv draws through Vulkan on MoltenVK, and MoltenVK rejects the Apple TV HD's A8 GPU
/// (`VK_ERROR_INCOMPATIBLE_DRIVER`), so on that device mpv plays audio with no picture. libVLC
/// renders through its own OpenGL ES output and works there. Auto picks VLC on the constrained
/// device and mpv everywhere else. Only builds compiled with STREMIOX_VLC (the tvOS apps, which
/// link SwiftVLC) can use VLC.
///
/// Device-scoped like AudioOutputMode: it describes this Apple TV's GPU, not the viewer.
enum PlayerEngine: String, CaseIterable {
    case auto, mpv, vlc

    static let key = "stremiox.playerEngine"

    static var current: PlayerEngine {
        PlayerEngine(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .auto
    }

    /// Whether a newly created player should run on libVLC.
    static var usesVLC: Bool {
        #if STREMIOX_VLC
        switch current {
        case .vlc: return true
        case .mpv: return false
        case .auto: return PerformanceMode.isConstrainedDevice
        }
        #else
        return false
        #endif
    }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .mpv: return "mpv"
        case .vlc: return "VLC"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "VLC on the Apple TV HD, where mpv can't show video; mpv on every other model."
        case .mpv: return "Always mpv. On the Apple TV HD it plays audio with no picture."
        case .vlc: return "Always VLC. Takes effect the next time a video opens."
        }
    }
}
