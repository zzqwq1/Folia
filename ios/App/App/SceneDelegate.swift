import UIKit
import Capacitor
import WebKit
import MetalKit

// ios/App/App/SceneDelegate.swift
//
// NOTES
// 1. Comments here stay ASCII-only: the iOS sources were once saved with a mismatched
//    encoding and several Chinese comments turned into mojibake. Do not reintroduce that.
// 2. The native renderer talks to JS through a WKScriptMessageHandler instead of a
//    Capacitor plugin. Reason: plugin registration APIs differ between Capacitor majors
//    (`registerPluginInstance`, `CAPPluginCall.getDouble` overloads, ...), and this code has
//    to stay compilable on the pinned 8.5.3 without a Mac to iterate quickly. A message
//    handler needs no registration at all, so the surface that can break is much smaller.
// 3. The Metal view is added on top of the web view. It only draws the placeholder field for
//    now; the lattice shader moves in once the JS -> native path is proven on device.

// Feature switch for the native renderer. Keep it OFF until a build is verified on device:
// with the switch off the app boots exactly like before (plain CAPBridgeViewController, no
// message handler, no Metal view), which is what makes a crash bisectable.
private let foliaNativeRenderEnabled = true

// Second switch, so a crash can be bisected one step at a time:
//   step A: subclass only (no overrides at all)   -> foliaInstallNativeBridge = false
//   step B: subclass + attach message handler     -> foliaInstallNativeBridge = true
private let foliaInstallNativeBridge = false

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        window = UIWindow(windowScene: windowScene)
        // When the switch is off this is the stock controller, i.e. byte-for-byte old behaviour.
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

/// Installs the native renderer bridge on the web view once Capacitor has built it.
/// Step A (subclass only) booted fine, so the attachment now uses the documented path
/// (`capacitorDidLoad` + `bridge?.webView`) instead of walking the view tree from
/// `viewDidAppear`, which was the only difference in the build that crashed.
class FoliaBridgeViewController: CAPBridgeViewController {
    private let nativeBridge = FoliaNativeBridge()

    override func capacitorDidLoad() {
        super.capacitorDidLoad()
        guard foliaInstallNativeBridge else { return }
        guard let webView = bridge?.webView else { return }
        nativeBridge.attach(to: webView)
    }
}

/// Receives fire-and-forget commands from JS via `window.webkit.messageHandlers.foliaNative`.
/// Commands: { cmd: "mount", x, y, width, height } / { cmd: "unmount" } / { cmd: "frame", level, hue }.
final class FoliaNativeBridge: NSObject, WKScriptMessageHandler {
    private weak var hostView: WKWebView?
    private var renderView: FoliaMetalView?
    private var installed = false

    /// Registers the message handler exactly once for the given web view.
    func attach(to webView: WKWebView) {
        hostView = webView
        guard !installed else { return }
        webView.configuration.userContentController.add(self, name: "foliaNative")
        installed = true
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "mount":
            let x = (body["x"] as? Double) ?? 0
            let y = (body["y"] as? Double) ?? 0
            let width = (body["width"] as? Double) ?? 0
            let height = (body["height"] as? Double) ?? 0
            mount(x: x, y: y, width: width, height: height)
        case "unmount":
            unmount()
        case "frame":
            let level = Float((body["level"] as? Double) ?? 0)
            let hue = Float((body["hue"] as? Double) ?? 0.6)
            renderView?.update(level: level, hue: hue)
        default:
            break
        }
    }

    private func mount(x: Double, y: Double, width: Double, height: Double) {
        guard width > 0, height > 0, let device = MTLCreateSystemDefaultDevice() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let host = self.hostView else { return }
            self.renderView?.removeFromSuperview()
            let frame = CGRect(x: x, y: y, width: width, height: height)
            let view = FoliaMetalView(frame: frame, device: device)
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
            host.addSubview(view)
            self.renderView = view
        }
    }

    private func unmount() {
        DispatchQueue.main.async { [weak self] in
            self?.renderView?.removeFromSuperview()
            self?.renderView = nil
        }
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
