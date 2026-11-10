import SwiftUI
import XCTest
@testable import Lesen

/// Baut ein künstliches Buch, prüft den Lesemotor und legt Bildschirmfotos der wichtigsten Ansichten ab.
@MainActor
final class PreviewTests: XCTestCase {
    private let output = URL(fileURLWithPath: "/tmp/lesen-shots", isDirectory: true)

    private static let words = [
        "Morgen", "der", "Wind", "über", "dem", "Hafen", "trug", "den", "Geruch", "von", "Salz", "und", "Teer",
        "langsam", "ging", "sie", "die", "Gasse", "hinauf", "wo", "alte", "Laternen", "noch", "brannten",
        "niemand", "sprach", "ein", "Wort", "bis", "Glocke", "schlug", "dann", "öffnete", "sich", "Tür",
        "Wasserstraßenverwaltung", "Kerzenlicht", "hinter", "Fenstern", "wartete", "Geschichte", "auf", "ihren", "Anfang"
    ]

    private func sentence(_ seed: inout UInt64) -> String {
        var parts: [String] = []
        let count = 8 + Int(next(&seed) % 12)
        for _ in 0..<count {
            parts.append(PreviewTests.words[Int(next(&seed) % UInt64(PreviewTests.words.count))])
        }
        var text = parts.joined(separator: " ")
        text = text.prefix(1).uppercased() + text.dropFirst()
        return text + "."
    }

    private func next(_ seed: inout UInt64) -> UInt64 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return seed >> 33
    }

    /// Malt ein einfaches Coverbild, damit auch Bücher mit echtem Cover geprüft werden.
    private func coverImage(title: String) -> UIImage {
        let size = CGSize(width: 800, height: 1200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [UIColor(red: 0.10, green: 0.22, blue: 0.36, alpha: 1).cgColor,
                          UIColor(red: 0.78, green: 0.42, blue: 0.22, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            UIColor.white.withAlphaComponent(0.85).setStroke()
            let frame = UIBezierPath(rect: CGRect(x: 30, y: 30, width: size.width - 60, height: size.height - 60))
            frame.lineWidth = 6
            frame.stroke()
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            (title as NSString).draw(in: CGRect(x: 70, y: 180, width: size.width - 140, height: 500), withAttributes: [
                .font: UIFont(name: "Georgia-Bold", size: 96) ?? UIFont.boldSystemFont(ofSize: 96),
                .foregroundColor: UIColor.white,
                .paragraphStyle: style
            ])
            ("ANNA BEISPIEL" as NSString).draw(in: CGRect(x: 70, y: 1030, width: size.width - 140, height: 80), withAttributes: [
                .font: UIFont.systemFont(ofSize: 44, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.9),
                .paragraphStyle: style
            ])
        }
    }

    private func note(_ line: String) {
        print("LESEN-MESSUNG: \(line)")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let url = output.appendingPathComponent("messung.txt")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (existing + line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeBook(title: String, author: String, chapters: Int, progress: Double,
                          withCover: Bool = false) throws -> Book {
        let id = UUID()
        let directory = Paths.bookDir(id).appendingPathComponent("OEBPS", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let css = """
        .GS { font-size: 0.88em; text-align: justify; text-indent: 17px; margin-top: 0 }
        .GS-oE { font-size: 0.88em; text-align: justify; text-indent: 0; margin-top: 17px }
        .H { font-size: 1.17em; text-align: center; margin-top: 28px; margin-bottom: 28px; text-indent: 0 }
        .kursiv { font-style: italic }
        .halbfett { font-weight: bold }
        """
        try css.write(to: directory.appendingPathComponent("stil.css"), atomically: true, encoding: .utf8)

        var seed = UInt64(title.count) &* 977 &+ 13
        var spine: [String] = []
        var toc: [TOCEntry] = []
        for chapter in 0..<chapters {
            var body = "<p class=\"H\"><span class=\"halbfett\">\(chapter + 1)</span><br/>Kapitel \(chapter + 1)</p>\n"
            for paragraph in 0..<34 {
                var text = ""
                for index in 0..<(2 + Int(next(&seed) % 4)) {
                    let piece = sentence(&seed)
                    text += index == 1 ? "<span class=\"kursiv\">\(piece)</span> " : piece + " "
                }
                body += "<p class=\"\(paragraph == 0 ? "GS-oE" : "GS")\">\(text)</p>\n"
            }
            let html = """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title>
            <link href="stil.css" rel="stylesheet" type="text/css"/></head>
            <body><div>\(body)</div></body></html>
            """
            let name = "k\(chapter).xhtml"
            try html.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
            spine.append("OEBPS/" + name)
            toc.append(TOCEntry(title: "Kapitel \(chapter + 1)", chapter: chapter))
        }
        var book = Book(title: title, author: author, spine: spine, coverPath: nil)
        if withCover, let data = coverImage(title: title).jpegData(compressionQuality: 0.9) {
            try data.write(to: Paths.bookDir(id).appendingPathComponent("cover.jpg"))
            book.coverPath = "cover.jpg"
        }
        book.id = id
        book.toc = toc
        book.progress = progress
        if progress > 0 {
            book.lastOpened = Date()
            book.chapter = 1
        }
        return book
    }

    private func save(_ image: UIImage, _ name: String) {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? image.pngData()?.write(to: output.appendingPathComponent(name + ".png"))
    }

    private func wait(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private var scene: UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    /// Zeigt eine Ansicht in einem eigenen Fenster. Ohne Größe füllt es den echten Simulator-Bildschirm
    /// mit seinen echten Rändern.
    private func present<V: View>(_ view: V, size: CGSize?) -> UIWindow {
        ReaderModel.current = nil
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        if let size {
            window.frame = CGRect(origin: .zero, size: size)
        }
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    private func capture(_ window: UIWindow, name: String) {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { context in
            if !window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) {
                window.layer.render(in: context.cgContext)
            }
        }
        save(image, name)
    }

    private func dismiss(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func snapshot<V: View>(_ view: V, size: CGSize?, name: String, delay: TimeInterval) {
        let window = present(view, size: size)
        wait(delay)
        capture(window, name: name)
        dismiss(window)
    }

    private func rotate(_ orientations: UIInterfaceOrientationMask) {
        guard let scene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { [weak self] error in
            DispatchQueue.main.async {
                self?.note("Drehen nicht möglich: \(error.localizedDescription)")
            }
        }
        wait(2.5)
    }

    private func waitUntilReady(_ timeout: TimeInterval = 30) -> ReaderModel? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let model = ReaderModel.current, !model.isPaginating, !model.counts.isEmpty {
                return model
            }
            wait(0.1)
        }
        return ReaderModel.current
    }

    // MARK: Tests

    func testEnginePaginatesWholeText() throws {
        let book = try makeBook(title: "Der Hafen im Nebel", author: "A. Beispiel", chapters: 3, progress: 0)
        let root = Paths.bookDir(book.id)
        let files = book.spine.map { root.appendingPathComponent($0) }
        let engine = BookEngine(root: root, files: files)
        let layout = PageLayout(pageWidth: 440, height: 880, spread: false, fontSize: 19,
                                font: .iowan, lineHeight: 1.55, margin: 26)
        engine.configure(layout: layout, theme: .paper)

        for chapter in 0..<files.count {
            let built = try XCTUnwrap(engine.chapter(chapter))
            XCTAssertGreaterThan(built.pageCount, 2, "Kapitel \(chapter) sollte mehrere Seiten haben")
            XCTAssertGreaterThan(built.length, 2000)
            XCTAssertEqual(built.pageRanges.first?.location, 0)
            var expected = 0
            for range in built.pageRanges {
                XCTAssertEqual(range.location, expected, "Seiten müssen lückenlos aneinander anschließen")
                XCTAssertGreaterThan(range.length, 0)
                expected = NSMaxRange(range)
            }
            XCTAssertEqual(expected, built.length, "Der ganze Text muss auf Seiten verteilt sein")
            let text = built.string(in: NSRange(location: 0, length: built.length))
            XCTAssertTrue(text.contains("Kapitel \(chapter + 1)"))
            XCTAssertFalse(text.contains("<"), "Es dürfen keine Tags im Text stehen")
        }

        // Seiten als fertige Bilder zeichnen
        let chapter = try XCTUnwrap(engine.chapter(0))
        for page in 0..<2 {
            var decor = PageDecor()
            decor.dogEar = page == 1
            if page == 1, let sentence = chapter.sentenceRange(at: chapter.pageRanges[1].location + 200) {
                decor.highlights = [sentence]
            }
            let spec = PageSpec(index: page, chapter: 0, page: page, number: page + 1, title: "KAPITEL 1", side: .single)
            let image = PageRenderer.render(PageJob(spec: spec, decor: decor, layout: layout, theme: .paper,
                                                    engine: engine, scale: 2))
            XCTAssertEqual(image.size, layout.size)
            save(image, "motor-seite-\(page + 1)")
        }

        // Wort- und Satzerkennung
        let word = try XCTUnwrap(chapter.wordRange(at: 40))
        XCTAssertGreaterThan(word.length, 0)
        XCTAssertNotNil(chapter.sentenceRange(at: 40))
    }

    func testPaginationIsCachedAndStable() async throws {
        let book = try makeBook(title: "Zwei Laternen", author: "B. Muster", chapters: 4, progress: 0)
        let root = Paths.bookDir(book.id)
        let engine = BookEngine(root: root, files: book.spine.map { root.appendingPathComponent($0) })
        let layout = PageLayout(pageWidth: 433, height: 900, spread: true, fontSize: 18,
                                font: .palatino, lineHeight: 1.55, margin: 34)
        engine.configure(layout: layout, theme: .sepia)
        let first = await engine.paginate(layout: layout, theme: .sepia) { _ in }
        let second = await engine.paginate(layout: layout, theme: .sepia) { _ in }
        let a = try XCTUnwrap(first)
        let b = try XCTUnwrap(second)
        XCTAssertEqual(a.starts, b.starts)
        XCTAssertEqual(a.starts.count, 4)
        for (chapter, starts) in a.starts.enumerated() {
            XCTAssertEqual(starts, engine.chapter(chapter)?.starts, "Gespeicherte und frisch gesetzte Seiten müssen übereinstimmen")
        }
    }

    /// Text darf nie unter Rändern, Seitenleiste, Kamera oder Falz liegen – auf keinem Display.
    func testGeometryKeepsTextClear() {
        struct Case {
            var name: String
            var full: CGSize
            var insets: UIEdgeInsets
            var fold: FoldInfo?
            var holes: [CGRect] = []
            var spread: Bool
        }
        // Echte Maße aus dem iPhone-Duo-Simulator
        let fold = FoldInfo(frame: CGRect(x: 455, y: 0, width: 40, height: 669), isActive: false)
        let innerHoles = [CGRect(x: 0, y: 0, width: 84, height: 82), CGRect(x: 29, y: 29, width: 37, height: 37)]
        let outerHoles = [CGRect(x: 266, y: 0, width: 200, height: 82), CGRect(x: 399, y: 29, width: 37, height: 37)]
        let cases = [
            Case(name: "innen flach", full: CGSize(width: 951, height: 669),
                 insets: UIEdgeInsets(top: 0, left: 0, bottom: 21, right: 0), fold: fold, holes: innerHoles, spread: true),
            Case(name: "innen ohne gemeldete Bereiche", full: CGSize(width: 951, height: 669),
                 insets: UIEdgeInsets(top: 24, left: 0, bottom: 21, right: 0), fold: nil, spread: true),
            Case(name: "innen mit Seitenleiste", full: CGSize(width: 951, height: 669),
                 insets: UIEdgeInsets(top: 0, left: 84, bottom: 21, right: 0), fold: fold, holes: innerHoles, spread: true),
            Case(name: "innen, Falz außermittig", full: CGSize(width: 1035, height: 669),
                 insets: UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 84), fold: fold, spread: true),
            Case(name: "innen halb aufgeklappt (Buch)", full: CGSize(width: 951, height: 669),
                 insets: UIEdgeInsets(top: 0, left: 0, bottom: 21, right: 0),
                 fold: FoldInfo(frame: fold.frame, isActive: true), holes: innerHoles, spread: true),
            Case(name: "innen hochkant", full: CGSize(width: 669, height: 951),
                 insets: UIEdgeInsets(top: 0, left: 0, bottom: 21, right: 0),
                 fold: FoldInfo(frame: CGRect(x: 0, y: 455, width: 669, height: 40), isActive: false),
                 holes: [CGRect(x: 585, y: 0, width: 84, height: 82)], spread: false),
            Case(name: "Tisch-Modus", full: CGSize(width: 669, height: 951),
                 insets: UIEdgeInsets(top: 0, left: 0, bottom: 21, right: 0),
                 fold: FoldInfo(frame: CGRect(x: 0, y: 455, width: 669, height: 40), isActive: true),
                 holes: [CGRect(x: 585, y: 0, width: 84, height: 82)], spread: false),
            Case(name: "außen", full: CGSize(width: 466, height: 678),
                 insets: UIEdgeInsets(top: 82, left: 0, bottom: 34, right: 0), fold: nil, holes: outerHoles, spread: false),
            Case(name: "außen ohne Rand-Angabe", full: CGSize(width: 466, height: 678),
                 insets: .zero, fold: nil, holes: outerHoles, spread: false),
            Case(name: "außen quer", full: CGSize(width: 678, height: 466),
                 insets: UIEdgeInsets(top: 0, left: 0, bottom: 21, right: 0), fold: nil,
                 holes: [CGRect(x: 0, y: 0, width: 84, height: 82)], spread: false),
            Case(name: "außen mit Seitenleiste", full: CGSize(width: 466, height: 678),
                 insets: UIEdgeInsets(top: 82, left: 0, bottom: 34, right: 84), fold: nil, spread: false),
            Case(name: "gewöhnliches iPhone", full: CGSize(width: 402, height: 874),
                 insets: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0), fold: nil, spread: false)
        ]
        for item in cases {
            for margin in [16, 26, 40] {
                let metrics = ReaderMetrics.make(full: item.full, insets: item.insets, fold: item.fold,
                                                 occlusions: item.holes, margin: margin)
                let layout = metrics.layout(fontSize: 19, font: .iowan, lineHeight: 1.55, margin: margin)
                let label = "\(item.name), Rand \(margin)"
                XCTAssertEqual(metrics.spread, item.spread, label)
                var safe = CGRect(origin: .zero, size: item.full).inset(by: item.insets)
                if let panel = metrics.panel {
                    safe.size.height = min(safe.maxY, panel.minY - 40) - safe.minY
                }
                let screen = CGRect(origin: .zero, size: item.full)
                XCTAssertTrue(screen.insetBy(dx: -0.5, dy: -0.5).contains(metrics.pagerFrame), "Buch im Bildschirm: \(label)")
                let rects = metrics.textRects(layout)
                XCTAssertEqual(rects.count, item.spread ? 2 : 1, label)
                for rect in rects {
                    XCTAssertTrue(safe.insetBy(dx: -0.5, dy: -0.5).contains(rect), "Text in der sicheren Fläche: \(label) \(rect) / \(safe)")
                    XCTAssertEqual(rect.size, layout.contentSize, label)
                    XCTAssertGreaterThan(rect.width, 200, label)
                    // Ein flach aufgeklappter, quer liegender Falz ist kaum sichtbar und darf überlesen werden.
                    if let fold = item.fold, fold.isActive || fold.frame.height > fold.frame.width {
                        XCTAssertFalse(rect.intersects(fold.frame), "Text im Falz: \(label)")
                    }
                    for hole in item.holes {
                        XCTAssertFalse(rect.intersects(hole), "Text unter einem verdeckten Bereich: \(label)")
                    }
                }
                // Kopfzeilen liegen frei, über dem Text und innerhalb ihrer Seite
                XCTAssertTrue(layout.headers.isEmpty || layout.headers.count == rects.count, label)
                for (index, header) in metrics.headers.enumerated() where header.width > 0 {
                    XCTAssertLessThanOrEqual(header.maxY, rects[index].minY, "Kopfzeile über dem Text: \(label)")
                    XCTAssertGreaterThanOrEqual(header.minX, rects[index].minX - 0.5, label)
                    XCTAssertLessThanOrEqual(header.maxX, rects[index].maxX + 0.5, label)
                    for hole in item.holes {
                        XCTAssertFalse(header.intersects(hole), "Kopfzeile unter einem verdeckten Bereich: \(label)")
                    }
                    let local = layout.headers[index]
                    XCTAssertGreaterThanOrEqual(local.minX, 0, label)
                    XCTAssertLessThanOrEqual(local.maxX, CGFloat(metrics.pageWidth), label)
                }
                if item.spread, rects.count == 2 {
                    let centre = (item.fold?.frame.height ?? 0) >= (item.fold?.frame.width ?? 1)
                        ? (item.fold?.frame.midX ?? item.full.width / 2) : item.full.width / 2
                    XCTAssertEqual(metrics.pagerFrame.midX, centre, accuracy: 0.6, "Buchrücken auf dem Falz: \(label)")
                    XCTAssertLessThan(rects[0].maxX, centre, label)
                    XCTAssertGreaterThan(rects[1].minX, centre, label)
                    XCTAssertEqual(rects[0].width, rects[1].width, label)
                }
                XCTAssertEqual(metrics.pagerFrame.width, CGFloat(metrics.pageWidth * (item.spread ? 2 : 1)), label)
            }
        }
    }

    /// Blättert durch ein Buch und prüft, dass dabei keine Seite erst im Moment des Blätterns
    /// gezeichnet und kein Kapitel erst dann gesetzt wird.
    func testTurningShowsOnlyFinishedPages() throws {
        let library = Library()
        var book = try makeBook(title: "Der Hafen im Nebel", author: "Anna Beispiel", chapters: 12, progress: 0)
        // Kurz vor dem Kapitelende einsteigen, damit sicher über Kapitelgrenzen geblättert wird.
        book.fraction = 0.7
        library.addForTesting(book)
        ReaderDiagnostics.shared.reset()

        let window = present(ReaderView(book: book, onClose: {}).environmentObject(library), size: nil)
        let model = try XCTUnwrap(waitUntilReady())
        XCTAssertFalse(model.isPaginating, "Das Buch muss innerhalb der Wartezeit bereit sein")
        wait(1.5)
        note("Fenster \(Int(window.bounds.width))×\(Int(window.bounds.height)), Ränder \(window.safeAreaInsets), Seiten \(model.totalPages), Doppelseite \(model.spread)")
        XCTAssertEqual(ReaderDiagnostics.shared.syncRenderCount, 0, "Schon beim Öffnen liegen die Seiten fertig bereit")

        var forward = 0
        for _ in 0..<16 {
            let before = model.index
            model.turnHandler?(true)
            wait(0.8)
            if model.index > before { forward += 1 }
        }
        var backward = 0
        for _ in 0..<5 {
            let before = model.index
            model.turnHandler?(false)
            wait(0.8)
            if model.index < before { backward += 1 }
        }
        // Schnell hintereinander, ohne auf das Vorzeichnen zu warten
        var quick = 0
        for _ in 0..<8 {
            let before = model.index
            model.turnHandler?(true)
            wait(0.5)
            if model.index > before { quick += 1 }
        }
        note("Geblättert: \(forward) vor, \(backward) zurück, \(quick) schnell; jetzt Seite \(model.index + 1), Kapitel \(model.chapter + 1)")
        for line in ReaderDiagnostics.shared.summary(maximumRate: UIScreen.main.maximumFramesPerSecond) {
            note(line)
        }
        capture(window, name: "9-nach-dem-blaettern")
        dismiss(window)

        XCTAssertGreaterThanOrEqual(forward, 14, "Vorwärtsblättern muss funktionieren")
        XCTAssertGreaterThanOrEqual(backward, 4, "Zurückblättern muss funktionieren")
        XCTAssertGreaterThan(model.chapter, 0, "Es wurde über eine Kapitelgrenze geblättert")
        XCTAssertEqual(ReaderDiagnostics.shared.syncRenderCount, 0, "Keine Seite darf erst beim Blättern gezeichnet werden")
        XCTAssertEqual(ReaderDiagnostics.shared.mainBuildCount, 0, "Kein Kapitel darf erst beim Blättern gesetzt werden")
        XCTAssertFalse(ReaderDiagnostics.shared.hasMismatch, "Seitenfläche und berechnete Seite müssen übereinstimmen")
    }

    func testScreens() throws {
        let library = Library()
        let samples: [(String, String, Double)] = [
            ("Der Hafen im Nebel", "Anna Beispiel", 0.42),
            ("Zwei Laternen", "Bernd Muster", 0.0),
            ("Das Haus am Fluss", "Clara Probe", 1.0),
            ("Nordwind", "David Test", 0.12),
            ("Die stille Gasse", "Eva Entwurf", 0.0)
        ]
        var books: [Book] = []
        for (title, author, progress) in samples {
            let book = try makeBook(title: title, author: author, chapters: 3, progress: progress)
            library.addForTesting(book)
            books.append(book)
        }
        library.addShelf("Lieblinge")
        library.toggleShelf("Lieblinge", for: books[2].id)
        library.toggleShelf("Lieblinge", for: books[3].id)

        // Maße des iPhone Duo: Außendisplay hochkant, Innendisplay quer mit dem Falz in der Mitte.
        let outer = CGSize(width: 466, height: 678)
        let inner = CGSize(width: 951, height: 669)

        snapshot(LibraryView().environmentObject(library), size: outer, name: "1-bibliothek-aussen", delay: 1.5)
        snapshot(LibraryView().environmentObject(library), size: inner, name: "2-bibliothek-innen", delay: 1.5)
        snapshot(ReaderView(book: books[0], onClose: {}).environmentObject(library), size: outer,
                 name: "3-lesen-aussen", delay: 5)
        snapshot(ReaderView(book: books[0], onClose: {}).environmentObject(library), size: inner,
                 name: "4-lesen-innen", delay: 5)
        snapshot(BookDetailView(bookID: books[0].id, onRead: {}, onChooseCover: {}).environmentObject(library),
                 size: outer, name: "5-buch-detail", delay: 1.5)
        snapshot(StatsView().environmentObject(library), size: outer, name: "6-statistik", delay: 2)

        // Außendisplay-Cover: füllend, ganzes Cover und Ersatzcover
        let withCover = try makeBook(title: "Der Hafen im Nebel", author: "Anna Beispiel", chapters: 1,
                                     progress: 0, withCover: true)
        library.addForTesting(withCover)
        let picture = library.cover(for: withCover, large: true)
        XCTAssertNotNil(picture)
        let info = CoverDisplayInfo(image: picture, title: withCover.title, author: withCover.author, progress: 0.42)
        UserDefaults.standard.set(true, forKey: "coverFill")
        snapshot(CoverDisplayView(info: info), size: outer, name: "10-cover-aussen-fuellend", delay: 1)
        UserDefaults.standard.set(false, forKey: "coverFill")
        snapshot(CoverDisplayView(info: info), size: outer, name: "11-cover-aussen-ganz", delay: 1)
        UserDefaults.standard.set(true, forKey: "coverFill")
        snapshot(CoverDisplayView(info: CoverDisplayInfo(image: nil, title: "Zwei Laternen", author: "Bernd Muster",
                                                         progress: 0.1)),
                 size: outer, name: "12-cover-aussen-ersatz", delay: 1)

    }

    /// Wartet, bis der Build-Rechner ein Foto des ganzen Simulator-Displays gemacht hat
    /// (mit Statusfeld und Seitenleiste, die im eigenen Fenster nicht zu sehen sind).
    private func systemShot(_ name: String) {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let marker = output.appendingPathComponent("foto-\(name).bitte")
        try? Data().write(to: marker)
        let deadline = Date().addingTimeInterval(10)
        while FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            wait(0.2)
        }
        try? FileManager.default.removeItem(at: marker)
    }

    /// Zeigt Regal und Leser auf dem echten Simulator-Display in seiner aktuellen Lage
    /// (zugeklappt, aufgeklappt, halb aufgeklappt), hoch und quer.
    func testRealDevice() throws {
        let library = Library()
        var books: [Book] = []
        for (title, author, progress) in [("Der Hafen im Nebel", "Anna Beispiel", 0.42), ("Zwei Laternen", "Bernd Muster", 0.0),
                                          ("Nordwind", "David Test", 0.12)] {
            let book = try makeBook(title: title, author: author, chapters: 4, progress: progress, withCover: title == "Nordwind")
            library.addForTesting(book)
            books.append(book)
        }
        if let scene {
            note("== Simulator-Bildschirm \(scene.screen.bounds.size), Szene \(scene.coordinateSpace.bounds.size)")
        }
        for (mask, name) in [(UIInterfaceOrientationMask.portrait, "hoch"), (.landscapeRight, "quer")] {
            rotate(mask)
            ReaderDiagnostics.shared.reset()
            let window = present(ReaderView(book: books[0], onClose: {}).environmentObject(library), size: nil)
            let model = waitUntilReady()
            wait(2)
            let lines = ReaderDiagnostics.shared.summary(maximumRate: UIScreen.main.maximumFramesPerSecond)
            let half = lines.contains { $0.hasPrefix("Falz") && $0.hasSuffix("aktiv") }
            let tag = "echt-\(Int(window.bounds.width))x\(Int(window.bounds.height))\(half ? "-halb" : "")"
            note("\(tag) (\(name)): UIKit-Ränder \(window.safeAreaInsets)")
            for line in lines.suffix(7) {
                note("\(tag): \(line)")
            }
            systemShot("\(tag)-lesen-mit-leiste")
            let layoutBefore = model?.layout
            let pageBefore = model?.index
            model?.chrome = false
            wait(1)
            model?.chrome = true
            wait(1)
            model?.chrome = false
            wait(1)
            XCTAssertEqual(model?.layout, layoutBefore, "Leiste ein- und ausblenden darf nicht neu umbrechen (\(tag))")
            XCTAssertEqual(model?.index, pageBefore, "Leiste ein- und ausblenden darf nicht blättern (\(tag))")
            capture(window, name: "\(tag)-lesen")
            systemShot("\(tag)-lesen-system")
            XCTAssertFalse(ReaderDiagnostics.shared.hasMismatch, "Seitenfläche und berechnete Seite müssen übereinstimmen (\(tag))")
            dismiss(window)

            let shelf = present(LibraryView().environmentObject(library), size: nil)
            wait(1.5)
            systemShot("\(tag)-regal-system")
            dismiss(shelf)
        }
        rotate(.portrait)
    }
}
