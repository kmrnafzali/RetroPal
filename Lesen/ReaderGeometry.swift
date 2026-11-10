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

    /// Platz für die Kopfzeile je Seite (in Bildschirmkoordinaten), wenn oben ohnehin ein Streifen
    /// frei bleiben muss. Leer = Seitenzahl steht wie gewohnt unten.
    var headers: [CGRect] = []

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

        // Aufgeschlagenes Buch nur, wenn jede Seite breit genug zum Lesen bleibt.
        let spread = area.width >= 800 || (spine != nil && area.width >= 560)
        var left = max(0, insets.left)
        var right = max(0, insets.right)

        // Verdeckte Bereiche (Kamera, Statusfeld der Seitenleiste).
        let holes = occlusions.map { $0.intersection(area) }.filter { !$0.isNull && $0.width >= 1 && $0.height >= 1 }
        for hole in holes {
            if hole.maxX <= left || hole.minX >= full.width - right { continue }
            if hole.maxY <= top || hole.minY >= area.height - bottom { continue }
            if hole.maxY <= area.height * 0.3 {
                top = max(top, hole.maxY)
            } else if hole.minY >= area.height * 0.7 {
                bottom = max(bottom, area.height - hole.minY)
            } else if hole.midX < full.width * 0.5 {
                left = max(left, hole.maxX)
            } else {
                right = max(right, full.width - hole.minX)
            }
        }
        top = min(top, 120)
        bottom = min(bottom, 100)
        left = min(left, 140)
        right = min(right, 140)

        // Bleibt oben ohnehin ein hoher Streifen frei, wandern Kapitel und Seitenzahl dorthin
        // (wie die Kopfzeile in einem gedruckten Buch) und der Text reicht dafür weiter nach unten.
        let headerMode = !holes.isEmpty && top >= 56
        let padTop = headerMode ? Int(top.rounded(.up)) + 6 : max(30, Int(top.rounded(.up)) + (top >= 50 ? 8 : 16))
        let padBottom = headerMode ? max(22, Int(bottom.rounded(.up)) + 12) : max(44, Int(bottom.rounded(.up)) + 34)
        let height = Int(area.height.rounded(.down))

        var result: ReaderMetrics
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
            result = ReaderMetrics(pagerFrame: pager, spread: true, pageWidth: Int(half), height: height,
                                   padTop: padTop, padBottom: padBottom, padInner: inner, padOuter: outer, panel: panel)
        } else {
            let width = Int(area.width.rounded(.down))
            let pager = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            var inner = Int(left.rounded(.up)) + margin
            var outer = Int(right.rounded(.up)) + margin
            // Sehr breite Einzelseite: Zeilen nicht länger als gut lesbar.
            let extra = (width - inner - outer - 620) / 2
            if extra > 0 {
                inner += extra
                outer += extra
            }
            result = ReaderMetrics(pagerFrame: pager, spread: false, pageWidth: width, height: height,
                                   padTop: padTop, padBottom: padBottom, padInner: inner, padOuter: outer, panel: panel)
        }

        if headerMode {
            let layout = result.layout(fontSize: 18, font: .iowan, lineHeight: 1.5, margin: margin)
            let lineY = CGFloat(padTop) - 30
            result.headers = result.textRects(layout).map { column in
                // Freies Stück der Zeile neben den verdeckten Bereichen suchen
                var free = [(column.minX, column.maxX)]
                for hole in holes where hole.maxY > lineY - 4 && hole.minY < lineY + 20 {
                    var next: [(CGFloat, CGFloat)] = []
                    for (start, end) in free {
                        if hole.maxX <= start || hole.minX >= end {
                            next.append((start, end))
                            continue
                        }
                        if hole.minX - 10 > start { next.append((start, hole.minX - 10)) }
                        if hole.maxX + 10 < end { next.append((hole.maxX + 10, end)) }
                    }
                    free = next
                }
                guard let best = free.max(by: { $0.1 - $0.0 < $1.1 - $1.0 }), best.1 - best.0 >= 110 else {
                    return CGRect.zero
                }
                return CGRect(x: best.0, y: lineY, width: best.1 - best.0, height: 16)
            }
        }
        return result
    }

    func layout(fontSize: Int, font: ReadingFont, lineHeight: Double, margin: Int) -> PageLayout {
        PageLayout(pageWidth: pageWidth, height: height, spread: spread, fontSize: fontSize, font: font,
                   lineHeight: lineHeight, margin: margin, padTop: padTop, padBottom: padBottom,
                   padInner: padInner, padOuter: padOuter, headers: pageHeaders)
    }

    /// Kopfzeilen in Seitenkoordinaten (für die linke bzw. einzige und die rechte Seite).
    var pageHeaders: [CGRect] {
        headers.enumerated().map { index, rect in
            rect.width <= 0 ? .zero : rect.offsetBy(dx: -pagerFrame.minX - CGFloat(index * pageWidth), dy: -pagerFrame.minY)
        }
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
