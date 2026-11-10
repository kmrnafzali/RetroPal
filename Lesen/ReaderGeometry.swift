import UIKit

/// Lage des Falzes beim iPhone Duo.
struct FoldInfo: Equatable {
    /// Bereich, der frei bleiben soll (Falzlinie plus Sicherheitsabstand), in Bildschirmkoordinaten.
    var frame: CGRect
    /// Aktiv = das Gerät ist halb aufgeklappt, der Falz teilt die Fläche spürbar.
    var isActive: Bool
}

/// Rechnet aus Bildschirmgröße, Safe Areas, Falz und verdeckten Bereichen aus,
/// wo das Buch liegt und wie viel Rand der Text auf jeder Seite braucht.
/// Alle Angaben beziehen sich auf den ganzen Bildschirm, nicht auf die Safe Area.
struct ReaderMetrics: Equatable {
    /// Fläche des Buchs. Bei der Doppelseite liegt ihre Mitte genau auf dem Falz.
    var pagerFrame: CGRect
    var spread: Bool
    var pageWidth: Int
    var height: Int
    var padTop: Int
    var padBottom: Int
    var padInner: Int
    var padOuter: Int
    /// Fläche für die Steuerung unter dem Falz, wenn das Duo halb aufgeklappt auf dem Tisch steht.
    var panel: CGRect?

    static let empty = ReaderMetrics(pagerFrame: .zero, spread: false, pageWidth: 0, height: 0,
                                     padTop: 0, padBottom: 0, padInner: 0, padOuter: 0, panel: nil)

    static func make(full: CGSize, insets: UIEdgeInsets, fold: FoldInfo?, occlusions: [CGRect],
                     margin: Int) -> ReaderMetrics {
        guard full.width > 100, full.height > 100 else { return .empty }
        var area = CGRect(origin: .zero, size: full)
        var top = max(0, insets.top)
        var bottom = max(0, insets.bottom)
        var panel: CGRect?

        // Tisch-Modus: Falz liegt quer, oben die Seite, unten die Steuerung.
        if let fold, fold.isActive, fold.frame.width > fold.frame.height,
           fold.frame.minY > 220, full.height - fold.frame.maxY > 140 {
            area.size.height = floor(fold.frame.minY)
            panel = CGRect(x: 0, y: fold.frame.maxY, width: full.width, height: full.height - fold.frame.maxY)
            bottom = 0
        }

        // Senkrechter Falz ungefähr in der Mitte: dort liegt der Buchrücken.
        var spine: FoldInfo?
        if let fold, fold.frame.height >= fold.frame.width,
           fold.frame.midX > full.width * 0.3, fold.frame.midX < full.width * 0.7 {
            spine = fold
        }

        let spread = area.width >= 560
        var left = max(0, insets.left)
        var right = max(0, insets.right)

        // Verdeckte Bereiche (z. B. Kamera), die nicht schon in der Safe Area liegen.
        for hole in occlusions {
            let clipped = hole.intersection(area)
            if clipped.isNull || clipped.width < 1 || clipped.height < 1 { continue }
            if clipped.maxX <= left || clipped.minX >= full.width - right { continue }
            if clipped.maxY <= top || clipped.minY >= area.height - bottom { continue }
            if clipped.maxY <= area.height * 0.3 {
                top = max(top, clipped.maxY)
            } else if clipped.minY >= area.height * 0.7 {
                bottom = max(bottom, area.height - clipped.minY)
            } else if clipped.midX < full.width * 0.5 {
                left = max(left, clipped.maxX)
            } else {
                right = max(right, full.width - clipped.minX)
            }
        }
        top = min(top, 120)
        bottom = min(bottom, 100)
        left = min(left, 140)
        right = min(right, 140)

        let padTop = max(30, Int(top.rounded(.up)) + 16)
        let padBottom = max(44, Int(bottom.rounded(.up)) + 34)
        let height = Int(area.height.rounded(.down))

        if spread {
            let centre = spine?.frame.midX ?? full.width / 2
            let half = floor(min(centre, full.width - centre))
            let pager = CGRect(x: centre - half, y: 0, width: half * 2, height: CGFloat(height))
            // Beide Seiten bekommen denselben Außenrand, damit sie gleich viel Text fassen.
            let outerLeft = max(0, left - pager.minX)
            let outerRight = max(0, pager.maxX - (full.width - right))
            let outer = Int(max(outerLeft, outerRight).rounded(.up)) + margin + 6
            // Am Falz bleibt dessen Sicherheitsabstand frei, dazu ein schmaler Bundsteg.
            let gutter = max(16, Int(((spine?.frame.width ?? 32) / 2).rounded(.up)))
            let inner = gutter + max(10, margin / 2)
            return ReaderMetrics(pagerFrame: pager, spread: true, pageWidth: Int(half), height: height,
                                 padTop: padTop, padBottom: padBottom, padInner: inner, padOuter: outer, panel: panel)
        }

        let width = Int(area.width.rounded(.down))
        let pager = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        return ReaderMetrics(pagerFrame: pager, spread: false, pageWidth: width, height: height,
                             padTop: padTop, padBottom: padBottom,
                             padInner: Int(left.rounded(.up)) + margin, padOuter: Int(right.rounded(.up)) + margin,
                             panel: panel)
    }

    func layout(fontSize: Int, font: ReadingFont, lineHeight: Double, margin: Int) -> PageLayout {
        PageLayout(pageWidth: pageWidth, height: height, spread: spread, fontSize: fontSize, font: font,
                   lineHeight: lineHeight, margin: margin, padTop: padTop, padBottom: padBottom,
                   padInner: padInner, padOuter: padOuter)
    }

    /// Textflächen aller Seiten in Bildschirmkoordinaten (für Tests und Diagnose).
    func textRects(_ layout: PageLayout) -> [CGRect] {
        if spread {
            let leftPage = layout.textRect(.left).offsetBy(dx: pagerFrame.minX, dy: pagerFrame.minY)
            let rightPage = layout.textRect(.right)
                .offsetBy(dx: pagerFrame.minX + CGFloat(pageWidth), dy: pagerFrame.minY)
            return [leftPage, rightPage]
        }
        return [layout.textRect(.single).offsetBy(dx: pagerFrame.minX, dy: pagerFrame.minY)]
    }
}
