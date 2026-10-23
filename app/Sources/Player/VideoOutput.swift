import Foundation

/// How mpv draws video: gpu-next on Vulkan (MoltenVK), or its OpenGL ES render API.
///
/// MoltenVK rejects the Apple TV HD's A8 GPU (`VK_ERROR_INCOMPATIBLE_DRIVER`), so on that device
/// Vulkan opens no video output and mpv plays audio with no picture. Auto picks OpenGL ES on the
/// constrained device and Vulkan everywhere else. tvOS only (MPVGLRenderer).
///
/// Device-scoped like AudioOutputMode: it describes this Apple TV's GPU, not the viewer.
enum VideoOutput: String, CaseIterable {
    case auto, vulkan, opengl

    static let key = "stremiox.videoOutput"

    static var current: VideoOutput {
        VideoOutput(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .auto
    }

    /// Whether a newly created player should draw through OpenGL ES.
    static var usesOpenGL: Bool {
        #if os(tvOS)
        switch current {
        case .opengl: return true
        case .vulkan: return false
        case .auto: return PerformanceMode.isConstrainedDevice
        }
        #else
        return false
        #endif
    }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .vulkan: return "Vulkan"
        case .opengl: return "OpenGL ES"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "OpenGL ES on the Apple TV HD, where Vulkan can't show video; Vulkan on every other model."
        case .vulkan: return "Always Vulkan. HDR and Dolby Vision need it. On the Apple TV HD it plays audio with no picture."
        case .opengl: return "Always OpenGL ES. Takes effect the next time a video opens."
        }
    }
}
