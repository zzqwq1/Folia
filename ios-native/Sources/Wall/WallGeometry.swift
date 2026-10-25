// Port of src/components/wall/layout.ts — pure geometry for the poster wall: an infinite
// lattice of repeated cells, plus the anchored expansion reflow that re-gears neighbours.

import Foundation
import CoreGraphics

struct WallMetrics: Equatable {
    var cellSize: CGFloat = 128
    var gap: CGFloat = 8

    var pitch: CGFloat { cellSize + gap }

    static let standard = WallMetrics()
}

struct WallBounds: Equatable {
    var left: CGFloat
    var top: CGFloat
    var right: CGFloat
    var bottom: CGFloat
}

struct WallRect: Equatable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    var bounds: WallBounds {
        WallBounds(left: x, top: y, right: x + width, bottom: y + height)
    }

    var midX: CGFloat { x + width / 2 }
    var midY: CGFloat { y + height / 2 }
}

/// One drawn poster. The wall repeats, so a song owns many instances: `cellSlot` is its seat
/// inside one lattice cell and `repeatX/Y` says which copy of the cell this is.
struct QueueInstance: Identifiable, Equatable {
    var instanceId: String
    var queueIndex: Int
    var cellSlot: Int
    var repeatX: Int
    var repeatY: Int
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    var id: String { instanceId }
    var rect: WallRect { WallRect(x: x, y: y, width: width, height: height) }
}

/// The repeating unit: a rectangle of blocks holding one pass over the queue.
struct LatticeGeometry: Equatable {
    var blocksPerRow: Int
    var blockRows: Int
    var cellSlots: Int
    var cellWidth: CGFloat
    var cellHeight: CGFloat
    var blockWidth: CGFloat
    var blockHeight: CGFloat
}

enum WallLayoutMath {
    /// Aspect of the repeating cell; a mild landscape bias keeps the recurrence even.
    static let fieldAspect: CGFloat = 2.2
    /// Ceiling on posters built for one viewport.
    static let maxRenderedInstances = 400

    static func overlaps(_ first: WallBounds, _ second: WallBounds) -> Bool {
        first.left < second.right
            && first.right > second.left
            && first.top < second.bottom
            && first.bottom > second.top
    }

    static func geometry(totalEntries: Int, metrics: WallMetrics) -> LatticeGeometry {
        let pitch = metrics.pitch
        let blockWidth = CGFloat(BlockTemplates.cols) * pitch
        let blockHeight = CGFloat(BlockTemplates.rows) * pitch
        let blocks = max(1, Int(ceil(Double(max(0, totalEntries)) / Double(BlockTemplates.slotsPerBlock))))
        let blocksPerRow = blocks <= 1
            ? 1
            : max(1, Int((Double(fieldAspect * CGFloat(blocks) * CGFloat(BlockTemplates.rows) / CGFloat(BlockTemplates.cols))).squareRoot().rounded()))
        let blockRows = Int(ceil(Double(blocks) / Double(blocksPerRow)))

        return LatticeGeometry(
            blocksPerRow: blocksPerRow,
            blockRows: blockRows,
            cellSlots: blocksPerRow * blockRows * BlockTemplates.slotsPerBlock,
            cellWidth: CGFloat(blocksPerRow) * blockWidth,
            cellHeight: CGFloat(blockRows) * blockHeight,
            blockWidth: blockWidth,
            blockHeight: blockHeight
        )
    }

    /// Builds the poster sitting in one slot of one block, addressed by unbounded block
    /// coordinates. The template comes from the block's position *inside* its cell, which is
    /// what makes the lattice periodic; the cell index only contributes a translation.
    static func buildInstance(
        _ geometry: LatticeGeometry,
        totalEntries: Int,
        absoluteColumn: Int,
        absoluteRow: Int,
        slotIndex: Int,
        metrics: WallMetrics
    ) -> QueueInstance {
        let blocksPerRow = geometry.blocksPerRow
        let blockRows = geometry.blockRows
        let repeatX = Int(floorDiv(absoluteColumn, blocksPerRow))
        let repeatY = Int(floorDiv(absoluteRow, blockRows))
        let localColumn = absoluteColumn - repeatX * blocksPerRow
        let localRow = absoluteRow - repeatY * blockRows
        let cellSlot = (localRow * blocksPerRow + localColumn) * BlockTemplates.slotsPerBlock + slotIndex
        let slot = BlockTemplates.template(localColumn, localRow)[slotIndex]
        let pitch = metrics.pitch

        return QueueInstance(
            instanceId: "\(cellSlot):\(repeatX):\(repeatY)",
            queueIndex: totalEntries > 0 ? cellSlot % totalEntries : 0,
            cellSlot: cellSlot,
            repeatX: repeatX,
            repeatY: repeatY,
            x: CGFloat(repeatX) * geometry.cellWidth + CGFloat(localColumn) * geometry.blockWidth + CGFloat(slot.x) * pitch,
            y: CGFloat(repeatY) * geometry.cellHeight + CGFloat(localRow) * geometry.blockHeight + CGFloat(slot.y) * pitch,
            width: CGFloat(slot.cols) * pitch - metrics.gap,
            height: CGFloat(slot.rows) * pitch - metrics.gap
        )
    }

    static func block(of geometry: LatticeGeometry, instance: QueueInstance) -> (column: Int, row: Int, slotIndex: Int) {
        let blockInCell = instance.cellSlot / BlockTemplates.slotsPerBlock
        return (
            column: instance.repeatX * geometry.blocksPerRow + (blockInCell % geometry.blocksPerRow),
            row: instance.repeatY * geometry.blockRows + (blockInCell / geometry.blocksPerRow),
            slotIndex: instance.cellSlot % BlockTemplates.slotsPerBlock
        )
    }

    /// Posters intersecting the viewport. Cost scales with what is on screen, never with queue length.
    static func layoutLattice(
        _ geometry: LatticeGeometry,
        totalEntries: Int,
        bounds: WallBounds,
        overscan: CGFloat,
        metrics: WallMetrics
    ) -> [QueueInstance] {
        guard totalEntries > 0, geometry.blockWidth > 0, geometry.blockHeight > 0 else { return [] }

        let view = WallBounds(
            left: bounds.left - overscan,
            top: bounds.top - overscan,
            right: bounds.right + overscan,
            bottom: bounds.bottom + overscan
        )
        let fromColumn = floored(view.left / geometry.blockWidth)
        let toColumn = floored(view.right / geometry.blockWidth)
        let fromRow = floored(view.top / geometry.blockHeight)
        let toRow = floored(view.bottom / geometry.blockHeight)

        var result: [QueueInstance] = []
        var row = fromRow
        while row <= toRow {
            var column = fromColumn
            while column <= toColumn {
                for slotIndex in 0..<BlockTemplates.slotsPerBlock {
                    let instance = buildInstance(
                        geometry,
                        totalEntries: totalEntries,
                        absoluteColumn: column,
                        absoluteRow: row,
                        slotIndex: slotIndex,
                        metrics: metrics
                    )
                    guard overlaps(instance.rect.bounds, view) else { continue }
                    result.append(instance)
                    if result.count >= maxRenderedInstances { return result }
                }
                column += 1
            }
            row += 1
        }
        return result
    }

    /// Rects for every card in the block holding `active`, while that card is expanded. The
    /// block's footprint is unchanged, so nothing outside it moves.
    static func layoutExpandedBlock(
        _ geometry: LatticeGeometry,
        totalEntries: Int,
        active: QueueInstance,
        metrics: WallMetrics
    ) -> [String: WallRect] {
        guard totalEntries > 0 else { return [:] }

        let block = block(of: geometry, instance: active)
        let localColumn = block.column - active.repeatX * geometry.blocksPerRow
        let localRow = block.row - active.repeatY * geometry.blockRows
        guard let reflow = BlockTemplates.reflow(localColumn, localRow, expandedSlot: block.slotIndex) else { return [:] }

        let pitch = metrics.pitch
        let originX = CGFloat(active.repeatX) * geometry.cellWidth + CGFloat(localColumn) * geometry.blockWidth
        let originY = CGFloat(active.repeatY) * geometry.cellHeight + CGFloat(localRow) * geometry.blockHeight
        let blockInCell = localRow * geometry.blocksPerRow + localColumn

        var result: [String: WallRect] = [:]
        for slotIndex in 0..<BlockTemplates.slotsPerBlock {
            let slot = reflow[slotIndex]
            let cellSlot = blockInCell * BlockTemplates.slotsPerBlock + slotIndex
            result["\(cellSlot):\(active.repeatX):\(active.repeatY)"] = WallRect(
                x: originX + CGFloat(slot.x) * pitch,
                y: originY + CGFloat(slot.y) * pitch,
                width: CGFloat(slot.cols) * pitch - metrics.gap,
                height: CGFloat(slot.rows) * pitch - metrics.gap
            )
        }
        return result
    }

    /// The nearest copy of a song to a world point.
    static func locateNearestInstance(
        _ geometry: LatticeGeometry,
        totalEntries: Int,
        queueIndex: Int,
        point: CGPoint,
        metrics: WallMetrics
    ) -> QueueInstance? {
        guard totalEntries > 0, queueIndex >= 0, queueIndex < totalEntries else { return nil }

        var best: QueueInstance?
        var bestDistance = CGFloat.greatestFiniteMagnitude

        var cellSlot = queueIndex
        while cellSlot < geometry.cellSlots {
            let blockInCell = cellSlot / BlockTemplates.slotsPerBlock
            let localColumn = blockInCell % geometry.blocksPerRow
            let localRow = blockInCell / geometry.blocksPerRow
            let slotIndex = cellSlot % BlockTemplates.slotsPerBlock
            let base = buildInstance(
                geometry,
                totalEntries: totalEntries,
                absoluteColumn: localColumn,
                absoluteRow: localRow,
                slotIndex: slotIndex,
                metrics: metrics
            )
            let repeatX = Int(((point.x - base.x - base.width / 2) / geometry.cellWidth).rounded())
            let repeatY = Int(((point.y - base.y - base.height / 2) / geometry.cellHeight).rounded())
            let candidate = buildInstance(
                geometry,
                totalEntries: totalEntries,
                absoluteColumn: repeatX * geometry.blocksPerRow + localColumn,
                absoluteRow: repeatY * geometry.blockRows + localRow,
                slotIndex: slotIndex,
                metrics: metrics
            )
            let dx = candidate.x + candidate.width / 2 - point.x
            let dy = candidate.y + candidate.height / 2 - point.y
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
            cellSlot += totalEntries
        }
        return best
    }

    /// Every poster of the block `from` sits in and of the eight blocks around it.
    static func locateStepCandidates(
        _ geometry: LatticeGeometry,
        totalEntries: Int,
        from: QueueInstance,
        metrics: WallMetrics
    ) -> [QueueInstance] {
        let origin = block(of: geometry, instance: from)
        var candidates: [QueueInstance] = []
        for row in (origin.row - 1)...(origin.row + 1) {
            for column in (origin.column - 1)...(origin.column + 1) {
                for slotIndex in 0..<BlockTemplates.slotsPerBlock {
                    candidates.append(
                        buildInstance(
                            geometry,
                            totalEntries: totalEntries,
                            absoluteColumn: column,
                            absoluteRow: row,
                            slotIndex: slotIndex,
                            metrics: metrics
                        )
                    )
                }
            }
        }
        return candidates
    }

    private static func floorDiv(_ value: Int, _ divisor: Int) -> Int {
        let quotient = value / divisor
        return (value % divisor != 0 && ((value < 0) != (divisor < 0))) ? quotient - 1 : quotient
    }

    private static func floored(_ value: CGFloat) -> Int {
        Int(value.rounded(.down))
    }
}
