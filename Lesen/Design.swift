import SwiftUI

// Klassisches Design: Holzregal, warme Farben, Messing, Papier.

enum Wood {
    static let brass = Color(red: 0.72, green: 0.56, blue: 0.27)
    static let brassLight = Color(red: 0.91, green: 0.79, blue: 0.50)
    static let brassDark = Color(red: 0.47, green: 0.34, blue: 0.13)

    static let boardTop = Color(red: 0.66, green: 0.47, blue: 0.29)
    static let boardFront = Color(red: 0.45, green: 0.29, blue: 0.16)
    static let boardFrontDark = Color(red: 0.27, green: 0.16, blue: 0.08)
    static let back = Color(red: 0.33, green: 0.21, blue: 0.12)
    static let backDark = Color(red: 0.20, green: 0.12, blue: 0.06)

    static let wallLight = Color(red: 0.95, green: 0.91, blue: 0.83)
    static let wallLightLow = Color(red: 0.89, green: 0.83, blue: 0.72)
    static let wallDark = Color(red: 0.13, green: 0.10, blue: 0.08)
    static let wallDarkLow = Color(red: 0.08, green: 0.06, blue: 0.05)

    static let ink = Color(red: 0.23, green: 0.16, blue: 0.10)
    static let ribbon = Color(red: 0.62, green: 0.13, blue: 0.14)
}

/// Lichtstimmung nach Tageszeit.
enum DayLight {
    case morning
    case day
    case evening
    case night

    static var current: DayLight {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 6..<10: return .morning
        case 10..<17: return .day
        case 17..<21: return .evening
        default: return .night
        }
    }

    var greeting: String {
        switch self {
        case .morning: return "Guten Morgen"
        case .day: return "Guten Tag"
        case .evening: return "Guten Abend"
        case .night: return "Gute Nacht"
        }
    }

    /// Farbe und Position der Lichtquelle.
    var glow: (color: Color, center: UnitPoint, strength: Double) {
        switch self {
        case .morning: return (Color(red: 1.0, green: 0.97, blue: 0.88), .topLeading, 0.55)
        case .day: return (Color.white, .top, 0.35)
        case .evening: return (Color(red: 1.0, green: 0.72, blue: 0.38), .topTrailing, 0.50)
        case .night: return (Color(red: 1.0, green: 0.66, blue: 0.30), .topTrailing, 0.34)
        }
    }

    /// Wie stark der Raum abgedunkelt wird.
    var dim: Double {
        switch self {
        case .morning: return 0
        case .day: return 0
        case .evening: return 0.10
        case .night: return 0.26
        }
    }
}

/// Wand hinter dem Regal mit feinem Tapetenmuster und Licht je nach Tageszeit.
struct RoomBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    let light: DayLight

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            LinearGradient(
                colors: dark ? [Wood.wallDark, Wood.wallDarkLow] : [Wood.wallLight, Wood.wallLightLow],
                startPoint: .top,
                endPoint: .bottom
            )
            // Tapete: feine senkrechte Streifen
            Canvas { context, size in
                let step: CGFloat = 26
                var x: CGFloat = 0
                while x < size.width {
                    let rect = CGRect(x: x, y: 0, width: step / 2, height: size.height)
                    context.fill(Path(rect), with: .color((dark ? Color.white : Wood.ink).opacity(dark ? 0.018 : 0.028)))
                    x += step
                }
            }
            RadialGradient(
                colors: [light.glow.color.opacity(light.glow.strength * (dark ? 0.45 : 1)), .clear],
                center: light.glow.center,
                startRadius: 10,
                endRadius: 560
            )
            .blendMode(dark ? .plusLighter : .softLight)
            Color.black.opacity(dark ? 0 : light.dim)
        }
    }
}

/// Maserung als feine, leicht versetzte Linien.
struct WoodGrain: View {
    var lines = 7
    var opacity = 0.16

    var body: some View {
        Canvas { context, size in
            for index in 0..<lines {
                let base = size.height * (CGFloat(index) + 0.5) / CGFloat(lines)
                var path = Path()
                path.move(to: CGPoint(x: 0, y: base))
                var x: CGFloat = 0
                var phase = CGFloat(index) * 1.7
                while x < size.width {
                    x += 46
                    phase += 0.9
                    path.addQuadCurve(
                        to: CGPoint(x: x, y: base + sin(phase) * 1.1),
                        control: CGPoint(x: x - 23, y: base + cos(phase * 1.3) * 1.6)
                    )
                }
                context.stroke(path, with: .color(.black.opacity(opacity)), lineWidth: 0.7)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Regalbrett: Oberkante mit Lichtkante, Vorderkante mit Maserung, Schatten darunter.
struct ShelfBoard: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(LinearGradient(colors: [Wood.boardTop.opacity(0.95), Wood.boardTop], startPoint: .top, endPoint: .bottom))
                .frame(height: 7)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.white.opacity(0.22)).frame(height: 1)
                }
            Rectangle()
                .fill(LinearGradient(colors: [Wood.boardFront, Wood.boardFrontDark], startPoint: .top, endPoint: .bottom))
                .frame(height: 15)
                .overlay(WoodGrain(lines: 4, opacity: 0.22))
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.black.opacity(0.25)).frame(height: 1)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2.5))
        .shadow(color: .black.opacity(0.45), radius: 9, y: 8)
    }
}

/// Rückwand eines Regalfachs. Die Bücher stehen davor.
struct ShelfNiche: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Wood.backDark, Wood.back], startPoint: .top, endPoint: .bottom)
            WoodGrain(lines: 9, opacity: 0.20)
            // Schatten, den das obere Brett und die Seitenwände werfen
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .center)
            HStack {
                LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 18)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 18)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

/// Graviertes Messingschild für den Namen eines Regals.
struct BrassPlate: View {
    let text: String

    var body: some View {
        HStack(spacing: 9) {
            screw
            Text(text.uppercased())
                .font(.system(size: 11.5, weight: .semibold, design: .serif))
                .tracking(1.6)
                .foregroundStyle(Wood.brassDark)
                .shadow(color: .white.opacity(0.45), radius: 0, y: 0.6)
                .lineLimit(1)
            screw
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(colors: [Wood.brassLight, Wood.brass, Wood.brassLight.opacity(0.9), Wood.brass],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Wood.brassDark.opacity(0.55), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.3), radius: 2.5, y: 1.5)
    }

    private var screw: some View {
        Circle()
            .fill(RadialGradient(colors: [Wood.brassLight, Wood.brassDark], center: .topLeading, startRadius: 0, endRadius: 5))
            .frame(width: 5, height: 5)
            .overlay(Rectangle().fill(Wood.brassDark.opacity(0.7)).frame(width: 4, height: 0.6).rotationEffect(.degrees(35)))
    }
}

/// Karte aus cremefarbenem Papier.
struct PaperCard: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        content
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(dark ? Color(red: 0.19, green: 0.15, blue: 0.12) : Color(red: 0.99, green: 0.97, blue: 0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(dark ? Color.white.opacity(0.07) : Wood.ink.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(dark ? 0.5 : 0.18), radius: 10, y: 5)
    }
}

extension View {
    func paperCard() -> some View {
        modifier(PaperCard())
    }
}

struct BookPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .rotation3DEffect(.degrees(configuration.isPressed ? -16 : 0), axis: (x: 0, y: 1, z: 0),
                              anchor: .leading, perspective: 0.5)
            .scaleEffect(configuration.isPressed ? 1.05 : 1, anchor: .bottom)
            .offset(y: configuration.isPressed ? -7 : 0)
            .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
