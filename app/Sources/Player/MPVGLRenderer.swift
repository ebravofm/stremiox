#if os(tvOS)
import GLKit
import Libmpv

/// OpenGL ES video output for mpv, for the Apple TV HD.
///
/// mpv normally draws with gpu-next on Vulkan through MoltenVK, and MoltenVK rejects the A8 GPU
/// (`VK_ERROR_INCOMPATIBLE_DRIVER`), so mpv opens no video output there and plays audio only.
/// The A8 does run OpenGL ES, so this hosts mpv's render API (`vo=libmpv`) in a GLKView instead,
/// the way MPVKit's own OpenGL demo does. Decoding is unchanged: VideoToolbox frames reach GL
/// through mpv's CVOpenGLESTextureCache interop. mpv's GL renderer can't show 10-bit video
/// correctly on iOS/tvOS (mpv#7846), which the A8 can't decode in hardware anyway.
///
/// Lifetime: `attach(to:)` right after `mpv_initialize`, `detach()` before the mpv core is
/// destroyed (a render context must never outlive its core).
final class MPVGLRenderer: NSObject, GLKViewDelegate {
    let view: GLKView
    private let context: EAGLContext
    private var renderContext: OpaquePointer?
    /// mpv's update callback holds this retained; the weak renderer inside means a callback racing
    /// teardown finds nil. Released in detach(), after the callback was cleared.
    private var relay: Unmanaged<UpdateRelay>?
    /// A redraw is already queued on the main thread, so a burst of mpv updates draws once.
    private var drawPending = false

    private final class UpdateRelay {
        weak var renderer: MPVGLRenderer?
        init(_ renderer: MPVGLRenderer) { self.renderer = renderer }
    }

    init?(frame: CGRect) {
        guard let context = EAGLContext(api: .openGLES3) ?? EAGLContext(api: .openGLES2) else { return nil }
        self.context = context
        view = GLKView(frame: frame, context: context)
        super.init()
        view.delegate = self
        view.drawableColorFormat = .RGBA8888
        view.enableSetNeedsDisplay = false
        view.backgroundColor = .black
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.isUserInteractionEnabled = false
    }

    /// Create mpv's GL render context on this view's context and start drawing on its updates.
    @discardableResult
    func attach(to mpv: OpaquePointer) -> Bool {
        EAGLContext.setCurrent(context)
        let api = UnsafeMutableRawPointer(mutating: (MPV_RENDER_API_TYPE_OPENGL as NSString).utf8String)
        var initParams = mpv_opengl_init_params(
            get_proc_address: { _, name in MPVGLRenderer.procAddress(name) },
            get_proc_address_ctx: nil
        )
        let rc: Int32 = withUnsafeMutablePointer(to: &initParams) { initParams in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: api),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: initParams),
                mpv_render_param(),
            ]
            return mpv_render_context_create(&renderContext, mpv, &params)
        }
        guard rc >= 0, let renderContext else {
            DiagnosticsLog.log("mpv", "OpenGL ES render context failed: \(String(cString: mpv_error_string(rc)))")
            return false
        }
        let relay = Unmanaged.passRetained(UpdateRelay(self))
        self.relay = relay
        mpv_render_context_set_update_callback(renderContext, { ctx in
            guard let ctx else { return }
            let relay = Unmanaged<UpdateRelay>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { relay.renderer?.scheduleDraw() }
        }, relay.toOpaque())
        DiagnosticsLog.log("mpv", "video output = OpenGL ES (\(context.api == .openGLES3 ? "3" : "2"))")
        return true
    }

    /// Free the render context. Must run before the mpv core it belongs to is destroyed.
    func detach() {
        guard let renderContext else { return }
        mpv_render_context_set_update_callback(renderContext, nil, nil)
        EAGLContext.setCurrent(context)
        mpv_render_context_free(renderContext)
        self.renderContext = nil
        relay?.release()
        relay = nil
    }

    deinit { detach() }

    private func scheduleDraw() {
        guard !drawPending else { return }
        drawPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.drawPending = false
            if self.renderContext != nil, self.view.window != nil { self.view.display() }
        }
    }

    func glkView(_ view: GLKView, drawIn rect: CGRect) {
        guard let renderContext else { return }
        glClearColor(0, 0, 0, 1)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))

        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &fbo)
        var target = mpv_opengl_fbo(fbo: fbo, w: Int32(view.drawableWidth), h: Int32(view.drawableHeight), internal_format: 0)
        var flip: CInt = 1
        withUnsafeMutablePointer(to: &target) { target in
            withUnsafeMutablePointer(to: &flip) { flip in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: target),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flip),
                    mpv_render_param(),
                ]
                mpv_render_context_render(renderContext, &params)
            }
        }
    }

    private static let openGLES = CFBundleGetBundleWithIdentifier("com.apple.opengles" as CFString)

    private static func procAddress(_ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
        guard let name, let symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue) else { return nil }
        return CFBundleGetFunctionPointerForName(openGLES, symbol)
    }
}
#endif
