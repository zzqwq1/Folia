import Foundation
import Capacitor
import MetalKit
import UIKit

// ios/App/App/FoliaVisualizerPlugin.swift
//
// 原生渲染层的第一块拼图：把原来由 WebKit 负责的高频重绘（晶格 / 墙面 / 可视化）
// 换成 Metal 直接绘制，再作为一层透明视图贴在 WebView 上方。
//
// 为什么需要它：iOS 给 WebKit 的进程内存和 GPU 显存都有硬上限，晶格画布按 3 倍像素渲染
// 时很容易越过阈值，系统直接回收 WebView 进程——这就是群里反复报的「开晶格/墙面就闪退」。
// Metal 自己管纹理和生命周期，同样的画面开销低一个数量级。
//
// 当前阶段：只提供 mount / unmount / pushFrame 三个最小能力，画面是一个可被音量驱动的
// 渐变场，用来打通「JS -> 原生 -> 屏幕」的链路。等链路验证通过后再把晶格着色器搬进来。

/// 原生可视化插件的桥接名：JS 侧用 `Capacitor.Plugins.FoliaVisualizer` 访问。
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

    /// 是否具备原生渲染条件：真机 + Metal 可用。
    @objc func isSupported(_ call: CAPPluginCall) {
        call.resolve([
            "supported": MTLCreateSystemDefaultDevice() != nil,
            "backend": "metal",
        ])
    }

    /// 在指定矩形上贴一层原生渲染视图（坐标单位是 CSS 像素，这里换算成 point）。
    @objc func mount(_ call: CAPPluginCall) {
        guard let bridge = self.bridge, let device = MTLCreateSystemDefaultDevice() else {
            call.reject("Metal 不可用")
            return
        }
        let x = CGFloat(call.getDouble("x") ?? 0)
        let y = CGFloat(call.getDouble("y") ?? 0)
        let width = CGFloat(call.getDouble("width") ?? 0)
        let height = CGFloat(call.getDouble("height") ?? 0)
        guard width > 0, height > 0 else {
            call.reject("尺寸无效")
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, let host = bridge.viewController?.webView else {
                call.reject("找不到 WebView")
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

    /// 移除原生层，回落到 WebView 自己的画布。
    @objc func unmount(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            self?.renderView?.removeFromSuperview()
            self?.renderView = nil
            call.resolve(["mounted": false])
        }
    }

    /// 每帧推一次状态（电平 0~1、色相 0~1），避免 JS 侧一次塞大量数据。
    @objc func pushFrame(_ call: CAPPluginCall) {
        let level = Float(call.getDouble("level") ?? 0)
        let hue = Float(call.getDouble("hue") ?? 0.6)
        renderView?.update(level: level, hue: hue)
        call.resolve()
    }
}

/// 最小 Metal 渲染视图：一个全屏三角形 + 运行时编译的片元着色器。
final class FoliaMetalView: MTKView {
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var level: Float = 0
    private var hue: Float = 0.6
    private var startTime = CACurrentMediaTime()

    /// 着色器在运行时编译，省掉把 .metal 加进 target 的构建设置，CI 上更省事。
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

    /// 编译运行时着色器并建立渲染管线；失败时直接把视图标成暂停，避免每帧空转。
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

    /// 由插件线程写入，渲染线程读取；只是浮点电平，不需要加锁也够用。
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
