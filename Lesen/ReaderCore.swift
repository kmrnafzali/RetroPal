import SwiftUI
import UIKit

/// Geometrie und Schrift einer Buchseite. Davon hängt die Seitenaufteilung ab.
struct PageLayout: Equatable {
    /// Breite einer einzelnen Buchseite (im Doppelseiten-Modus die halbe Bildschirmbreite).
    var pageWidth: Int
    var height: Int
    /// true = aufgeschlagenes Buch mit zwei Seiten (Innendisplay), false = Einzelseite (Außendisplay).
    var spread: Bool
    var fontSize: Int
    var font: ReadingFont
    var lineHeight: Double
    var margin: Int

    var topPad: Int { 26 }
    var bottomPad: Int { 44 }
    var size: CGSize { CGSize(width: pageWidth, height: height) }

    var contentSize: CGSize {
        CGSize(width: max(80, pageWidth - 2 * margin), height: max(120, height - topPad - bottomPad))
    }

    var cacheKey: String {
        "\(pageWidth)x\(height)-\(font.rawValue)-\(fontSize)-\(Int(lineHeight * 100))-\(margin)"
    }
}

enum PageSide {
    case single
    case left
    case right
}

struct PageInfo {
    var chapter: Int
    var page: Int
    var number: Int
    var title: String
}

/// Vom Leser angetippte Textstelle.
struct TextSelection: Equatable {
    var chapter: Int
    var word: NSRange
    var sentence: NSRange
    var wordText: String
    var sentenceText: String
    var highlightID: UUID?
}

// MARK: - Zeichenfläche einer Seite

final class PageCanvas: UIView {
    var chapterLayout: ChapterLayout?
    var page = 0
    var textOrigin = CGPoint.zero
    var theme: ReadingTheme = .paper
    var side: PageSide = .single
    var margin: CGFloat = 24
    var footerTitle = ""
    var footerNumber = ""
    var highlights: [NSRange] = []
    var selection: NSRange?
    var dogEar = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) wird nicht verwendet")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let bounds = self.bounds
        theme.background.setFill()
        context.fill(bounds)

        if let chapterLayout {
            // Markierungen liegen unter dem Text
            let marker = theme.isDark
                ? UIColor(red: 0.85, green: 0.68, blue: 0.20, alpha: 0.38)
                : UIColor(red: 0.98, green: 0.80, blue: 0.25, alpha: 0.48)
            marker.setFill()
            for range in highlights {
                for box in chapterLayout.rects(for: range, page: page) {
                    let shifted = box.offsetBy(dx: textOrigin.x, dy: textOrigin.y).insetBy(dx: -1.5, dy: 0)
                    UIBezierPath(roundedRect: shifted, cornerRadius: 3).fill()
                }
            }
            if let selection {
                UIColor(red: 0.30, green: 0.50, blue: 0.85, alpha: 0.28).setFill()
                for box in chapterLayout.rects(for: selection, page: page) {
                    let shifted = box.offsetBy(dx: textOrigin.x, dy: textOrigin.y).insetBy(dx: -1.5, dy: 0)
                    UIBezierPath(roundedRect: shifted, cornerRadius: 3).fill()
                }
            }
            chapterLayout.draw(page: page, at: textOrigin)
        }

        drawFooter(in: bounds)
        if side != .single {
            drawSpineShadow(in: bounds, context: context)
        }
        if dogEar {
            drawDogEar(in: bounds, context: context)
        }
    }

    private func drawFooter(in bounds: CGRect) {
        guard !footerNumber.isEmpty else { return }
        let color = theme.footerColor
        let numberAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: color
        ]
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.lineBreakMode = .byTruncatingTail
        titleStyle.alignment = side == .left ? .right : .left
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: color,
            .kern: 0.6,
            .paragraphStyle: titleStyle
        ]
        let y = bounds.height - 29
        let number = footerNumber as NSString
        let numberSize = number.size(withAttributes: numberAttributes)
        let titleWidth = max(0, bounds.width - 2 * margin - numberSize.width - 12)
        if side == .left {
            number.draw(at: CGPoint(x: margin, y: y), withAttributes: numberAttributes)
            (footerTitle as NSString).draw(
                in: CGRect(x: margin + numberSize.width + 12, y: y, width: titleWidth, height: 16),
                withAttributes: titleAttributes
            )
        } else {
            number.draw(at: CGPoint(x: bounds.width - margin - numberSize.width, y: y), withAttributes: numberAttributes)
            (footerTitle as NSString).draw(
                in: CGRect(x: margin, y: y, width: titleWidth, height: 16),
                withAttributes: titleAttributes
            )
        }
    }

    /// Schatten am Buchfalz, damit die Doppelseite wie ein aufgeschlagenes Buch wirkt.
    private func drawSpineShadow(in bounds: CGRect, context: CGContext) {
        let strength: CGFloat = theme.isDark ? 0.55 : 0.16
        let colors = [
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(strength * 0.3).cgColor,
            UIColor.black.withAlphaComponent(strength).cgColor
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.65, 1]) else { return }
        let width: CGFloat = 38
        context.saveGState()
        if side == .left {
            context.clip(to: CGRect(x: bounds.width - width, y: 0, width: width, height: bounds.height))
            context.drawLinearGradient(gradient, start: CGPoint(x: bounds.width - width, y: 0),
                                       end: CGPoint(x: bounds.width, y: 0), options: [])
        } else {
            context.clip(to: CGRect(x: 0, y: 0, width: width, height: bounds.height))
            context.drawLinearGradient(gradient, start: CGPoint(x: width, y: 0), end: CGPoint(x: 0, y: 0), options: [])
        }
        context.restoreGState()
    }

    /// Eselsohr an der äußeren oberen Ecke als Lesezeichen.
    private func drawDogEar(in bounds: CGRect, context: CGContext) {
        let size: CGFloat = 34
        let outerX: CGFloat = side == .left ? 0 : bounds.width
        let direction: CGFloat = side == .left ? 1 : -1

        // Ecke „wegnehmen"
        let cut = UIBezierPath()
        cut.move(to: CGPoint(x: outerX, y: 0))
        cut.addLine(to: CGPoint(x: outerX + direction * size, y: 0))
        cut.addLine(to: CGPoint(x: outerX, y: size))
        cut.close()
        (theme.isDark ? UIColor.black : UIColor(white: 0.25, alpha: 1)).withAlphaComponent(theme.isDark ? 0.9 : 0.35).setFill()
        cut.fill()

        // Umgeknickte Rückseite
        let fold = UIBezierPath()
        fold.move(to: CGPoint(x: outerX + direction * size, y: 0))
        fold.addLine(to: CGPoint(x: outerX + direction * size, y: size))
        fold.addLine(to: CGPoint(x: outerX, y: size))
        fold.close()
        context.saveGState()
        context.setShadow(offset: CGSize(width: direction * 1.5, height: 2), blur: 5,
                          color: UIColor.black.withAlphaComponent(0.35).cgColor)
        let paper = theme.background
        var alpha: CGFloat = 0
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        paper.getRed(&r, green: &g, blue: &b, alpha: &alpha)
        let shade: CGFloat = theme.isDark ? 1.6 : 0.93
        UIColor(red: min(1, r * shade + (theme.isDark ? 0.08 : 0)), green: min(1, g * shade + (theme.isDark ? 0.08 : 0)),
                blue: min(1, b * shade + (theme.isDark ? 0.08 : 0)), alpha: 1).setFill()
        fold.fill()
        context.restoreGState()
    }
}

// MARK: - Einzelne Buchseite

final class PageVC: UIViewController {
    /// Fortlaufender Seitenindex über das ganze Buch.
    let index: Int
    let info: PageInfo?

    private weak var model: ReaderModel?
    private let layout: PageLayout
    private let theme: ReadingTheme
    private let side: PageSide
    private let canvas = PageCanvas(frame: .zero)

    init(index: Int, info: PageInfo?, model: ReaderModel, layout: PageLayout, theme: ReadingTheme, side: PageSide) {
        self.index = index
        self.info = info
        self.model = model
        self.layout = layout
        self.theme = theme
        self.side = side
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) wird nicht verwendet")
    }

    override func loadView() {
        canvas.theme = theme
        canvas.side = side
        canvas.margin = CGFloat(layout.margin)
        canvas.textOrigin = CGPoint(x: CGFloat(layout.margin), y: CGFloat(layout.topPad))
        canvas.backgroundColor = theme.background
        view = canvas
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let info, let model else { return }
        canvas.chapterLayout = model.engine.chapter(info.chapter)
        canvas.page = info.page
        canvas.footerTitle = info.title.uppercased()
        canvas.footerNumber = "\(info.number)"
        reloadDecor()

        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        press.minimumPressDuration = 0.35
        canvas.addGestureRecognizer(press)
    }

    /// Zeichenbereich dieser Seite im Kapiteltext.
    var characterRange: NSRange? {
        guard let info, let chapterLayout = canvas.chapterLayout, info.page < chapterLayout.pageCount else { return nil }
        return chapterLayout.pageRanges[info.page]
    }

    /// Markierungen, Auswahl und Eselsohr neu einlesen.
    func reloadDecor() {
        guard let info, let model else { return }
        canvas.highlights = model.highlights.filter { $0.chapter == info.chapter }
            .map { NSRange(location: $0.start, length: $0.length) }
        if let selection = model.selection, selection.chapter == info.chapter {
            canvas.selection = selection.highlightID == nil ? selection.sentence : nil
        } else {
            canvas.selection = nil
        }
        if let range = characterRange {
            canvas.dogEar = model.hasBookmark(chapter: info.chapter, range: range)
        }
        canvas.setNeedsDisplay()
    }

    /// Liegt der Punkt in der äußeren oberen Ecke (Eselsohr-Zone)?
    func isCorner(_ point: CGPoint) -> Bool {
        guard info != nil, point.y < 76 else { return false }
        return side == .left ? point.x < 76 : point.x > view.bounds.width - 76
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let info, let model,
              let chapterLayout = canvas.chapterLayout else { return }
        let location = recognizer.location(in: canvas)
        let point = CGPoint(x: location.x - canvas.textOrigin.x, y: location.y - canvas.textOrigin.y)
        guard let index = chapterLayout.characterIndex(at: point, page: info.page),
              let word = chapterLayout.wordRange(at: index) else { return }
        let sentence = chapterLayout.sentenceRange(at: index) ?? word
        let existing = model.highlights.first {
            $0.chapter == info.chapter && NSLocationInRange(index, NSRange(location: $0.start, length: $0.length))
        }
        Haptics.medium()
        model.select(TextSelection(
            chapter: info.chapter,
            word: word,
            sentence: existing.map { NSRange(location: $0.start, length: $0.length) } ?? sentence,
            wordText: chapterLayout.string(in: word),
            sentenceText: existing?.text ?? chapterLayout.string(in: sentence),
            highlightID: existing?.id
        ))
    }
}
