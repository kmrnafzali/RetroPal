import SwiftUI
import UIKit

/// Ein Buch von vorn: Coverbild oder gestaltetes Ersatzcover, mit Buchrücken-Glanz und Seitenkante.
struct CoverArt: View {
    let image: UIImage?
    let title: String
    let author: String

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let edge = max(1.5, w * 0.022)

            ZStack(alignment: .topLeading) {
                // Seitenblock, der rechts und unten hervorschaut
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.96, green: 0.94, blue: 0.88), Color(red: 0.80, green: 0.77, blue: 0.70)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: w - edge, height: h - edge)
                    .offset(x: edge, y: edge)

                ZStack {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: w - edge, height: h - edge)
                            .clipped()
                    } else {
                        GeneratedCover(title: title, author: author)
                    }

                    // Falz und Glanz am Buchrücken
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.30), location: 0),
                            .init(color: .white.opacity(0.22), location: 0.035),
                            .init(color: .black.opacity(0.12), location: 0.07),
                            .init(color: .clear, location: 0.13)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )

                    // Sanfter Lichtverlauf über das ganze Cover
                    LinearGradient(
                        colors: [.white.opacity(0.10), .clear, .black.opacity(0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
                .frame(width: w - edge, height: h - edge)
                .clipShape(RoundedRectangle(cornerRadius: max(2, w * 0.02)))
            }
        }
        .shadow(color: .black.opacity(0.32), radius: 5, x: 3, y: 5)
    }
}

/// Typografisches Leinen-Cover für Bücher ohne Coverbild.
struct GeneratedCover: View {
    let title: String
    let author: String

    private static let palette: [(Double, Double, Double)] = [
        (0.16, 0.22, 0.36), // Nachtblau
        (0.40, 0.13, 0.16), // Bordeaux
        (0.13, 0.30, 0.25), // Tannengrün
        (0.33, 0.24, 0.16), // Leder
        (0.24, 0.18, 0.34), // Aubergine
        (0.15, 0.31, 0.37), // Petrol
        (0.22, 0.22, 0.24), // Graphit
        (0.44, 0.27, 0.12)  // Cognac
    ]

    private var base: Color {
        let seed = title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 9973 }
        let c = GeneratedCover.palette[seed % GeneratedCover.palette.count]
        return Color(red: c.0, green: c.1, blue: c.2)
    }

    private let gold = Color(red: 0.86, green: 0.74, blue: 0.48)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                base
                LinearGradient(colors: [.white.opacity(0.08), .black.opacity(0.22)],
                               startPoint: .top, endPoint: .bottom)

                RoundedRectangle(cornerRadius: 1)
                    .stroke(gold.opacity(0.85), lineWidth: max(0.6, w * 0.008))
                    .padding(w * 0.075)
                RoundedRectangle(cornerRadius: 1)
                    .stroke(gold.opacity(0.5), lineWidth: max(0.4, w * 0.004))
                    .padding(w * 0.095)

                VStack(spacing: h * 0.03) {
                    Spacer(minLength: 0)
                    Text(title)
                        .font(.system(size: max(8, w * 0.115), weight: .semibold, design: .serif))
                        .multilineTextAlignment(.center)
                        .lineLimit(5)
                        .minimumScaleFactor(0.55)
                    Rectangle()
                        .fill(gold.opacity(0.8))
                        .frame(width: w * 0.22, height: max(0.6, w * 0.006))
                    Spacer(minLength: 0)
                    if !author.isEmpty {
                        Text(author.uppercased())
                            .font(.system(size: max(5, w * 0.055), weight: .medium, design: .serif))
                            .tracking(w * 0.008)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                    }
                }
                .foregroundStyle(gold)
                .padding(.horizontal, w * 0.15)
                .padding(.vertical, h * 0.12)
            }
        }
    }
}

/// Lesebändchen, das den Fortschritt zeigt.
struct Ribbon: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width
                let h = geo.size.height
                path.move(to: .zero)
                path.addLine(to: CGPoint(x: w, y: 0))
                path.addLine(to: CGPoint(x: w, y: h))
                path.addLine(to: CGPoint(x: w / 2, y: h - w * 0.45))
                path.addLine(to: CGPoint(x: 0, y: h))
                path.closeSubpath()
            }
            .fill(
                LinearGradient(colors: [Color(red: 0.80, green: 0.20, blue: 0.20), Color(red: 0.62, green: 0.12, blue: 0.14)],
                               startPoint: .top, endPoint: .bottom)
            )
            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
        }
    }
}
