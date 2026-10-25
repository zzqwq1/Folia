// Port of src/components/app/lattice/exploreLayout.ts + wallLayout.ts — the explore wall's
// layout: the wall laid out by section, each section a small collage with its heading as one of
// the tiles. A lot is 12 x 8 units and holds one section of up to 13 entries; a longer section is
// dealt evenly, in order, over lots that follow each other. All lots in the page's order are the
// strip. The plane has no edge: the place (column, row) holds lot (row + column * stride) of the
// strip, counted round.

import Foundation
import CoreGraphics

/// A rectangle on a lot, in units of the cell pitch.
struct LotSlot: Equatable {
    var x: Int
    var y: Int
    var cols: Int
    var rows: Int
}

enum LotTables {
    static let lotCols = 12
    static let lotRows = 8
    /// 一块 lot 最多放几个条目；更长的段落摊到几块 lot 上
    static let lotCapacity = 13

    // 三个条目以上的 lot：
    //   标题条   | 右方块
    //   ---------|-------
    //   左方块   | 右条
    static let headingStrip = LotSlot(x: 0, y: 0, cols: 6, rows: 2)
    static let leftSquare = LotSlot(x: 0, y: 2, cols: 6, rows: 6)
    static let rightSquare = LotSlot(x: 6, y: 0, cols: 6, rows: 6)
    static let rightStrip = LotSlot(x: 6, y: 6, cols: 6, rows: 2)

    // 一个或两个条目的 lot：标题占整个左半，条目占右半
    static let headingHalf = LotSlot(x: 0, y: 0, cols: 6, rows: 8)
    /// 右半按条目数（1、2）切好的座位，单位为整块 lot
    static let rightHalfSeats: [[LotSlot]] = [
        [],
        [LotSlot(x: 6, y: 0, cols: 6, rows: 8)],
        [LotSlot(x: 6, y: 0, cols: 6, rows: 4), LotSlot(x: 6, y: 4, cols: 6, rows: 4)],
    ]

    /// 一个方块（6 x 6）切成 m 个座位：`squareSeats[m]`，m 从 1 到 9
    static let squareSeats: [[LotSlot]] = [
        [],
        [LotSlot(x: 0, y: 0, cols: 6, rows: 6)],
        [LotSlot(x: 0, y: 0, cols: 6, rows: 3), LotSlot(x: 0, y: 3, cols: 6, rows: 3)],
        [
            LotSlot(x: 0, y: 0, cols: 6, rows: 4),
            LotSlot(x: 0, y: 4, cols: 3, rows: 2), LotSlot(x: 3, y: 4, cols: 3, rows: 2),
        ],
        [
            LotSlot(x: 0, y: 0, cols: 4, rows: 4), LotSlot(x: 4, y: 0, cols: 2, rows: 4),
            LotSlot(x: 0, y: 4, cols: 4, rows: 2), LotSlot(x: 4, y: 4, cols: 2, rows: 2),
        ],
        [
            LotSlot(x: 0, y: 0, cols: 4, rows: 4), LotSlot(x: 4, y: 0, cols: 2, rows: 2),
            LotSlot(x: 4, y: 2, cols: 2, rows: 2),
            LotSlot(x: 0, y: 4, cols: 4, rows: 2), LotSlot(x: 4, y: 4, cols: 2, rows: 2),
        ],
        [
            LotSlot(x: 0, y: 0, cols: 4, rows: 4), LotSlot(x: 4, y: 0, cols: 2, rows: 2),
            LotSlot(x: 4, y: 2, cols: 2, rows: 2),
            LotSlot(x: 0, y: 4, cols: 2, rows: 2), LotSlot(x: 2, y: 4, cols: 2, rows: 2),
            LotSlot(x: 4, y: 4, cols: 2, rows: 2),
        ],
        [
            LotSlot(x: 0, y: 0, cols: 3, rows: 2), LotSlot(x: 3, y: 0, cols: 3, rows: 2),
            LotSlot(x: 0, y: 2, cols: 3, rows: 2), LotSlot(x: 3, y: 2, cols: 3, rows: 2),
            LotSlot(x: 0, y: 4, cols: 2, rows: 2), LotSlot(x: 2, y: 4, cols: 2, rows: 2),
            LotSlot(x: 4, y: 4, cols: 2, rows: 2),
        ],
        [
            LotSlot(x: 0, y: 0, cols: 3, rows: 2), LotSlot(x: 3, y: 0, cols: 3, rows: 2),
            LotSlot(x: 0, y: 2, cols: 2, rows: 2), LotSlot(x: 2, y: 2, cols: 2, rows: 2),
            LotSlot(x: 4, y: 2, cols: 2, rows: 2),
            LotSlot(x: 0, y: 4, cols: 2, rows: 2), LotSlot(x: 2, y: 4, cols: 2, rows: 2),
            LotSlot(x: 4, y: 4, cols: 2, rows: 2),
        ],
        [
            LotSlot(x: 0, y: 0, cols: 2, rows: 2), LotSlot(x: 2, y: 0, cols: 2, rows: 2),
            LotSlot(x: 4, y: 0, cols: 2, rows: 2),
            LotSlot(x: 0, y: 2, cols: 2, rows: 2), LotSlot(x: 2, y: 2, cols: 2, rows: 2),
            LotSlot(x: 4, y: 2, cols: 2, rows: 2),
            LotSlot(x: 0, y: 4, cols: 2, rows: 2), LotSlot(x: 2, y: 4, cols: 2, rows: 2),
            LotSlot(x: 4, y: 4, cols: 2, rows: 2),
        ],
    ]

    /// 一条（6 x 2）切成 m 个座位：`stripSeats[m]`，m 从 1 到 3
    static let stripSeats: [[LotSlot]] = [
        [],
        [LotSlot(x: 0, y: 0, cols: 6, rows: 2)],
        [LotSlot(x: 0, y: 0, cols: 3, rows: 2), LotSlot(x: 3, y: 0, cols: 3, rows: 2)],
        [
            LotSlot(x: 0, y: 0, cols: 2, rows: 2), LotSlot(x: 2, y: 0, cols: 2, rows: 2),
            LotSlot(x: 4, y: 0, cols: 2, rows: 2),
        ],
    ]

    /// 一块 lot 的 `count` 个条目（3 到 13）里右边那条占几个；剩下的左方块占一半（向下取整），
    /// 右方块占其余的
    static func stripSeatsOf(_ count: Int) -> Int {
        count <= 3 ? 1 : count == lotCapacity ? 3 : 2
    }

    /// 一块 lot 里有一格放大时，与它共享另一方块和右条的 `others`（2 到 12）个条目，
    /// 右条占几个：其余都归那个方块，最多九个
    static func grownStripSeatsOf(_ others: Int) -> Int {
        min(3, max(others - 9, others > 2 ? 2 : 1))
    }
}

enum LotSeats {
    /// 两块方块各两位镜像：1 左方块左右翻，2 左方块上下翻，4 和 8 是右方块
    struct LotMirrors: Equatable {
        var bits: Int
    }

    /// 由段落的 key 与它在段落里的序号定镜像：lot 不必长得都一样，但同一块永远长一样
    static func mirrorsOf(_ sectionKey: String, _ part: Int) -> LotMirrors {
        var hash = UInt32(0x811C_9DC5)
        for character in "\(sectionKey)#\(part)" {
            for scalar in character.unicodeScalars {
                hash = (hash ^ scalar.value) &* 0x0100_0193
            }
        }
        hash = (hash ^ (hash >> 15)) &* 0x2C1B_3C6D
        hash ^= hash >> 12
        return LotMirrors(bits: Int(hash % 16))
    }

    /// 一张表在 `field` 里的座位，单位为整块 lot；`mirror`：1 左右翻，2 上下翻
    static func seatsIn(_ field: LotSlot, _ table: [LotSlot], _ mirror: Int) -> [LotSlot] {
        table.map { seat in
            LotSlot(
                x: field.x + (mirror & 1 != 0 ? field.cols - seat.x - seat.cols : seat.x),
                y: field.y + (mirror & 2 != 0 ? field.rows - seat.y - seat.rows : seat.y),
                cols: seat.cols,
                rows: seat.rows
            )
        }
    }

    /// 座位的次序：面积大的在前，然后从上到下，再从左到右
    static func bySeatOrder(_ first: LotSlot, _ second: LotSlot) -> Bool {
        let area: (LotSlot) -> Int = { $0.cols * $0.rows }
        if area(first) != area(second) { return area(first) > area(second) }
        if first.y != second.y { return first.y < second.y }
        return first.x < second.x
    }

    struct LotCut: Equatable {
        var heading: LotSlot
        var seats: [LotSlot]
    }

    /// `count`（1 到 13）个条目的一块 lot 的标题位与座位，按座位的次序：
    /// 第 i 个条目坐第 i 个座位
    static func cutLot(_ rawCount: Int, _ mirrors: LotMirrors) -> LotCut {
        let count = max(0, rawCount)
        if count <= 2 {
            return LotCut(heading: LotTables.headingHalf, seats: LotTables.rightHalfSeats[count])
        }
        let strip = LotTables.stripSeatsOf(count)
        let left = (count - strip) / 2
        var seats: [LotSlot] = []
        seats += seatsIn(LotTables.leftSquare, LotTables.squareSeats[left], mirrors.bits & 3)
        seats += seatsIn(LotTables.rightSquare, LotTables.squareSeats[count - strip - left], (mirrors.bits >> 2) & 3)
        seats += seatsIn(LotTables.rightStrip, LotTables.stripSeats[strip], 0)
        return LotCut(heading: LotTables.headingStrip, seats: seats.sorted(by: bySeatOrder))
    }

    /// `from` 的每个条目各坐 `to` 的哪个座位，让条目挪得最少：中心距离平方和最小的分配，
    /// 有多个并列时取先找到的，于是这条规则是纯的。最多十二个条目：
    /// `best[mask]` 是前几个条目坐在 `mask` 这些座位上时的最小和
    static func seatWithLeastTravel(_ from: [LotSlot], _ to: [LotSlot]) -> [Int] {
        let count = from.count
        guard count > 0 else { return [] }
        // 中心乘二，好让和是整数
        let travel: [[Int]] = from.map { tile in
            to.map { seat in
                let dx = 2 * tile.x + tile.cols - 2 * seat.x - seat.cols
                let dy = 2 * tile.y + tile.rows - 2 * seat.y - seat.rows
                return dx * dx + dy * dy
            }
        }
        let size = 1 << count
        var best = [Double](repeating: .infinity, count: size)
        var lastSeat = [Int](repeating: 0, count: size)
        best[0] = 0
        for mask in 0..<size {
            var tile = 0
            var rest = mask
            while rest != 0 {
                tile += 1
                rest &= rest - 1
            }
            if tile >= count { continue }
            for seat in 0..<count where mask & (1 << seat) == 0 {
                let sum = best[mask] + Double(travel[tile][seat])
                let next = mask | (1 << seat)
                if sum < best[next] {
                    best[next] = sum
                    lastSeat[next] = seat
                }
            }
        }
        var taken = [Int](repeating: 0, count: count)
        var mask = size - 1
        var index = count - 1
        while index >= 0 {
            taken[index] = lastSeat[mask]
            mask &= ~(1 << lastSeat[mask])
            index -= 1
        }
        return taken
    }

    /// `count` 个条目的一块 lot 里，坐在 `grownSeat` 的那格放大时各座位的去处（按 `cutLot` 的座位次序）：
    /// 第 i 个是原来第 i 个座位上的条目此刻站的地方。放大的格子占满它中心所在的那个方块
    /// （原本在右条上的占右方块）；其余的在另一个方块与右条上按它们的人数重新切，
    /// 每个坐挪动最少的座位。标题不动。
    static func cutGrownLot(_ rawCount: Int, _ mirrors: LotMirrors, _ grownSeat: Int) -> [LotSlot] {
        let count = max(0, rawCount)
        let base = cutLot(count, mirrors).seats
        guard grownSeat >= 0, grownSeat < base.count else { return base }
        let grown = base[grownSeat]
        if count <= 2 {
            return base.enumerated().map { seat, _ in
                seat == grownSeat ? LotTables.rightSquare : LotTables.rightStrip
            }
        }
        let isInLeft = Double(grown.x) + Double(grown.cols) / 2
            < Double(LotTables.leftSquare.x + LotTables.leftSquare.cols)
        let others = count - 1
        let strip = LotTables.grownStripSeatsOf(others)
        var free: [LotSlot] = []
        free += seatsIn(
            isInLeft ? LotTables.rightSquare : LotTables.leftSquare,
            LotTables.squareSeats[others - strip],
            isInLeft ? (mirrors.bits >> 2) & 3 : mirrors.bits & 3
        )
        free += seatsIn(LotTables.rightStrip, LotTables.stripSeats[strip], 0)
        let movers = (0..<count).filter { $0 != grownSeat }
        let taken = seatWithLeastTravel(movers.map { base[$0] }, free)
        var result = base
        result[grownSeat] = isInLeft ? LotTables.leftSquare : LotTables.rightSquare
        for (index, seat) in movers.enumerated() {
            result[seat] = free[taken[index]]
        }
        return result
    }
}

/// One lot of the strip: a section, or one part of a section too long for one lot.
struct ExploreLot: Equatable {
    /// The section's place among the sections that stand on the wall, from 0.
    var section: Int
    /// Which of the section's `parts` lots this is, from 0.
    var part: Int
    var parts: Int
    /// The entries on the lot's seats, by their place in the wall's list: `tiles[i]` stands on `seats[i]`.
    var tiles: [Int]
    var seats: [LotSlot]
    var heading: LotSlot
    var mirrors: LotSeats.LotMirrors
}

struct ExploreLayout: WallLayoutSpec {
    var sections: [WallSectionSpec]
    var lotSize: CGSize?

    private var lots: [ExploreLot]
    private var seatOf: [Int: (lot: Int, seat: Int)]
    private var firstLotOf: [Int]
    private var metrics: WallMetrics
    private var pitch: CGFloat
    private var pitchX: CGFloat
    private var pitchY: CGFloat
    private var lotWidth: CGFloat
    private var lotHeight: CGFloat
    private var stride: Int

    private init(sections: [WallSectionSpec], lots: [ExploreLot], metrics: WallMetrics) {
        self.sections = sections
        self.lots = lots
        self.metrics = metrics
        let pitch = metrics.cellSize + metrics.gap
        let street = metrics.cellSize / 2
        self.pitch = pitch
        self.pitchX = CGFloat(LotTables.lotCols) * pitch + street
        self.pitchY = CGFloat(LotTables.lotRows) * pitch + street
        self.lotWidth = CGFloat(LotTables.lotCols) * pitch - metrics.gap
        self.lotHeight = CGFloat(LotTables.lotRows) * pitch - metrics.gap
        self.lotSize = lots.isEmpty
            ? nil
            : CGSize(width: lotWidth, height: lotHeight)
        self.stride = lots.count >= 7 ? 3 : lots.count >= 4 ? 2 : 1
        var seatOf: [Int: (lot: Int, seat: Int)] = [:]
        for (index, lot) in lots.enumerated() {
            for (seat, tile) in lot.tiles.enumerated() {
                seatOf[tile] = (index, seat)
            }
        }
        self.seatOf = seatOf
        self.firstLotOf = sections.map { section in
            lots.firstIndex(where: { $0.section == section }) ?? -1
        }
    }

    init(pageSections: [WallSectionSpec], metrics: WallMetrics = .standard) {
        let sections = pageSections.filter { !$0.entries.isEmpty }
        self.init(sections: sections, lots: ExploreLayout.buildStrip(sections), metrics: metrics)
    }

    /// The strip: every section's lots, in the page's order. A section is dealt over its lots in
    /// the page's order, the earlier lots taking the one entry more where it does not divide;
    /// on each lot the entries are then put by kind.
    static func buildStrip(_ sections: [WallSectionSpec]) -> [ExploreLot] {
        var result: [ExploreLot] = []
        for (index, section) in sections.enumerated() {
            let total = section.entries.count
            guard total > 0 else { continue }
            let parts = Int(ceil(Double(total) / Double(LotTables.lotCapacity)))
            var from = 0
            for part in 0..<parts {
                let size = total / parts + (part < total % parts ? 1 : 0)
                let entries = section.entries[from..<min(from + size, section.entries.count)]
                    .sorted { $0.kind.rank < $1.kind.rank }
                from += size
                let mirrors = LotSeats.mirrorsOf(section.key, part)
                let cut = LotSeats.cutLot(size, mirrors)
                result.append(
                    ExploreLot(
                        section: index,
                        part: part,
                        parts: parts,
                        tiles: entries.map { $0.index },
                        seats: cut.seats,
                        heading: cut.heading,
                        mirrors: mirrors
                    )
                )
            }
        }
        return result
    }

    // MARK: - Addresses

    private func wrap(_ value: Int, _ count: Int) -> Int {
        guard count > 0 else { return 0 }
        let remainder = value % count
        return remainder < 0 ? remainder + count : remainder
    }

    private func lotIndexAt(_ column: Int, _ row: Int) -> Int {
        wrap(row + column * stride, lots.count)
    }

    private func lotAt(_ column: Int, _ row: Int) -> ExploreLot? {
        guard !lots.isEmpty else { return nil }
        return lots[lotIndexAt(column, row)]
    }

    private func rectOf(_ slot: LotSlot, _ column: Int, _ row: Int) -> WallRect {
        WallRect(
            x: CGFloat(column) * pitchX + CGFloat(slot.x) * pitch,
            y: CGFloat(row) * pitchY + CGFloat(slot.y) * pitch,
            width: CGFloat(slot.cols) * pitch - metrics.gap,
            height: CGFloat(slot.rows) * pitch - metrics.gap
        )
    }

    private func headingAt(_ column: Int, _ row: Int) -> WallHeadingInstance? {
        guard let lot = lotAt(column, row) else { return nil }
        let rect = rectOf(lot.heading, column, row)
        return WallHeadingInstance(
            instanceId: "heading:\(column):\(row)",
            section: lot.section,
            part: lot.part,
            parts: lot.parts,
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: rect.height
        )
    }

    private func posterAt(_ column: Int, _ row: Int, _ seat: Int) -> QueueInstance? {
        guard let lot = lotAt(column, row), seat >= 0, seat < lot.seats.count, seat < lot.tiles.count else { return nil }
        let rect = rectOf(lot.seats[seat], column, row)
        return QueueInstance(
            instanceId: "\(seat):\(column):\(row)",
            queueIndex: lot.tiles[seat],
            cellSlot: seat,
            repeatX: column,
            repeatY: row,
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: rect.height
        )
    }

    /// Of all the places that hold lot `index` of the strip, the one where the lot's point
    /// `offset` (from the lot's top left) is closest to `point`.
    private func nearestPlace(_ index: Int, offset: CGPoint, point: CGPoint) -> (column: Int, row: Int) {
        let column = (point.x - offset.x) / pitchX
        let row = (point.y - offset.y) / pitchY
        let middle = Int(column.rounded())
        let reach = Int(ceil((CGFloat(lots.count) * pitchY) / (2 * pitchX))) + 1
        var best = (column: middle, row: 0)
        var bestDistance = CGFloat.greatestFiniteMagnitude
        var candidate = middle - reach
        while candidate <= middle + reach {
            // The rows of this column that hold the lot: one, and every `lotCount` from it.
            let first = wrap(index - candidate * stride, lots.count)
            let candidateRow = first + lots.count * Int(((row - CGFloat(first)) / CGFloat(lots.count)).rounded())
            let dx = (CGFloat(candidate) - column) * pitchX
            let dy = (CGFloat(candidateRow) - row) * pitchY
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                best = (candidate, candidateRow)
            }
            candidate += 1
        }
        return best
    }

    // MARK: - WallLayoutSpec

    func near(_ bounds: WallBounds, overscan: CGFloat) -> (posters: [QueueInstance], headings: [WallHeadingInstance]) {
        var posters: [QueueInstance] = []
        var headings: [WallHeadingInstance] = []
        guard !lots.isEmpty else { return (posters, headings) }
        let view = WallBounds(
            left: bounds.left - overscan,
            top: bounds.top - overscan,
            right: bounds.right + overscan,
            bottom: bounds.bottom + overscan
        )
        func isFull() -> Bool {
            posters.count + headings.count >= WallLayoutMath.maxRenderedInstances
        }
        var row = Int((view.top / pitchY).rounded(.down))
        let lastRow = Int((view.bottom / pitchY).rounded(.down))
        while row <= lastRow {
            var column = Int((view.left / pitchX).rounded(.down))
            let lastColumn = Int((view.right / pitchX).rounded(.down))
            while column <= lastColumn {
                if let heading = headingAt(column, row),
                   WallLayoutMath.overlaps(heading.rect.bounds, view) {
                    headings.append(heading)
                    if isFull() { return (posters, headings) }
                }
                let seats = lots[lotIndexAt(column, row)].seats.count
                for seat in 0..<seats {
                    guard let poster = posterAt(column, row, seat) else { continue }
                    guard WallLayoutMath.overlaps(poster.rect.bounds, view) else { continue }
                    posters.append(poster)
                    if isFull() { return (posters, headings) }
                }
                column += 1
            }
            row += 1
        }
        return (posters, headings)
    }

    func nearest(queueIndex: Int, point: CGPoint) -> QueueInstance? {
        guard let stands = seatOf[queueIndex], stands.lot < lots.count else { return nil }
        let lot = lots[stands.lot]
        guard stands.seat < lot.seats.count else { return nil }
        let slot = lot.seats[stands.seat]
        let offset = CGPoint(
            x: CGFloat(slot.x) * pitch + (CGFloat(slot.cols) * pitch - metrics.gap) / 2,
            y: CGFloat(slot.y) * pitch + (CGFloat(slot.rows) * pitch - metrics.gap) / 2
        )
        let place = nearestPlace(stands.lot, offset: offset, point: point)
        return posterAt(place.column, place.row, stands.seat)
    }

    func grown(_ active: QueueInstance) -> [String: WallRect] {
        var result: [String: WallRect] = [:]
        guard let lot = lotAt(active.repeatX, active.repeatY) else { return result }
        let seat = active.cellSlot
        guard seat >= 0, seat < lot.seats.count else { return result }
        let grown = LotSeats.cutGrownLot(lot.seats.count, lot.mirrors, seat)
        for (index, slot) in grown.enumerated() {
            result["\(index):\(active.repeatX):\(active.repeatY)"] = rectOf(slot, active.repeatX, active.repeatY)
        }
        return result
    }

    /// The posters of the lot `from` stands on and of the eight lots around it.
    func stepCandidates(from: QueueInstance) -> [QueueInstance] {
        var candidates: [QueueInstance] = []
        guard !lots.isEmpty else { return candidates }
        for row in (from.repeatY - 1)...(from.repeatY + 1) {
            for column in (from.repeatX - 1)...(from.repeatX + 1) {
                let seats = lots[lotIndexAt(column, row)].seats.count
                for seat in 0..<seats {
                    if let poster = posterAt(column, row, seat) { candidates.append(poster) }
                }
            }
        }
        return candidates
    }

    func sectionAt(_ point: CGPoint) -> Int? {
        guard !lots.isEmpty else { return nil }
        let column = Int((point.x / pitchX).rounded(.down))
        let row = Int((point.y / pitchY).rounded(.down))
        // Past the lot's own edge the point is on a street.
        if point.x - CGFloat(column) * pitchX > lotWidth { return nil }
        if point.y - CGFloat(row) * pitchY > lotHeight { return nil }
        return lotAt(column, row)?.section
    }

    func sectionStart(_ section: Int, point: CGPoint) -> CGPoint? {
        guard section >= 0, section < firstLotOf.count else { return nil }
        let index = firstLotOf[section]
        guard index >= 0 else { return nil }
        let place = nearestPlace(index, offset: .zero, point: point)
        return CGPoint(x: CGFloat(place.column) * pitchX, y: CGFloat(place.row) * pitchY)
    }
}

/// The queue wall's layout: the lattice of blocks behind `WallLayoutSpec`.
struct QueueLayout: WallLayoutSpec {
    var sections: [WallSectionSpec] = []
    var lotSize: CGSize? = nil

    private let totalEntries: Int
    private let metrics: WallMetrics
    private let geometry: LatticeGeometry

    init(totalEntries: Int, metrics: WallMetrics = .standard) {
        self.totalEntries = totalEntries
        self.metrics = metrics
        self.geometry = WallLayoutMath.geometry(totalEntries: totalEntries, metrics: metrics)
    }

    func near(_ bounds: WallBounds, overscan: CGFloat) -> (posters: [QueueInstance], headings: [WallHeadingInstance]) {
        (WallLayoutMath.layoutLattice(geometry, totalEntries: totalEntries, bounds: bounds, overscan: overscan, metrics: metrics), [])
    }

    func nearest(queueIndex: Int, point: CGPoint) -> QueueInstance? {
        WallLayoutMath.locateNearestInstance(geometry, totalEntries: totalEntries, queueIndex: queueIndex, point: point, metrics: metrics)
    }

    func grown(_ active: QueueInstance) -> [String: WallRect] {
        WallLayoutMath.layoutExpandedBlock(geometry, totalEntries: totalEntries, active: active, metrics: metrics)
    }

    func stepCandidates(from: QueueInstance) -> [QueueInstance] {
        WallLayoutMath.locateStepCandidates(geometry, totalEntries: totalEntries, from: from, metrics: metrics)
    }

    func sectionAt(_ point: CGPoint) -> Int? { nil }
    func sectionStart(_ section: Int, point: CGPoint) -> CGPoint? { nil }
}
