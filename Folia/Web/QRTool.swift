import Foundation
import CoreImage
import UIKit

/// 生成扫码登录用的二维码 dataURL。
/// 网页版把接口返回的 `qrimg` 直接塞进 `<img src>`，所以这里给完整的 `data:image/png;base64,`。
enum QRTool {
    private static let context = CIContext(options: nil)

    // 每次新建滤镜：CIFilter 不是线程安全的，桥接层在并发队列里调用。
    // 用 setValue 而不是 CIFilterBuiltins 的类型化属性，避免 SDK 版本差异导致编译不过。
    private static func makeFilter() -> CIFilter? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue("M", forKey: "inputCorrectionLevel")
        return filter
    }

    static func dataURL(for text: String, scale: CGFloat = 10) -> String? {
        guard let data = text.data(using: .utf8), let filter = makeFilter() else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        guard let output = filter.outputImage else { return nil }

        // 放大后重绘，避免小图上屏发糊；顺带留一圈白边方便扫码。
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let padded = scaled.composited(over: CIImage(color: .white).cropped(to: scaled.extent))
        guard let cgImage = context.createCGImage(padded, from: padded.extent) else { return nil }
        guard let png = UIImage(cgImage: cgImage).pngData() else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}
