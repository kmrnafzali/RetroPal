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

    var finished: Bool { progress >= 0.98 }
}

@MainActor
final class Library: ObservableObject {
    @Published private(set) var books: [Book] = []
    @Published private(set) var shelves: [String] = []
    @Published var importError: String?
    @Published private(set) var importing = 0

    private let coverCache = NSCache<NSString, UIImage>()

    private struct Store: Codable {
        var books: [Book]
        var shelves: [String]
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
    }

    private func save() {
        let store = Store(books: books, shelves: shelves)
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
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    return try EPUBParser.importEPUB(at: url, libraryRoot: root)
                }.value
                books.insert(book, at: 0)
                save()
            } catch {
                importError = (error as? EPUBError)?.errorDescription
                    ?? "Die Datei konnte nicht gelesen werden. Es muss eine EPUB-Datei sein."
            }
            importing -= 1
        }
    }

    // MARK: Bücher

    func book(_ id: UUID) -> Book? {
        books.first { $0.id == id }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: Paths.bookDir(id))
        books.removeAll { $0.id == id }
        coverCache.removeObject(forKey: id.uuidString as NSString)
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

    func cover(for book: Book) -> UIImage? {
        guard let relative = book.coverPath else { return nil }
        let key = book.id.uuidString as NSString
        if let cached = coverCache.object(forKey: key) { return cached }
        let url = Paths.bookDir(book.id).appendingPathComponent(relative)
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let thumb = image.preparingThumbnail(of: CGSize(width: 480, height: 720)) ?? image
        coverCache.setObject(thumb, forKey: key)
        return thumb
    }

    // MARK: Lesezeichen

    func addBookmark(_ id: UUID, _ bookmark: Bookmark) {
        mutate(id) { $0.bookmarks.append(bookmark) }
    }

    func removeBookmark(_ id: UUID, _ bookmarkID: UUID) {
        mutate(id) { $0.bookmarks.removeAll { $0.id == bookmarkID } }
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
}
