import CoreGraphics
import Foundation

/// 一个块里的槽位（网格单位）：左上角 + 跨几列几行。
struct BlockSlot {
    let x: Int
    let y: Int
    let cols: Int
    let rows: Int
}

/// 直译 src/components/wall/blockTemplates.ts：4 种 12×8 块模板 × 4 种镜像 = 16 种朝向，
/// 朝向由块坐标线性推进（模板）+ 整数哈希（镜像）决定，邻块不会重复。
enum BlockTemplates {
    static let blockCols = 12
    static let blockRows = 8
    static let slotsPerBlock = 12

    private static let templates: [[BlockSlot]] = [
        // 变体 0
        [
            BlockSlot(x: 0, y: 0, cols: 3, rows: 2),
            BlockSlot(x: 3, y: 0, cols: 6, rows: 4),
            BlockSlot(x: 9, y: 0, cols: 3, rows: 2),
            BlockSlot(x: 0, y: 2, cols: 3, rows: 2),
            BlockSlot(x: 9, y: 2, cols: 3, rows: 4),
            BlockSlot(x: 0, y: 4, cols: 4, rows: 4),
            BlockSlot(x: 4, y: 4, cols: 2, rows: 2),
            BlockSlot(x: 6, y: 4, cols: 3, rows: 2),
            BlockSlot(x: 4, y: 6, cols: 2, rows: 2),
            BlockSlot(x: 6, y: 6, cols: 2, rows: 2),
            BlockSlot(x: 8, y: 6, cols: 2, rows: 2),
            BlockSlot(x: 10, y: 6, cols: 2, rows: 2),
        ],
        // 变体 1
        [
            BlockSlot(x: 0, y: 0, cols: 2, rows: 3),
            BlockSlot(x: 2, y: 0, cols: 2, rows: 3),
            BlockSlot(x: 4, y: 0, cols: 2, rows: 3),
            BlockSlot(x: 6, y: 0, cols: 6, rows: 4),
            BlockSlot(x: 0, y: 3, cols: 6, rows: 2),
            BlockSlot(x: 6, y: 4, cols: 2, rows: 4),
            BlockSlot(x: 8, y: 4, cols: 2, rows: 4),
            BlockSlot(x: 10, y: 4, cols: 2, rows: 2),
            BlockSlot(x: 0, y: 5, cols: 2, rows: 3),
            BlockSlot(x: 2, y: 5, cols: 2, rows: 3),
            BlockSlot(x: 4, y: 5, cols: 2, rows: 3),
            BlockSlot(x: 10, y: 6, cols: 2, rows: 2),
        ],
        // 变体 2
        [
            BlockSlot(x: 0, y: 0, cols: 6, rows: 4),
            BlockSlot(x: 6, y: 0, cols: 6, rows: 3),
            BlockSlot(x: 6, y: 3, cols: 4, rows: 3),
            BlockSlot(x: 10, y: 3, cols: 2, rows: 2),
            BlockSlot(x: 0, y: 4, cols: 4, rows: 2),
            BlockSlot(x: 4, y: 4, cols: 2, rows: 2),
            BlockSlot(x: 10, y: 5, cols: 2, rows: 3),
            BlockSlot(x: 0, y: 6, cols: 2, rows: 2),
            BlockSlot(x: 2, y: 6, cols: 2, rows: 2),
            BlockSlot(x: 4, y: 6, cols: 2, rows: 2),
            BlockSlot(x: 6, y: 6, cols: 2, rows: 2),
            BlockSlot(x: 8, y: 6, cols: 2, rows: 2),
        ],
        // 变体 3
        [
            BlockSlot(x: 0, y: 0, cols: 2, rows: 2),
            BlockSlot(x: 2, y: 0, cols: 2, rows: 2),
            BlockSlot(x: 4, y: 0, cols: 4, rows: 3),
            BlockSlot(x: 8, y: 0, cols: 2, rows: 4),
            BlockSlot(x: 10, y: 0, cols: 2, rows: 4),
            BlockSlot(x: 0, y: 2, cols: 2, rows: 3),
            BlockSlot(x: 2, y: 2, cols: 2, rows: 2),
            BlockSlot(x: 4, y: 3, cols: 4, rows: 3),
            BlockSlot(x: 2, y: 4, cols: 2, rows: 2),
            BlockSlot(x: 8, y: 4, cols: 4, rows: 4),
            BlockSlot(x: 0, y: 5, cols: 2, rows: 3),
            BlockSlot(x: 2, y: 6, cols: 6, rows: 2),
        ],
    ]

    private static func flipX(_ slots: [BlockSlot]) -> [BlockSlot] {
        slots.map { BlockSlot(x: blockCols - $0.x - $0.cols, y: $0.y, cols: $0.cols, rows: $0.rows) }
    }

    private static func flipY(_ slots: [BlockSlot]) -> [BlockSlot] {
        slots.map { BlockSlot(x: $0.x, y: blockRows - $0.y - $0.rows, cols: $0.cols, rows: $0.rows) }
    }

    // 镜像保持槽位顺序，所以同一张卡在每个朝向下都保持自己的序号。
    private static let reflections: [([BlockSlot]) -> [BlockSlot]] = [
        { $0 },
        flipX,
        flipY,
        { flipX(flipY($0)) },
    ]

    static let orientationCount = templates.count * reflections.count

    private static let orientedTemplates: [[BlockSlot]] = templates.flatMap { template in
        reflections.map { $0(template) }
    }

    /// 直译 Math.imul 的 32 位整数哈希（溢出环绕）。
    private static func mixBlockCoords(_ blockColumn: Int, _ blockRow: Int) -> UInt32 {
        func imul(_ a: Int32, _ b: Int32) -> Int32 {
            a &* b
        }
        var value = imul(Int32(truncatingIfNeeded: blockColumn), Int32(bitPattern: 0x9e37_79b1))
            ^ imul(Int32(truncatingIfNeeded: blockRow), Int32(bitPattern: 0x85eb_ca6b))
        value = imul(value ^ Int32(bitPattern: UInt32(bitPattern: value) >> 15), Int32(bitPattern: 0x2c1b_3c6d))
        value ^= Int32(bitPattern: UInt32(bitPattern: value) >> 12)
        return UInt32(bitPattern: value)
    }

    private static func orientation(_ blockColumn: Int, _ blockRow: Int) -> Int {
        let count = templates.count
        let template = ((blockColumn + blockRow * 2) % count + count) % count
        return template * reflections.count + Int(mixBlockCoords(blockColumn, blockRow) % UInt32(reflections.count))
    }

    static func template(_ blockColumn: Int, _ blockRow: Int) -> [BlockSlot] {
        orientedTemplates[orientation(blockColumn, blockRow)]
    }
}

/// 直译 src/library/suites/bravais/bravaisConstants.ts 的几何参数。
enum BravaisMetrics {
    static let cellSize: CGFloat = 128
    static let gap: CGFloat = 8
    static var pitch: CGFloat { cellSize + gap }        // 136
    static var blockWidth: CGFloat { CGFloat(BlockTemplates.blockCols) * pitch }   // 1632
    static var blockHeight: CGFloat { CGFloat(BlockTemplates.blockRows) * pitch }  // 1088

    /// 相机缩放档位（<640: .52，<1100: .64，否则 .76）。
    static func scale(for viewportWidth: CGFloat) -> CGFloat {
        viewportWidth < 640 ? 0.52 : viewportWidth < 1100 ? 0.64 : 0.76
    }

    /// 缝的锚点：块边界 = index * 块跨度 - gap / 2。
    static func seamBoundaryX(_ column: Int) -> CGFloat { CGFloat(column) * blockWidth - gap / 2 }
    static func seamBoundaryY(_ row: Int) -> CGFloat { CGFloat(row) * blockHeight - gap / 2 }

    static func nearestSeamBoundaryX(_ x: CGFloat) -> CGFloat {
        seamBoundaryX(Int(((x + gap / 2) / blockWidth).rounded()))
    }

    static func nearestSeamBoundaryY(_ y: CGFloat) -> CGFloat {
        seamBoundaryY(Int(((y + gap / 2) / blockHeight).rounded()))
    }

    /// 一个 slot 的世界矩形。
    static func slotRect(column: Int, row: Int, rect: BlockSlot) -> CGRect {
        CGRect(
            x: CGFloat(column) * blockWidth + CGFloat(rect.x) * pitch,
            y: CGFloat(row) * blockHeight + CGFloat(rect.y) * pitch,
            width: CGFloat(rect.cols) * pitch - gap,
            height: CGFloat(rect.rows) * pitch - gap
        )
    }

    static func slots(column: Int, row: Int) -> [CGRect] {
        BlockTemplates.template(column, row).map { slotRect(column: column, row: row, rect: $0) }
    }
}

/// 直译 bravaisBlockPlate.ts：外框只向左 / 上多盖 PLATE_BLEED，缝边那一行止于 / 铺到缝的边沿。
enum BravaisPlate {
    static let bleed: CGFloat = 2

    static func frame(column: Int, row: Int, anchorY: CGFloat?) -> CGRect {
        let block = CGRect(
            x: CGFloat(column) * BravaisMetrics.blockWidth,
            y: CGFloat(row) * BravaisMetrics.blockHeight,
            width: BravaisMetrics.blockWidth,
            height: BravaisMetrics.blockHeight
        )
        let isRowAnchor: (Int) -> Bool = { boundary in
            guard let anchorY else { return false }
            return abs(BravaisMetrics.seamBoundaryY(boundary) - anchorY) < 1e-6
        }
        let top = isRowAnchor(row) ? (anchorY! - BravaisMetrics.gap / 2) : block.minY - bleed
        let bottom = isRowAnchor(row + 1) ? (anchorY! + BravaisMetrics.gap / 2) : block.maxY
        return CGRect(x: block.minX - bleed, y: top, width: block.width + bleed, height: bottom - top)
    }

    /// 外框 + 每个窗洞，evenodd 填充（坐标相对外框左上角）。
    static func path(frame: CGRect, holes: [CGRect]) -> CGPath {
        let path = CGMutablePath()
        path.addRect(CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        for hole in holes {
            let clipped = hole.intersection(frame)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { continue }
            path.addRect(CGRect(
                x: clipped.minX - frame.minX,
                y: clipped.minY - frame.minY,
                width: clipped.width,
                height: clipped.height
            ))
        }
        return path
    }
}
