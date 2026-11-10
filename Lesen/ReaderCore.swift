import SwiftUI
import UIKit

/// Geometrie und Schrift einer Buchseite. Davon hängt die Seitenaufteilung ab.
struct PageLayout: Equatable {
    /// Breite einer einzelnen Buchseite (im Doppelseiten-Modus die halbe Breite des Buchs).
    var pageWidth: Int
    var height: Int
    /// true = aufgeschlagenes Buch mit zwei Seiten (Innendisplay), false = Einzelseite (Außendisplay).
    var spread: Bool
    var fontSize: Int
    var font: ReadingFont
    var lineHeight: Double
    var margin: Int
    /// Abstand des Textes zum oberen und unteren Seitenrand, Safe Area schon eingerechnet.
    var padTop = 26
    var padBottom = 44
    /// Innen = zum Buchfalz hin (bei der Einzelseite: links). Außen = zum Displayrand hin (Einzelseite: rechts).
    var padInner = -1
    var padOuter = -1
    /// Platz für Kapitel und Seitenzahl oben auf der linken (bzw. einzigen) und der rechten Seite.
    /// Leer = sie stehen unten.
    var headers: [CGRect] = []

    private var inner: Int { padInner >= 0 ? padInner : margin }
    private var outer: Int { padOuter >= 0 ? padOuter : margin }

    var size: CGSize { CGSize(width: pageWidth, height: height) }

    var contentSize: CGSize {
        CGSize(width: max(80, pageWidth - inner - outer), height: max(120, height - padTop - padBottom))
    }

    /// Linke obere Ecke des Textes auf einer Seite.
    func textOrigin(_ side: PageSide) -> CGPoint {
        CGPoint(x: CGFloat(side == .left ? outer : inner), y: CGFloat(padTop))
    }

    /// Fläche, die der Text auf einer Seite belegt.
    func textRect(_ side: PageSide) -> CGRect {
        CGRect(origin: textOrigin(side), size: contentSize)
    }

    /// Die Seitenaufteilung hängt nur von der Textfläche und der Schrift ab.
    var cacheKey: String {
        let content = contentSize
        return "\(Int(content.width))x\(Int(content.height))-\(font.rawValue)-\(fontSize)-\(Int(lineHeight * 100))"
    }
}

enum PageSide {
    case single
    case left
    case right
}

/// Welche Seite gemeint ist: fortlaufender Index, Kapitel und Seite im Kapitel.
struct PageSpec: Equatable {
    var index: Int
    /// -1 = leere Schlussseite, damit die Doppelseite aufgeht.
    var chapter: Int
    var page: Int
    var number: Int
    var title: String
    var side: PageSide
}

/// Alles, was zusätzlich zum Text auf der Seite liegt.
struct PageDecor: Equatable {
    var highlights: [NSRange] = []
    var selection: NSRange?
    var dogEar = false
}

/// Ein Zeichenauftrag für eine Seite. Enthält alles, damit er abseits des Hauptthreads laufen kann.
struct PageJob {
    let spec: PageSpec
    let decor: PageDecor
    let layout: PageLayout
    let theme: ReadingTheme
    let engine: BookEngine
    let scale: CGFloat
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

// MARK: - Seite als fertiges Bild zeichnen

/// Zeichnet eine komplette Seite in ein Bild. Läuft im Hintergrund, damit beim Umblättern
/// nur noch ein fertiges Bild gezeigt werden muss.
enum PageRenderer {
    static func render(_ job: PageJob) -> UIImage {
        let started = CACurrentMediaTime()
        let signpost = ReaderDiagnostics.signposter.beginInterval("Seite zeichnen")
        let layout = job.layout
        let chapter: ChapterLayout? = job.spec.chapter >= 0 ? job.engine.chapter(job.spec.chapter) : nil

        let format = UIGraphicsImageRendererFormat()
        format.scale = max(1, job.scale)
        format.opaque = true
        format.preferredRange = .standard
        let bounds = CGRect(origin: .zero, size: layout.size)
        let image = UIGraphicsImageRenderer(size: layout.size, format: format).image { renderer in
            draw(job, chapter: chapter, bounds: bounds, context: renderer.cgContext)
        }
        ReaderDiagnostics.signposter.endInterval("Seite zeichnen", signpost)
        ReaderDiagnostics.shared.recordRender(milliseconds: (CACurrentMediaTime() - started) * 1000)
        return image
    }

    private static func draw(_ job: PageJob, chapter: ChapterLayout?, bounds: CGRect, context: CGContext) {
        let theme = job.theme
        let spec = job.spec
        let origin = job.layout.textOrigin(spec.side)
        theme.background.setFill()
        context.fill(bounds)

        if let chapter {
            chapter.lock.lock()
            // Markierungen liegen unter dem Text
            let marker = theme.isDark
                ? UIColor(red: 0.85, green: 0.68, blue: 0.20, alpha: 0.38)
                : UIColor(red: 0.98, green: 0.80, blue: 0.25, alpha: 0.48)
            marker.setFill()
            for range in job.decor.highlights {
                for box in chapter.rects(for: range, page: spec.page) {
                    let shifted = box.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -1.5, dy: 0)
                    UIBezierPath(roundedRect: shifted, cornerRadius: 3).fill()
                }
            }
            if let selection = job.decor.selection {
                UIColor(red: 0.30, green: 0.50, blue: 0.85, alpha: 0.28).setFill()
                for box in chapter.rects(for: selection, page: spec.page) {
                    let shifted = box.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -1.5, dy: 0)
                    UIBezierPath(roundedRect: shifted, cornerRadius: 3).fill()
                }
            }
            chapter.draw(page: spec.page, at: origin)
            chapter.lock.unlock()
            drawFooter(job, bounds: bounds)
        }

        if spec.side != .single {
            drawSpineShadow(side: spec.side, theme: theme, bounds: bounds, context: context)
        }
        if job.decor.dogEar {
            drawDogEar(side: spec.side, theme: theme, bounds: bounds, context: context)
        }
    }

    private static func drawFooter(_ job: PageJob, bounds: CGRect) {
        let spec = job.spec
        guard spec.number > 0 else { return }
        let side = spec.side
        var text = job.layout.textRect(side)
        var y = text.maxY + 14
        let headers = job.layout.headers
        if !headers.isEmpty {
            // Kopfzeile im freien Streifen oben
            let line = headers[min(side == .right ? 1 : 0, headers.count - 1)]
            guard line.width > 60 else { return }
            text = line
            y = line.minY
        }
        let color = job.theme.footerColor
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
        let number = "\(spec.number)" as NSString
        let numberSize = number.size(withAttributes: numberAttributes)
        let titleWidth = max(0, text.width - numberSize.width - 12)
        if side == .left {
            number.draw(at: CGPoint(x: text.minX, y: y), withAttributes: numberAttributes)
            (spec.title as NSString).draw(
                in: CGRect(x: text.minX + numberSize.width + 12, y: y, width: titleWidth, height: 16),
                withAttributes: titleAttributes
            )
        } else {
            number.draw(at: CGPoint(x: text.maxX - numberSize.width, y: y), withAttributes: numberAttributes)
            (spec.title as NSString).draw(
                in: CGRect(x: text.minX, y: y, width: titleWidth, height: 16),
                withAttributes: titleAttributes
            )
        }
    }

    /// Schatten am Buchfalz, damit die Doppelseite wie ein aufgeschlagenes Buch wirkt.
    private static func drawSpineShadow(side: PageSide, theme: ReadingTheme, bounds: CGRect, context: CGContext) {
        let strength: CGFloat = theme.isDark ? 0.55 : 0.16
        let colors = [
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(strength * 0.3).cgColor,
            UIColor.black.withAlphaComponent(strength).cgColor
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                                        locations: [0, 0.65, 1]) else { return }
        let width: CGFloat = 30
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
    private static func drawDogEar(side: PageSide, theme: ReadingTheme, bounds: CGRect, context: CGContext) {
        let size: CGFloat = 34
        let outerX: CGFloat = side == .left ? 0 : bounds.width
        let direction: CGFloat = side == .left ? 1 : -1

        // Ecke „wegnehmen"
        let cut = UIBezierPath()
        cut.move(to: CGPoint(x: outerX, y: 0))
        cut.addLine(to: CGPoint(x: outerX + direction * size, y: 0))
        cut.addLine(to: CGPoint(x: outerX, y: size))
        cut.close()
        (theme.isDark ? UIColor.black : UIColor(white: 0.25, alpha: 1))
            .withAlphaComponent(theme.isDark ? 0.9 : 0.35).setFill()
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
        var alpha: CGFloat = 0
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        theme.background.getRed(&r, green: &g, blue: &b, alpha: &alpha)
        let shade: CGFloat = theme.isDark ? 1.6 : 0.93
        let lift: CGFloat = theme.isDark ? 0.08 : 0
        UIColor(red: min(1, r * shade + lift), green: min(1, g * shade + lift),
                blue: min(1, b * shade + lift), alpha: 1).setFill()
        fold.fill()
        context.restoreGState()
    }
}

// MARK: - Anzeige einer Seite

/// Zeigt das fertige Seitenbild. Hier wird beim Umblättern nichts mehr gezeichnet.
final class PageCanvas: UIView {
    private let picture = UIImageView()
    var side: PageSide = .single

    var image: UIImage? {
        get { picture.image }
        set {
            picture.image = newValue
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        clipsToBounds = true
        picture.isOpaque = true
        picture.contentMode = .scaleToFill
        addSubview(picture)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) wird nicht verwendet")
    }

    /// Das Bild behält seine Größe und liegt am Buchfalz an. Weicht die Fläche einmal von der
    /// berechneten Seitengröße ab, wird nichts verzerrt.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let size = picture.image?.size else { return }
        let x = side == .left ? bounds.width - size.width : 0
        picture.frame = CGRect(x: x, y: 0, width: size.width, height: size.height)
        if bounds.width > 0, abs(bounds.width - size.width) > 1 || abs(bounds.height - size.height) > 1 {
            ReaderDiagnostics.shared.noteMismatch(expected: size, actual: bounds.size)
        }
    }
}

// MARK: - Einzelne Buchseite

final class PageVC: UIViewController {
    /// Fortlaufender Seitenindex über das ganze Buch.
    let index: Int
    let spec: PageSpec?

    private weak var model: ReaderModel?
    private let theme: ReadingTheme
    private let side: PageSide
    private let canvas = PageCanvas(frame: .zero)
    private var shownDecor: PageDecor?

    init(index: Int, spec: PageSpec?, model: ReaderModel, theme: ReadingTheme, side: PageSide) {
        self.index = index
        self.spec = spec
        self.model = model
        self.theme = theme
        self.side = side
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) wird nicht verwendet")
    }

    override func loadView() {
        canvas.side = side
        canvas.backgroundColor = theme.background
        view = canvas
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard spec != nil else { return }
        refresh(allowSync: true, counted: true)

        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        press.minimumPressDuration = 0.35
        canvas.addGestureRecognizer(press)
    }

    /// Holt das passende Seitenbild. Liegt es noch nicht bereit, wird es entweder im Hintergrund
    /// angefordert oder – wenn die Seite sofort gebraucht wird – ausnahmsweise direkt gezeichnet.
    func refresh(allowSync: Bool, counted: Bool) {
        guard let spec, let model, let job = model.job(for: spec) else { return }
        if canvas.image != nil, shownDecor == job.decor { return }
        if let ready = model.pages.image(spec.index, decor: job.decor) {
            canvas.image = ready
            shownDecor = job.decor
        } else if allowSync {
            canvas.image = model.pages.renderNow(job, counted: counted)
            shownDecor = job.decor
        } else {
            model.pages.request(job)
        }
    }

    /// Liegt der Punkt in der äußeren oberen Ecke (Eselsohr-Zone)?
    func isCorner(_ point: CGPoint) -> Bool {
        guard let spec, spec.chapter >= 0, point.y < 76 else { return false }
        return side == .left ? point.x < 76 : point.x > view.bounds.width - 76
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let spec, spec.chapter >= 0, let model, let layout = model.layout,
              let chapterLayout = model.engine.chapter(spec.chapter) else { return }
        let location = recognizer.location(in: canvas)
        let origin = layout.textOrigin(side)
        let shift = side == .left ? canvas.bounds.width - CGFloat(layout.pageWidth) : 0
        let point = CGPoint(x: location.x - origin.x - shift, y: location.y - origin.y)
        guard let index = chapterLayout.characterIndex(at: point, page: spec.page),
              let word = chapterLayout.wordRange(at: index) else { return }
        let sentence = chapterLayout.sentenceRange(at: index) ?? word
        let existing = model.highlights.first {
            $0.chapter == spec.chapter && NSLocationInRange(index, NSRange(location: $0.start, length: $0.length))
        }
        Haptics.medium()
        model.select(TextSelection(
            chapter: spec.chapter,
            word: word,
            sentence: existing.map { NSRange(location: $0.start, length: $0.length) } ?? sentence,
            wordText: chapterLayout.string(in: word),
            sentenceText: existing?.text ?? chapterLayout.string(in: sentence),
            highlightID: existing?.id
        ))
    }
}
