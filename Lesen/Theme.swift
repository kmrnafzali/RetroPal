import SwiftUI
import UIKit

enum ReadingTheme: String, CaseIterable, Identifiable {
    case paper
    case sepia
    case candle
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paper: return "Papier"
        case .sepia: return "Sepia"
        case .candle: return "Kerzenlicht"
        case .dark: return "Nacht"
        }
    }

    var backgroundHex: String {
        switch self {
        case .paper: return "#FBF8F1"
        case .sepia: return "#F2E8D2"
        case .candle: return "#E9CC98"
        case .dark: return "#141414"
        }
    }

    var textHex: String {
        switch self {
        case .paper: return "#23201B"
        case .sepia: return "#4F3B2A"
        case .candle: return "#3B2713"
        case .dark: return "#CFCDC6"
        }
    }

    var background: UIColor { UIColor(hex: backgroundHex) }
    var swiftUIBackground: Color { Color(uiColor: background) }
    var isDark: Bool { self == .dark }
    var textColor: UIColor { UIColor(hex: textHex) }
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

/// Gespeicherte Auswahl. „Automatisch" folgt dem Hell-/Dunkelmodus des Geräts.
enum ThemeChoice: String, CaseIterable, Identifiable {
    case auto
    case paper
    case sepia
    case candle
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .paper: return "Papier"
        case .sepia: return "Sepia"
        case .candle: return "Kerze"
        case .dark: return "Nacht"
        }
    }

    func resolve(systemDark: Bool) -> ReadingTheme {
        switch self {
        case .auto: return systemDark ? .dark : .paper
        case .paper: return .paper
        case .sepia: return .sepia
        case .candle: return .candle
        case .dark: return .dark
        }
    }
}

enum ReadingFont: String, CaseIterable, Identifiable {
    case iowan
    case palatino
    case georgia
    case charter
    case newYork
    case sans

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iowan: return "Iowan"
        case .palatino: return "Palatino"
        case .georgia: return "Georgia"
        case .charter: return "Charter"
        case .newYork: return "New York"
        case .sans: return "San Francisco"
        }
    }

    var familyName: String {
        switch self {
        case .iowan: return "Iowan Old Style"
        case .palatino: return "Palatino"
        case .georgia: return "Georgia"
        case .charter: return "Charter"
        case .newYork: return "New York"
        case .sans: return "SF Pro"
        }
    }

    var css: String {
        switch self {
        case .iowan: return "'Iowan Old Style', Georgia, serif"
        case .palatino: return "Palatino, 'Palatino Linotype', serif"
        case .georgia: return "Georgia, serif"
        case .charter: return "Charter, Georgia, serif"
        case .newYork: return "ui-serif, 'New York', Georgia, serif"
        case .sans: return "-apple-system, 'Helvetica Neue', sans-serif"
        }
    }

    var preview: Font {
        switch self {
        case .iowan: return .custom("Iowan Old Style", size: 17)
        case .palatino: return .custom("Palatino", size: 17)
        case .georgia: return .custom("Georgia", size: 17)
        case .charter: return .custom("Charter", size: 17)
        case .newYork: return .system(size: 17, design: .serif)
        case .sans: return .system(size: 17)
        }
    }
}

extension ReadingTheme {
    var footerColor: UIColor {
        UIColor(hex: textHex).withAlphaComponent(0.45)
    }
}
