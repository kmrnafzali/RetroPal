import SwiftUI
import UniformTypeIdentifiers

struct OpenBook: Identifiable {
    let id: UUID
}

enum ShelfFilter: Hashable {
    case all
    case reading
    case finished
    case custom(String)
}

struct LibraryView: View {
    @EnvironmentObject private var library: Library

    @State private var filter: ShelfFilter = .all
    @State private var showImporter = false
    @State private var openBook: OpenBook?
    @State private var showNewShelf = false
    @State private var newShelfName = ""

    private var importTypes: [UTType] {
        var types: [UTType] = []
        if let epub = UTType("org.idpf.epub-container") { types.append(epub) }
        if let byExtension = UTType(filenameExtension: "epub") { types.append(byExtension) }
        types.append(.data)
        return types
    }

    private var visibleBooks: [Book] {
        let sorted = library.books.sorted {
            ($0.lastOpened ?? $0.addedAt) > ($1.lastOpened ?? $1.addedAt)
        }
        switch filter {
        case .all: return sorted
        case .reading: return sorted.filter { $0.progress > 0.01 && !$0.finished }
        case .finished: return sorted.filter { $0.finished }
        case .custom(let name): return sorted.filter { $0.shelves.contains(name) }
        }
    }

    private var resumeBook: Book? {
        library.books
            .filter { $0.lastOpened != nil && !$0.finished }
            .max { ($0.lastOpened ?? .distantPast) < ($1.lastOpened ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if library.books.isEmpty {
                    emptyState
                } else {
                    shelfContent
                }
            }
            .navigationTitle("Bibliothek")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if library.importing > 0 {
                        ProgressView()
                    } else {
                        Button { showImporter = true } label: { Image(systemName: "plus") }
                    }
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { library.importBook(from: url) }
            }
        }
        .fullScreenCover(item: $openBook) { item in
            if let book = library.book(item.id) {
                ReaderView(book: book)
                    .environmentObject(library)
            }
        }
        .alert("Neues Regal", isPresented: $showNewShelf) {
            TextField("Name", text: $newShelfName)
            Button("Anlegen") {
                library.addShelf(newShelfName)
                newShelfName = ""
            }
            Button("Abbrechen", role: .cancel) { newShelfName = "" }
        }
        .alert("Import fehlgeschlagen", isPresented: Binding(
            get: { library.importError != nil },
            set: { if !$0 { library.importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.importError ?? "")
        }
    }

    // MARK: Leerer Zustand

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Dein Regal ist leer", systemImage: "books.vertical")
        } description: {
            Text("Importiere eine EPUB-Datei, um loszulegen.")
        } actions: {
            Button("EPUB importieren") { showImporter = true }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Regal

    private var shelfContent: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 14
            let inset: CGFloat = 16
            let perRow = max(2, Int((geo.size.width - 2 * inset) / 118))
            let cellWidth = (geo.size.width - 2 * inset - spacing * CGFloat(perRow - 1)) / CGFloat(perRow)
            let rows = chunk(visibleBooks, size: perRow)

            ScrollView {
                VStack(spacing: 22) {
                    chips

                    if filter == .all, let last = resumeBook {
                        resumeCard(last)
                    }

                    if visibleBooks.isEmpty {
                        Text("Hier ist noch nichts.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    }

                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        shelfRow(row, cellWidth: cellWidth, spacing: spacing, inset: inset, perRow: perRow)
                    }
                }
                .padding(.vertical, 12)
            }
        }
    }

    private func chunk(_ books: [Book], size: Int) -> [[Book]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: books.count, by: size).map {
            Array(books[$0..<min($0 + size, books.count)])
        }
    }

    private func shelfRow(_ row: [Book], cellWidth: CGFloat, spacing: CGFloat, inset: CGFloat, perRow: Int) -> some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(row) { book in
                    CoverView(book: book)
                        .frame(width: cellWidth, height: cellWidth * 1.5)
                        .onTapGesture { openBook = OpenBook(id: book.id) }
                        .contextMenu { menu(for: book) }
                }
                if row.count < perRow { Spacer(minLength: 0) }
            }
            .padding(.horizontal, inset)

            ShelfBoard()

            HStack(alignment: .top, spacing: spacing) {
                ForEach(row) { book in
                    caption(book).frame(width: cellWidth, alignment: .leading)
                }
                if row.count < perRow { Spacer(minLength: 0) }
            }
            .padding(.horizontal, inset)
        }
    }

    private func caption(_ book: Book) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(book.title)
                .font(.caption.weight(.medium))
                .lineLimit(2)
            if !book.author.isEmpty {
                Text(book.author)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(book.finished ? "Gelesen" : (book.progress > 0.01 ? "\(Int(book.progress * 100)) %" : "Neu"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func menu(for book: Book) -> some View {
        if !library.shelves.isEmpty {
            Menu {
                ForEach(library.shelves, id: \.self) { shelf in
                    Button {
                        library.toggleShelf(shelf, for: book.id)
                    } label: {
                        if book.shelves.contains(shelf) {
                            Label(shelf, systemImage: "checkmark")
                        } else {
                            Text(shelf)
                        }
                    }
                }
            } label: {
                Label("Zu Regal hinzufügen", systemImage: "books.vertical")
            }
        }
        Button {
            library.setFinished(book.id, !book.finished)
        } label: {
            Label(book.finished ? "Als ungelesen markieren" : "Als gelesen markieren",
                  systemImage: book.finished ? "arrow.uturn.backward" : "checkmark.circle")
        }
        Button(role: .destructive) {
            library.delete(book.id)
        } label: {
            Label("Löschen", systemImage: "trash")
        }
    }

    // MARK: Filter

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Alle", .all)
                chip("Lese ich", .reading)
                chip("Gelesen", .finished)
                ForEach(library.shelves, id: \.self) { shelf in
                    chip(shelf, .custom(shelf))
                        .contextMenu {
                            Button(role: .destructive) {
                                if filter == .custom(shelf) { filter = .all }
                                library.deleteShelf(shelf)
                            } label: {
                                Label("Regal löschen", systemImage: "trash")
                            }
                        }
                }
                Button { showNewShelf = true } label: {
                    Label("Regal", systemImage: "plus")
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .overlay(Capsule().stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4])))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip(_ title: String, _ value: ShelfFilter) -> some View {
        Button { filter = value } label: {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .foregroundStyle(filter == value ? Color.white : Color.primary)
                .background(filter == value ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func resumeCard(_ book: Book) -> some View {
        Button { openBook = OpenBook(id: book.id) } label: {
            HStack(spacing: 14) {
                CoverView(book: book)
                    .frame(width: 56, height: 84)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Weiterlesen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(book.title)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("\(Int(book.progress * 100)) % gelesen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }
}

// MARK: - Bausteine

struct ShelfBoard: View {
    var body: some View {
        Rectangle()
            .fill(LinearGradient(
                colors: [Color(red: 0.58, green: 0.41, blue: 0.26), Color(red: 0.37, green: 0.24, blue: 0.14)],
                startPoint: .top,
                endPoint: .bottom
            ))
            .frame(height: 12)
            .shadow(color: .black.opacity(0.3), radius: 4, y: 3)
    }
}

struct CoverView: View {
    @EnvironmentObject private var library: Library
    let book: Book

    var body: some View {
        ZStack {
            if let image = library.cover(for: book) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
            // Buchrücken-Glanz
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.28), location: 0),
                    .init(color: .white.opacity(0.18), location: 0.04),
                    .init(color: .clear, location: 0.1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .shadow(color: .black.opacity(0.35), radius: 4, x: 2, y: 3)
    }

    private var placeholder: some View {
        let seed = book.title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }
        let hue = Double(seed) / 360
        return ZStack {
            LinearGradient(
                colors: [Color(hue: hue, saturation: 0.45, brightness: 0.55),
                         Color(hue: hue, saturation: 0.55, brightness: 0.35)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(book.title)
                .font(.system(.footnote, design: .serif).weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(10)
        }
    }
}
