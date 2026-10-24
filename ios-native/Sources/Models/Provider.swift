import Foundation

enum Provider: String, CaseIterable, Identifiable {
    case netease
    case qq
    case kugou
    case bodian

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .netease: return "网易云音乐"
        case .qq:      return "QQ 音乐"
        case .kugou:   return "酷狗音乐"
        case .bodian:  return "波点音乐"
        }
    }

    var shortName: String {
        switch self {
        case .netease: return "网易云"
        case .qq:      return "QQ"
        case .kugou:   return "酷狗"
        case .bodian:  return "波点"
        }
    }

    /// 圆形徽章上的单字（与网页版 PlatformMark 一致）
    var markLetter: String {
        switch self {
        case .netease: return "云"
        case .qq:      return "Q"
        case .kugou:   return "K"
        case .bodian:  return "波"
        }
    }

    /// 品牌色（对齐网页版 src/services/onlineMusic/*/*Provider.ts）
    var accentColorHex: String {
        switch self {
        case .netease: return "#dc2626"
        case .qq:      return "#16a34a"
        case .kugou:   return "#2563eb"
        case .bodian:  return "#0d9488"
        }
    }

    /// 是否已实装
    var isAvailable: Bool {
        switch self {
        case .netease: return true
        default: return false
        }
    }
}
