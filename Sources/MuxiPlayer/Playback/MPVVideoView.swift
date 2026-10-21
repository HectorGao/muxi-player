import SwiftUI
import AppKit
import OpenGL.GL3
import CMPV

struct MPVVideo: NSViewRepresentable {
    let engine: MPVEngine
    func makeNSView(context: Context) -> NSView {
        if let view = MPVOpenGLView(engine: engine) { return view }
        engine.onFailure?("此 Mac 无法创建视频渲染环境。")
        return NSView()
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

final class MPVOpenGLView: NSOpenGLView {
    private let engine: MPVEngine
    private var renderer: OpaquePointer?
    private var timer: Timer?
    private static let openGL = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY)

    init?(engine: MPVEngine) {
        self.engine = engine
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
            UInt32(NSOpenGLPFAColorSize), 24, UInt32(NSOpenGLPFADoubleBuffer), UInt32(NSOpenGLPFAAccelerated), 0
        ]
        super.init(frame: .zero, pixelFormat: NSOpenGLPixelFormat(attributes: attributes))
        wantsBestResolutionOpenGLSurface = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareOpenGL() {
        super.prepareOpenGL()
        guard renderer == nil, let context = openGLContext else { return }
        context.makeCurrentContext()
        var interval: GLint = 1
        context.setValues(&interval, for: .swapInterval)
        var initParams = mpv_opengl_init_params(get_proc_address: { _, name in
            dlsym(MPVOpenGLView.openGL, name)
        }, get_proc_address_ctx: nil)
        let result = "opengl".withCString { api in
            withUnsafeMutablePointer(to: &initParams) { gl in
                var params = [mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: api)),
                              mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: gl),
                              mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)]
                return mpv_render_context_create(&renderer, engine.handle, &params)
            }
        }
        guard result >= 0 else { engine.onFailure?("无法初始化视频画面，请重新打开播放器。"); return }
        // Poll render updates on the GL-owning main thread; no callback outlives this view.
        timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let renderer = self.renderer else { return }
                self.openGLContext?.makeCurrentContext()
                if mpv_render_context_update(renderer) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 { self.draw(self.bounds) }
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    override func reshape() { super.reshape(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = openGLContext else { return }
        context.makeCurrentContext()
        let size = convertToBacking(bounds).size
        glViewport(0, 0, GLsizei(size.width), GLsizei(size.height))
        glClearColor(0, 0, 0, 1)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        if let renderer {
            var fbo = mpv_opengl_fbo(fbo: 0, w: Int32(size.width), h: Int32(size.height), internal_format: 0)
            var flip: Int32 = 1
            var block: Int32 = 0
            withUnsafeMutablePointer(to: &fbo) { target in
                withUnsafeMutablePointer(to: &flip) { flipped in
                    withUnsafeMutablePointer(to: &block) { blocking in
                        var params = [mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: blocking),
                                  mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: target),
                                  mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipped),
                                  mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)]
                        mpv_render_context_render(renderer, &params)
                    }
                }
            }
        }
        context.flushBuffer()
        if let renderer { mpv_render_context_report_swap(renderer) }
    }

    deinit {
        timer?.invalidate()
        openGLContext?.makeCurrentContext()
        if let renderer { mpv_render_context_free(renderer) }
    }
}
