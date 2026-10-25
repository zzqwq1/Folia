// Port of src/components/wall/blockTemplates.ts

import Foundation

struct BlockSlot: Equatable {
    let x: Int
    let y: Int
    let cols: Int
    let rows: Int
}

enum BlockTemplates {
    static let cols = 12
    static let rows = 8
    static let slotsPerBlock = 12

    /// Gear an expanded card takes; the only size every slot has an exact re-cover for.
    static let expansionCols = 6
    static let expansionRows = 6

    private static let base: [[BlockSlot]] = [
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
        slots.map { BlockSlot(x: cols - $0.x - $0.cols, y: $0.y, cols: $0.cols, rows: $0.rows) }
    }

    private static func flipY(_ slots: [BlockSlot]) -> [BlockSlot] {
        slots.map { BlockSlot(x: $0.x, y: rows - $0.y - $0.rows, cols: $0.cols, rows: $0.rows) }
    }

    private static let reflections: [([BlockSlot]) -> [BlockSlot]] = [
        { $0 },
        flipX,
        flipY,
        { flipX(flipY($0)) },
    ]

    private static let orientedTemplates: [[BlockSlot]] =
        base.flatMap { template in reflections.map { $0(template) } }

    private static let orientedReflows: [[[BlockSlot]]] =
        BlockReflows.table.flatMap { perSlot in reflections.map { reflect in perSlot.map { reflect($0) } } }

    /// Integer hash; picks the reflection so the field never settles into a visible period.
    private static func mixBlockCoords(_ blockColumn: Int, _ blockRow: Int) -> UInt32 {
        var value = (Int32(truncatingIfNeeded: blockColumn) &* Int32(bitPattern: 0x9e37_79b1))
            ^ (Int32(truncatingIfNeeded: blockRow) &* Int32(bitPattern: 0x85eb_ca6b))
        value = (value ^ Int32(bitPattern: UInt32(bitPattern: value) >> 15)) &* Int32(bitPattern: 0x2c1b_3c6d)
        value ^= Int32(bitPattern: UInt32(bitPattern: value) >> 12)
        return UInt32(bitPattern: value)
    }

    /// Template steps linearly (+1 across, +2 down) so neighbours never share one, while the
    /// reflection comes from a hash, which keeps the field from reading as a grid.
    private static func orientation(_ blockColumn: Int, _ blockRow: Int) -> Int {
        let count = base.count
        let template = (((blockColumn + blockRow * 2) % count) + count) % count
        return template * reflections.count + Int(mixBlockCoords(blockColumn, blockRow) % UInt32(reflections.count))
    }

    static func template(_ blockColumn: Int, _ blockRow: Int) -> [BlockSlot] {
        orientedTemplates[orientation(blockColumn, blockRow)]
    }

    /// Where every card in this block sits while `expandedSlot` is open.
    static func reflow(_ blockColumn: Int, _ blockRow: Int, expandedSlot: Int) -> [BlockSlot]? {
        guard expandedSlot >= 0, expandedSlot < slotsPerBlock else { return nil }
        return orientedReflows[orientation(blockColumn, blockRow)][expandedSlot]
    }
}
