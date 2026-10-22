import UIKit
import Capacitor
import MetalKit

// ios/App/App/SceneDelegate.swift
//
// NOTE: comments in this file are intentionally ASCII-only. The iOS sources were previously
// saved with a mismatched encoding, which turned several Chinese comments into mojibake; any
// new text here stays ASCII so the same damage cannot happen again.
//
// This file also hosts the first slice of the native rendering plugin. Xcode only compiles
// files registered in project.pbxproj, so a brand new .swift file would require a project edit
// as well. Keeping the plugin here lets the CI build prove the JS -> Capacitor -> Metal path
// first; it can move into its own file once the plugin needs to grow.

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        window = UIWindow(windowScene: windowScene)
        // Use the subclass so in-app plugins get registered (see FoliaBridgeViewController below).
        window?.rootViewController = FoliaBridgeViewController()
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

/// Registers plugins that live inside the App target itself.
/// Capacitor only auto-registers plugins shipped as packages, so app-local ones are wired here.
class FoliaBridgeViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        super.capacitorDidLoad()
        bridge?.registerPluginInstance(FoliaVisualizerPlugin())
    }
}

/// Native renderer bridge; JS side accesses it as `Capacitor.Plugins.FoliaVisualizer`.
@objc(FoliaVisualizerPlugin)
public class FoliaVisualizerPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "FoliaVisualizerPlugin"
    public let jsName = "FoliaVisualizer"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "mount", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "unmount", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pushFrame", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "isSupported", returnType: CAPPluginReturnPromise),
    ]

    private var renderView: FoliaMetalView?

    /// Reports whether the native renderer can run here (device + Metal available).
    @objc func isSupported(_ call: CAPPluginCall) {
        call.resolve([
            "supported": MTLCreateSystemDefaultDevice() != nil,
            "backend": "metal",
        ])
    }

    /// Attaches a native render layer over the given rectangle (coordinates arrive in CSS pixels).
    @objc func mount(_ call: CAPPluginCall) {
        guard let bridge = self.bridge, let device = MTLCreateSystemDefaultDevice() else {
            call.reject("Metal unavailable")
            return
        }
        let x = CGFloat(call.getDouble("x") ?? 0)
        let y = CGFloat(call.getDouble("y") ?? 0)
        let width = CGFloat(call.getDouble("width") ?? 0)
        let height = CGFloat(call.getDouble("height") ?? 0)
        guard width > 0, height > 0 else {
            call.reject("invalid size")
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, let host = bridge.viewController?.webView else {
                call.reject("no webview")
                return
            }
            self.renderView?.removeFromSuperview()

            let frame = CGRect(x: x, y: y, width: width, height: height)
            let view = FoliaMetalView(frame: frame, device: device)
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
            host.addSubview(view)
            self.renderView = view

            call.resolve(["mounted": true])
        }
    }

    /// Removes the native layer and hands rendering back to the WebView canvas.
    @objc func unmount(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            self?.renderView?.removeFromSuperview()
            self?.renderView = nil
            call.resolve(["mounted": false])
        }
    }

    /// Pushes one frame of state; JS throttles the rate so this stays cheap.
    @objc func pushFrame(_ call: CAPPluginCall) {
        let level = Float(call.getDouble("level") ?? 0)
        let hue = Float(call.getDouble("hue") ?? 0.6)
        renderView?.update(level: level, hue: hue)
        call.resolve()
    }
}

/// Minimal Metal view: one full-screen triangle plus a shader compiled at runtime,
/// which avoids adding a .metal file to the Xcode target just for the scaffold.
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

    /// Written from the plugin queue, read on the render thread; plain floats need no locking.
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
