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

    var accentColorHex: String {
        switch self {
        case .netease: return "#E60026"
        case .qq:      return "#31C27C"
        case .kugou:   return "#2BA1E0"
        case .bodian:  return "#7B61FF"
        }
    }
}
