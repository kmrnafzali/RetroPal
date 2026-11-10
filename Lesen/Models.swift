import Foundation
import SwiftUI
import UIKit

enum Paths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var booksRoot: URL {
        documents.appendingPathComponent("Books", isDirectory: true)
    }
    static func bookDir(_ id: UUID) -> URL {
        booksRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }
    static var store: URL {
        documents.appendingPathComponent("library.json")
    }
}

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var chapter: Int
    var fraction: Double
    var label: String
    var date = Date()
}

struct Highlight: Codable, Identifiable, Hashable {
    var id = UUID()
    var chapter: Int
    var start: Int
    var length: Int
    var text: String
    var note: String?
    var date = Date()
}

struct TOCEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var chapter: Int
}

struct Book: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var author: String
    var spine: [String]
    var coverPath: String?
    var chapter: Int = 0
    var fraction: Double = 0
    var progress: Double = 0
    var addedAt = Date()
    var lastOpened: Date?
    var shelves: [String] = []
    var bookmarks: [Bookmark] = []
    // Später ergänzte Felder sind optional, damit alte Bibliotheken lesbar bleiben.
    var toc: [TOCEntry]?
    var customCover: String?
    var highlights: [Highlight]?
    var rating: Int?
    var review: String?
    var finishedAt: Date?

    var finished: Bool { progress >= 0.98 }
    var started: Bool { progress > 0.01 && !finished }
}

struct DayStat: Identifiable {
    let id: String
    let label: String
    let seconds: Int
}

@MainActor
final class Library: ObservableObject {
    @Published private(set) var books: [Book] = []
    @Published private(set) var shelves: [String] = []
    @Published private(set) var stats: [String: Int] = [:]
    @Published var importError: String?
    @Published private(set) var importing = 0

    private let coverCache = NSCache<NSString, UIImage>()
    private var pendingSeconds = 0

    private struct Store: Codable {
        var books: [Book]
        var shelves: [String]
        var stats: [String: Int]?
    }

    init() {
        load()
    }

    // MARK: Speicher

    private func load() {
        guard let data = try? Data(contentsOf: Paths.store),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return }
        books = store.books
        shelves = store.shelves
        stats = store.stats ?? [:]
    }

    private func save() {
        let store = Store(books: books, shelves: shelves, stats: stats)
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: Paths.store, options: .atomic)
        }
    }

    private func mutate(_ id: UUID, _ change: (inout Book) -> Void) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        change(&books[index])
        save()
    }

    // MARK: Import

    func importBook(from url: URL) {
        importing += 1
        let root = Paths.booksRoot
        Task {
            do {
                let book = try await Task.detached(priority: .userInitiated) { () throws -> Book in
                    try Library.importCopy(of: url, root: root)
                }.value
                withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) {
                    books.insert(book, at: 0)
                }
                save()
                Haptics.success()
            } catch {
                if let epubError = error as? EPUBError {
                    importError = epubError.errorDescription
                } else {
                    importError = "Die Datei konnte nicht gelesen werden (\(error.localizedDescription))."
                }
            }
            importing -= 1
        }
    }

    /// Kopiert die Datei zuerst in einen eigenen Ordner und importiert dann die Kopie.
    /// So spielt es keine Rolle, ob sie aus der Dateien-App, iCloud oder einer anderen App kommt.
    nonisolated static func importCopy(of url: URL, root: URL) throws -> Book {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        let staging = fm.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString).epub")
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readable in
            do {
                try fm.copyItem(at: readable, to: staging)
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        defer { try? fm.removeItem(at: staging) }

        var book = try EPUBParser.importEPUB(at: staging, libraryRoot: root)
        if book.title.hasPrefix("import-") {
            book.title = url.deletingPathExtension().lastPathComponent
        }
        return book
    }

    /// Nur für die automatischen Vorschau-Tests.
    func addForTesting(_ book: Book) {
        books.append(book)
    }

    // MARK: Bücher

    func book(_ id: UUID) -> Book? {
        books.first { $0.id == id }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: Paths.bookDir(id))
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
            books.removeAll { $0.id == id }
        }
        clearCoverCache(id)
        save()
    }

    func markOpened(_ id: UUID) {
        mutate(id) { $0.lastOpened = Date() }
    }

    func updatePosition(_ id: UUID, chapter: Int, fraction: Double, progress: Double) {
        mutate(id) {
            $0.chapter = chapter
            $0.fraction = fraction
            $0.progress = progress
            if $0.finished && $0.finishedAt == nil {
                $0.finishedAt = Date()
            }
        }
    }

    func setFinished(_ id: UUID, _ finished: Bool) {
        mutate(id) {
            $0.progress = finished ? 1 : 0
            if !finished {
                $0.chapter = 0
                $0.fraction = 0
            }
        }
    }

    func setRating(_ id: UUID, _ rating: Int) {
        mutate(id) { $0.rating = $0.rating == rating ? nil : rating }
    }

    func setReview(_ id: UUID, _ review: String) {
        let trimmed = review.trimmingCharacters(in: .whitespacesAndNewlines)
        mutate(id) { $0.review = trimmed.isEmpty ? nil : trimmed }
    }

    /// Liest das Inhaltsverzeichnis nach, falls das Buch vor dieser Funktion importiert wurde.
    func ensureTOC(_ id: UUID) {
        guard let book = book(id), book.toc == nil else { return }
        let parsed = try? EPUBParser.parse(directory: Paths.bookDir(id))
        mutate(id) { $0.toc = parsed?.toc ?? [] }
    }

    // MARK: Cover

    private func clearCoverCache(_ id: UUID) {
        coverCache.removeObject(forKey: "\(id.uuidString)-s" as NSString)
        coverCache.removeObject(forKey: "\(id.uuidString)-l" as NSString)
    }

    func cover(for book: Book, large: Bool = false) -> UIImage? {
        guard let relative = book.customCover ?? book.coverPath else { return nil }
        let key = "\(book.id.uuidString)-\(large ? "l" : "s")" as NSString
        if let cached = coverCache.object(forKey: key) { return cached }
        let url = Paths.bookDir(book.id).appendingPathComponent(relative)
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let size = large ? CGSize(width: 1000, height: 1500) : CGSize(width: 420, height: 630)
        let thumb = image.preparingThumbnail(of: size) ?? image
        coverCache.setObject(thumb, forKey: key)
        return thumb
    }

    func setCustomCover(_ id: UUID, data: Data) {
        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.88) else { return }
        let name = "eigenes-cover-\(Int(Date().timeIntervalSince1970)).jpg"
        let url = Paths.bookDir(id).appendingPathComponent(name)
        do {
            try jpeg.write(to: url, options: .atomic)
        } catch {
            return
        }
        clearCoverCache(id)
        mutate(id) { $0.customCover = name }
    }

    func resetCustomCover(_ id: UUID) {
        if let name = book(id)?.customCover {
            try? FileManager.default.removeItem(at: Paths.bookDir(id).appendingPathComponent(name))
        }
        clearCoverCache(id)
        mutate(id) { $0.customCover = nil }
    }

    // MARK: Lesezeichen

    func addBookmark(_ id: UUID, _ bookmark: Bookmark) {
        mutate(id) { $0.bookmarks.append(bookmark) }
    }

    func removeBookmark(_ id: UUID, _ bookmarkID: UUID) {
        mutate(id) { $0.bookmarks.removeAll { $0.id == bookmarkID } }
    }

    // MARK: Markierungen

    func addHighlight(_ id: UUID, _ highlight: Highlight) {
        mutate(id) {
            var list = $0.highlights ?? []
            list.append(highlight)
            $0.highlights = list
        }
    }

    func removeHighlight(_ id: UUID, _ highlightID: UUID) {
        mutate(id) { $0.highlights?.removeAll { $0.id == highlightID } }
    }

    func setNote(_ id: UUID, highlightID: UUID, note: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        mutate(id) { book in
            guard let index = book.highlights?.firstIndex(where: { $0.id == highlightID }) else { return }
            book.highlights?[index].note = trimmed.isEmpty ? nil : trimmed
        }
    }

    // MARK: Regale

    func addShelf(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !shelves.contains(trimmed) else { return }
        shelves.append(trimmed)
        save()
    }

    func deleteShelf(_ name: String) {
        shelves.removeAll { $0 == name }
        for index in books.indices {
            books[index].shelves.removeAll { $0 == name }
        }
        save()
    }

    func toggleShelf(_ shelf: String, for id: UUID) {
        mutate(id) {
            if let index = $0.shelves.firstIndex(of: shelf) {
                $0.shelves.remove(at: index)
            } else {
                $0.shelves.append(shelf)
            }
        }
    }

    // MARK: Lesestatistik

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "EEEEEE"
        return formatter
    }()

    private func key(_ date: Date) -> String {
        Library.dayFormatter.string(from: date)
    }

    func addReading(seconds: Int) {
        stats[key(Date()), default: 0] += seconds
        pendingSeconds += seconds
        if pendingSeconds >= 30 {
            flushStats()
        }
    }

    func flushStats() {
        guard pendingSeconds > 0 else { return }
        pendingSeconds = 0
        save()
    }

    var todaySeconds: Int {
        stats[key(Date())] ?? 0
    }

    var totalSeconds: Int {
        stats.values.reduce(0, +)
    }

    /// Aufeinanderfolgende Tage mit mindestens einer Minute Lesezeit.
    var streak: Int {
        let calendar = Calendar.current
        var day = Date()
        if (stats[key(day)] ?? 0) < 60 {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var count = 0
        while (stats[key(day)] ?? 0) >= 60 {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    var lastSevenDays: [DayStat] {
        let calendar = Calendar.current
        return (0..<7).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: Date()) else { return nil }
            let id = key(day)
            return DayStat(id: id, label: Library.weekdayFormatter.string(from: day), seconds: stats[id] ?? 0)
        }
    }
}
