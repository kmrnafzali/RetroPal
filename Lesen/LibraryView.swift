import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum ShelfFilter: Hashable {
    case all
    case reading
    case finished
    case custom(String)
}

struct CoverFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Merkt sich die Positionen der Cover, ohne die Ansicht bei jedem Scrollen neu zu zeichnen.
final class FrameBox {
    var frames: [UUID: CGRect] = [:]
}

/// Ein Buch, das gerade vom Regal zum Leser fliegt (oder zurück).
struct Flight: Identifiable {
    let id = UUID()
    let bookID: UUID
    let origin: CGRect
    let opening: Bool
}

struct LibraryView: View {
    @EnvironmentObject private var library: Library

    @State private var filter: ShelfFilter = .all
    @State private var showImporter = false
    @State private var showStats = false
    @State private var showNewShelf = false
    @State private var newShelfName = ""

    @State private var frameBox = FrameBox()
    @State private var flight: Flight?
    @State private var readerID: UUID?

    @State private var coverTarget: UUID?
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?

    private var visibleBooks: [Book] {
        let sorted = library.books.sorted {
            ($0.lastOpened ?? $0.addedAt) > ($1.lastOpened ?? $1.addedAt)
        }
        switch filter {
        case .all: return sorted
        case .reading: return sorted.filter { $0.started }
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
        GeometryReader { rootGeo in
            ZStack {
                NavigationStack {
                    Group {
                        if library.books.isEmpty {
                            emptyState
                        } else {
                            shelfContent
                        }
                    }
                    .background(backdrop.ignoresSafeArea())
                    .navigationTitle("Bibliothek")
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { showStats = true } label: { Image(systemName: "chart.bar.xaxis") }
                        }
                        ToolbarItem(placement: .primaryAction) {
                            if library.importing > 0 {
                                ProgressView()
                            } else {
                                Button { showImporter = true } label: { Image(systemName: "plus") }
                            }
                        }
                    }
                }

                if let id = readerID, let book = library.book(id) {
                    ReaderView(book: book) { close(id) }
                        .id(id)
                        .transition(.opacity)
                        .zIndex(1)
                }

                if let flight, let book = library.book(flight.bookID) {
                    FlightView(
                        flight: flight,
                        image: library.cover(for: book, large: true),
                        title: book.title,
                        author: book.author,
                        container: rootGeo.size,
                        onMid: { midFlight(flight) },
                        onDone: { endFlight(flight) }
                    )
                    .id(flight.id)
                    .zIndex(2)
                }
            }
            .coordinateSpace(name: "root")
            .onPreferenceChange(CoverFrameKey.self) { frameBox.frames = $0 }
        }
        .sheet(isPresented: $showImporter) {
            DocumentPicker { urls in
                for url in urls { library.importBook(from: url) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showStats) {
            StatsView()
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item, let target = coverTarget else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    library.setCustomCover(target, data: data)
                }
                photoItem = nil
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

    private var backdrop: some View {
        LinearGradient(
            colors: [Color(uiColor: .systemBackground), Color(uiColor: .secondarySystemBackground)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: Öffnen und Schließen

    private func open(_ book: Book) {
        guard flight == nil, readerID == nil else { return }
        Haptics.medium()
        flight = Flight(bookID: book.id, origin: frameBox.frames[book.id] ?? .zero, opening: true)
    }

    private func close(_ id: UUID) {
        guard flight == nil else { return }
        Haptics.tap()
        flight = Flight(bookID: id, origin: frameBox.frames[id] ?? .zero, opening: false)
        withAnimation(.easeOut(duration: 0.35)) {
            readerID = nil
        }
    }

    private func midFlight(_ current: Flight) {
        guard current.opening else { return }
        withAnimation(.easeIn(duration: 0.4)) {
            readerID = current.bookID
        }
    }

    private func endFlight(_ current: Flight) {
        if flight?.id == current.id {
            flight = nil
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
            let spacing: CGFloat = 18
            let inset: CGFloat = 22
            let perRow = max(2, Int((geo.size.width - 2 * inset + spacing) / (112 + spacing)))
            let cellWidth = (geo.size.width - 2 * inset - spacing * CGFloat(perRow - 1)) / CGFloat(perRow)
            let rows = chunk(visibleBooks, size: perRow)

            ScrollView {
                VStack(spacing: 26) {
                    chips

                    if filter == .all, let last = resumeBook {
                        resumeCard(last)
                    }

                    if visibleBooks.isEmpty {
                        Text("Hier steht noch nichts.")
                            .font(.system(.body, design: .serif))
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    }

                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        shelfRow(row, cellWidth: cellWidth, spacing: spacing, inset: inset, perRow: perRow)
                    }
                }
                .padding(.vertical, 12)
                .animation(.spring(response: 0.5, dampingFraction: 0.85), value: filter)
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
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(row) { book in
                    Button { open(book) } label: {
                        shelfBook(book)
                            .frame(width: cellWidth, height: cellWidth * 1.5)
                    }
                    .buttonStyle(BookPressStyle())
                    .contextMenu { menu(for: book) }
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .scale(scale: 0.6).combined(with: .opacity)
                    ))
                }
                if row.count < perRow { Spacer(minLength: 0) }
            }
            .padding(.horizontal, inset)
            .zIndex(1)

            ShelfBoard()
                .padding(.horizontal, 6)

            HStack(alignment: .top, spacing: spacing) {
                ForEach(row) { book in
                    caption(book).frame(width: cellWidth, alignment: .leading)
                }
                if row.count < perRow { Spacer(minLength: 0) }
            }
            .padding(.horizontal, inset)
            .padding(.top, 10)
        }
    }

    private func shelfBook(_ book: Book) -> some View {
        CoverArt(image: library.cover(for: book), title: book.title, author: book.author)
            .overlay(alignment: .topTrailing) {
                if book.started {
                    Ribbon()
                        .frame(width: 13, height: 22 + 46 * book.progress)
                        .padding(.trailing, 12)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if book.finished {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color(red: 0.72, green: 0.58, blue: 0.28))
                        .shadow(radius: 2)
                        .padding(8)
                }
            }
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: CoverFrameKey.self,
                                           value: [book.id: geo.frame(in: .named("root"))])
                }
            )
            .opacity(flight?.bookID == book.id ? 0 : 1)
    }

    private func caption(_ book: Book) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(book.title)
                .font(.system(.caption, design: .serif).weight(.semibold))
                .lineLimit(2)
            if !book.author.isEmpty {
                Text(book.author)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if book.started {
                ProgressView(value: book.progress)
                    .tint(Color(red: 0.70, green: 0.16, blue: 0.17))
                    .scaleEffect(x: 1, y: 0.6, anchor: .center)
                    .padding(.top, 1)
            }
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
            coverTarget = book.id
            showPhotoPicker = true
        } label: {
            Label("Cover aus Fotos wählen", systemImage: "photo")
        }
        if book.customCover != nil {
            Button {
                library.resetCustomCover(book.id)
            } label: {
                Label("Original-Cover wiederherstellen", systemImage: "arrow.uturn.backward")
            }
        }
        Button {
            library.setFinished(book.id, !book.finished)
        } label: {
            Label(book.finished ? "Als ungelesen markieren" : "Als gelesen markieren",
                  systemImage: book.finished ? "arrow.uturn.backward.circle" : "checkmark.circle")
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
            .padding(.horizontal, 22)
        }
    }

    private func chip(_ title: String, _ value: ShelfFilter) -> some View {
        Button {
            Haptics.tap()
            filter = value
        } label: {
            Text(title)
                .font(.subheadline.weight(filter == value ? .semibold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .foregroundStyle(filter == value ? Color(uiColor: .systemBackground) : Color.primary)
                .background(filter == value ? Color.primary : Color.secondary.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: filter)
    }

    private func resumeCard(_ book: Book) -> some View {
        Button { open(book) } label: {
            HStack(spacing: 16) {
                CoverArt(image: library.cover(for: book), title: book.title, author: book.author)
                    .frame(width: 62, height: 93)
                VStack(alignment: .leading, spacing: 5) {
                    Text("WEITERLESEN")
                        .font(.caption2.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                    Text(book.title)
                        .font(.system(.title3, design: .serif).weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    ProgressView(value: book.progress)
                        .tint(Color.primary)
                    Text("\(Int((book.progress * 100).rounded())) % gelesen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "book.pages")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(CardPressStyle())
        .padding(.horizontal, 22)
    }
}

// MARK: - Bausteine

struct BookPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .rotation3DEffect(.degrees(configuration.isPressed ? -14 : 0), axis: (x: 0, y: 1, z: 0),
                              anchor: .leading, perspective: 0.5)
            .scaleEffect(configuration.isPressed ? 1.04 : 1, anchor: .bottom)
            .offset(y: configuration.isPressed ? -6 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct ShelfBoard: View {
    var body: some View {
        VStack(spacing: 0) {
            // Oberkante, auf der die Bücher stehen
            Rectangle()
                .fill(LinearGradient(
                    colors: [Color(red: 0.70, green: 0.53, blue: 0.36), Color(red: 0.60, green: 0.43, blue: 0.28)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .frame(height: 5)
            // Vorderkante
            Rectangle()
                .fill(LinearGradient(
                    colors: [Color(red: 0.50, green: 0.34, blue: 0.21), Color(red: 0.33, green: 0.21, blue: 0.12)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .frame(height: 11)
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 6)
    }
}

/// Das Cover hebt sich vom Regal, schwebt in die Mitte und klappt wie ein Buchdeckel auf.
struct FlightView: View {
    enum Phase {
        case shelf
        case center
        case open
    }

    let flight: Flight
    let image: UIImage?
    let title: String
    let author: String
    let container: CGSize
    let onMid: () -> Void
    let onDone: () -> Void

    @State private var phase: Phase

    init(flight: Flight, image: UIImage?, title: String, author: String, container: CGSize,
         onMid: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.flight = flight
        self.image = image
        self.title = title
        self.author = author
        self.container = container
        self.onMid = onMid
        self.onDone = onDone
        _phase = State(initialValue: flight.opening ? .shelf : .open)
    }

    private var centerRect: CGRect {
        let height = min(container.height * 0.74, container.width * 0.82 * 1.5)
        let width = height / 1.5
        return CGRect(x: (container.width - width) / 2, y: (container.height - height) / 2, width: width, height: height)
    }

    private var openRect: CGRect {
        let height = container.height * 1.02
        let width = max(container.width * 0.6, height / 1.5)
        return CGRect(x: (container.width - width) / 2 + width * 0.18, y: (container.height - height) / 2,
                      width: width, height: height)
    }

    private var rect: CGRect {
        switch phase {
        case .shelf:
            if flight.origin.width > 1 { return flight.origin }
            let fallback = centerRect
            return fallback.insetBy(dx: fallback.width * 0.3, dy: fallback.height * 0.3)
        case .center: return centerRect
        case .open: return openRect
        }
    }

    var body: some View {
        let current = rect
        ZStack {
            Color.black
                .opacity(phase == .center ? 0.5 : 0)
                .ignoresSafeArea()

            // Seitenblock unter dem Deckel
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(red: 0.97, green: 0.95, blue: 0.90))
                .frame(width: current.width * 0.97, height: current.height * 0.985)
                .position(x: current.midX + current.width * 0.012, y: current.midY)
                .opacity(phase == .center ? 1 : 0)

            CoverArt(image: image, title: title, author: author)
                .frame(width: current.width, height: current.height)
                .rotation3DEffect(.degrees(phase == .open ? -112 : 0), axis: (x: 0, y: 1, z: 0),
                                  anchor: .leading, perspective: 0.42)
                .opacity(phase == .open ? 0 : 1)
                .position(x: current.midX, y: current.midY)
        }
        .frame(width: container.width, height: container.height)
        .onAppear(perform: run)
    }

    private func run() {
        if flight.opening {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                phase = .center
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.46) {
                onMid()
                withAnimation(.easeInOut(duration: 0.7)) {
                    phase = .open
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                    onDone()
                }
            }
        } else {
            withAnimation(.easeInOut(duration: 0.5)) {
                phase = .center
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    phase = .shelf
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                    onDone()
                }
            }
        }
    }
}
