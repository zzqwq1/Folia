import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// 生成扫码登录用的二维码 dataURL。
/// 网页版把接口返回的 `qrimg` 直接塞进 `<img src>`，所以这里给完整的 `data:image/png;base64,`。
enum QRTool {
    private static let context = CIContext(options: nil)
    // 每次新建滤镜：CIFilter 不是线程安全的，桥接层在并发队列里调用。
    private static func makeFilter() -> CIFilterQRCodeGenerator {
        let filter = CIFilter.qrCodeGenerator()
        filter.correctionLevel = "M"
        return filter
    }

    static func dataURL(for text: String, scale: CGFloat = 10) -> String? {
        guard let data = text.data(using: .utf8) else { return nil }
        let filter = makeFilter()
        filter.message = data
        guard let output = filter.outputImage else { return nil }

        // 放大后重绘，避免小图上屏发糊；顺带留一圈白边方便扫码。
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let padded = scaled.composited(over: CIImage(color: .white).cropped(to: scaled.extent))
        guard let cgImage = context.createCGImage(padded, from: padded.extent) else { return nil }
        guard let png = UIImage(cgImage: cgImage).pngData() else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}
