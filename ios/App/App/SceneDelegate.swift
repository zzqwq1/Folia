import UIKit
import Capacitor
import WebKit
import MetalKit

// ios/App/App/SceneDelegate.swift
//
// NOTES
// 1. Comments here stay ASCII-only: the iOS sources were once saved with a mismatched
//    encoding and several Chinese comments turned into mojibake.
// 2. JS -> native goes through a 15 Hz `evaluateJavaScript` poll of `window.__foliaNative`
//    instead of a WKScriptMessageHandler. Two builds were bisected already:
//      - plain CAPBridgeViewController  : boots
//      - subclass, nothing attached     : boots
//      - subclass + message handler     : crashed, and `bridge` is not visible to this target
//    Polling needs no bridge access and no mutation of the web view configuration, which is
//    the smallest surface that can still prove "JS drives a Metal layer" on device.
// 3. The Metal view draws a placeholder field; the lattice shader moves in once this path is
//    confirmed to survive on a real phone.

private let foliaNativeRenderEnabled = true

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        window = UIWindow(windowScene: windowScene)
        let root: UIViewController = foliaNativeRenderEnabled ? FoliaBridgeViewController() : CAPBridgeViewController()
        window?.rootViewController = root
        window?.makeKeyAndVisible()

        SceneDelegateProxy.shared.scene(scene, willConnectTo: session, options: connectionOptions)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        SceneDelegateProxy.shared.scene(scene, openURLContexts: URLContexts)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        SceneDelegateProxy.shared.scene(scene, continue: userActivity)
    }
}

/// Hosts the native renderer and reads the page state.
class FoliaBridgeViewController: CAPBridgeViewController {
    private let renderer = FoliaNativeRenderer()

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard foliaNativeRenderEnabled else { return }
        if let webView = FoliaBridgeViewController.findWebView(in: view) {
            renderer.attach(to: webView)
        }
    }

    /// Depth-first search for the first WKWebView inside a view tree.
    static func findWebView(in view: UIView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for subview in view.subviews {
            if let found = findWebView(in: subview) { return found }
        }
        return nil
    }
}

/// Reads `window.__foliaNative` and drives a Metal overlay.
/// The shape JS publishes:
///   null                                     -> nothing to draw
///   { mount: { x, y, width, height } }       -> create/refresh the overlay
///   { mount: null }                          -> remove the overlay
///   { level: 0...1, hue: 0...1 }             -> per-frame state
///
/// Step D: no Timer and no repeated evaluateJavaScript. Only one read is scheduled after the
/// page settles, so a crash here would point at the single call rather than at a polling loop.
final class FoliaNativeRenderer {
    private weak var hostView: WKWebView?
    private var metalView: FoliaMetalView?
    private var mountedRect: CGRect?
    private var didSchedule = false

    /// Remembers the web view and schedules exactly one state read.
    func attach(to webView: WKWebView) {
        hostView = webView
        guard !didSchedule else { return }
        didSchedule = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.readOnce()
        }
    }

    private func readOnce() {
        guard let webView = hostView else { return }
        webView.evaluateJavaScript("JSON.stringify(window.__foliaNative || null)") { [weak self] result, _ in
            guard let self, let text = result as? String, text != "null" else { return }
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            self.apply(object)
        }
    }

    private func apply(_ object: [String: Any]) {
        if let mount = object["mount"] as? [String: Any] {
            let rect = CGRect(
                x: (mount["x"] as? Double) ?? 0,
                y: (mount["y"] as? Double) ?? 0,
                width: (mount["width"] as? Double) ?? 0,
                height: (mount["height"] as? Double) ?? 0
            )
            if mountedRect != rect {
                mountLayer(rect: rect)
                mountedRect = rect
            }
        } else if mountedRect != nil {
            unmountLayer()
            mountedRect = nil
        }

        if let level = object["level"] as? Double, let hue = object["hue"] as? Double {
            metalView?.update(level: Float(level), hue: Float(hue))
        }
    }

    private func mountLayer(rect: CGRect) {
        guard rect.width > 0, rect.height > 0,
              let host = hostView,
              let device = MTLCreateSystemDefaultDevice() else { return }
        metalView?.removeFromSuperview()
        let view = FoliaMetalView(frame: rect, device: device)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        host.addSubview(view)
        metalView = view
    }

    private func unmountLayer() {
        metalView?.removeFromSuperview()
        metalView = nil
    }
}

/// Minimal Metal view: one full-screen triangle plus a shader compiled at runtime, which
/// avoids adding a .metal file to the Xcode target just for the scaffold.
final class FoliaMetalView: MTKView {
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var level: Float = 0
    private var hue: Float = 0.6
    private var startTime = CACurrentMediaTime()

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float time;
        float level;
        float hue;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut vertexMain(uint vid [[vertex_id]]) {
        float2 positions[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
        VertexOut out;
        out.position = float4(positions[vid], 0.0, 1.0);
        out.uv = positions[vid] * 0.5 + 0.5;
        return out;
    }

    fragment float4 fragmentMain(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
        float2 p = in.uv;
        float2 center = float2(0.5, 0.5);
        float dist = length(p - center);
        float wave = sin((dist * 18.0) - u.time * 2.0 + u.level * 6.0) * 0.5 + 0.5;
        float glow = smoothstep(0.9, 0.0, dist) * (0.35 + u.level * 0.65);
        float3 base = float3(
            0.5 + 0.5 * cos(6.283 + u.hue * 6.283),
            0.5 + 0.5 * cos(6.283 + u.hue * 6.283 + 2.094),
            0.5 + 0.5 * cos(6.283 + u.hue * 6.283 + 4.188)
        );
        float3 color = base * glow * (0.6 + wave * 0.4);
        return float4(color, glow);
    }
    """

    init(frame: CGRect, device: MTLDevice) {
        super.init(frame: frame, device: device)
        self.colorPixelFormat = .bgra8Unorm
        self.clearColor = MTLClearColorMake(0, 0, 0, 0)
        self.isOpaque = false
        self.framebufferOnly = true
        self.preferredFramesPerSecond = 60
        self.enableSetNeedsDisplay = false
        self.isPaused = false
        self.queue = device.makeCommandQueue()
        buildPipeline(device: device)
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// Compiles the runtime shader and builds the pipeline; on failure it parks the view
    /// instead of spinning on empty frames every refresh.
    private func buildPipeline(device: MTLDevice) {
        do {
            let library = try device.makeLibrary(source: FoliaMetalView.shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
            descriptor.fragmentFunction = library.makeFunction(name: "fragmentMain")
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            pipeline = nil
            isPaused = true
        }
    }

    /// Written from the web view thread, read on the render thread; plain floats need no locking.
    func update(level: Float, hue: Float) {
        self.level = max(0, min(1, level))
        self.hue = hue
    }

    override func draw(_ rect: CGRect) {
        guard let pipeline, let queue,
              let descriptor = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        var uniforms = Uniforms(
            time: Float(CACurrentMediaTime() - startTime),
            level: level,
            hue: hue
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private struct Uniforms {
        var time: Float
        var level: Float
        var hue: Float
    }
}
