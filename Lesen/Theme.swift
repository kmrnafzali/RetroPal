import SwiftUI
import UIKit

enum ReadingTheme: String, CaseIterable, Identifiable {
    case paper
    case sepia
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paper: return "Papier"
        case .sepia: return "Sepia"
        case .dark: return "Nacht"
        }
    }

    var backgroundHex: String {
        switch self {
        case .paper: return "#FBFAF6"
        case .sepia: return "#F2E8D2"
        case .dark: return "#141414"
        }
    }

    var textHex: String {
        switch self {
        case .paper: return "#1C1C1E"
        case .sepia: return "#4F3B2A"
        case .dark: return "#CFCDC6"
        }
    }

    var background: UIColor { UIColor(hex: backgroundHex) }
    var swiftUIBackground: Color { Color(uiColor: background) }
    var isDark: Bool { self == .dark }
}

extension UIColor {
    convenience init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
