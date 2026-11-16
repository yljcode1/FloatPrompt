import SwiftUI

enum PromptShape: String, CaseIterable, Identifiable {
    case strip = "横条", wide = "横向", square = "方形", portrait = "竖向"
    var id: String { rawValue }
    var size: CGSize {
        switch self {
        case .strip: return CGSize(width: 720, height: 320)
        case .wide: return CGSize(width: 720, height: 405)
        case .square: return CGSize(width: 600, height: 600)
        case .portrait: return CGSize(width: 405, height: 720)
        }
    }
}
