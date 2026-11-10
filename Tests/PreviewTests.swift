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

    private func makeBook(title: String, author: String, chapters: Int, progress: Double) throws -> Book {
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

    private func snapshot<V: View>(_ view: V, size: CGSize, name: String, delay: TimeInterval) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.isHidden = false
        window.layoutIfNeeded()
        wait(delay)
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { context in
            if !window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) {
                window.layer.render(in: context.cgContext)
            }
        }
        save(image, name)
        window.isHidden = true
        window.rootViewController = nil
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

        // Seite direkt zeichnen
        let chapter = try XCTUnwrap(engine.chapter(0))
        for page in 0..<2 {
            let canvas = PageCanvas(frame: CGRect(origin: .zero, size: layout.size))
            canvas.chapterLayout = chapter
            canvas.page = page
            canvas.theme = .paper
            canvas.margin = CGFloat(layout.margin)
            canvas.textOrigin = CGPoint(x: CGFloat(layout.margin), y: CGFloat(layout.topPad))
            canvas.footerTitle = "KAPITEL 1"
            canvas.footerNumber = "\(page + 1)"
            canvas.dogEar = page == 1
            if page == 1, let sentence = chapter.sentenceRange(at: chapter.pageRanges[1].location + 200) {
                canvas.highlights = [sentence]
            }
            let image = UIGraphicsImageRenderer(bounds: canvas.bounds).image { context in
                canvas.layer.render(in: context.cgContext)
            }
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

        let outer = CGSize(width: 440, height: 956)
        let inner = CGSize(width: 880, height: 960)

        snapshot(LibraryView().environmentObject(library), size: outer, name: "1-bibliothek-aussen", delay: 1.5)
        snapshot(LibraryView().environmentObject(library), size: inner, name: "2-bibliothek-innen", delay: 1.5)
        snapshot(ReaderView(book: books[0], onClose: {}).environmentObject(library), size: outer,
                 name: "3-lesen-aussen", delay: 5)
        snapshot(ReaderView(book: books[0], onClose: {}).environmentObject(library), size: inner,
                 name: "4-lesen-innen", delay: 5)
        snapshot(BookDetailView(bookID: books[0].id, onRead: {}, onChooseCover: {}).environmentObject(library),
                 size: outer, name: "5-buch-detail", delay: 1.5)
        snapshot(StatsView().environmentObject(library), size: outer, name: "6-statistik", delay: 2)
    }
}
