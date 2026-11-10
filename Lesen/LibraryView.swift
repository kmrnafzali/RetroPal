import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

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

struct ShelfSection: Identifiable {
    let id: String
    let title: String
    let books: [Book]
    let custom: Bool
}

struct DetailTarget: Identifiable {
    let id: UUID
}

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("themeChoice") private var themeRaw = ThemeChoice.auto.rawValue

    @State private var light = DayLight.current
    @State private var showImporter = false
    @State private var showStats = false
    @State private var showNewShelf = false
    @State private var newShelfName = ""
    @State private var detail: DetailTarget?

    @State private var frameBox = FrameBox()
    @State private var flight: Flight?
    @State private var reader: DetailTarget?

    @State private var coverTarget: UUID?
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?

    private var recent: [Book] {
        library.books.sorted { ($0.lastOpened ?? $0.addedAt) > ($1.lastOpened ?? $1.addedAt) }
    }

    private var sections: [ShelfSection] {
        let all = recent
        var result: [ShelfSection] = []
        let reading = all.filter { $0.started }
        if !reading.isEmpty {
            result.append(ShelfSection(id: "#lese-ich", title: "Lese ich", books: reading, custom: false))
        }
        for shelf in library.shelves {
            result.append(ShelfSection(id: "regal-" + shelf, title: shelf,
                                       books: all.filter { $0.shelves.contains(shelf) }, custom: true))
        }
        result.append(ShelfSection(id: "#alle", title: "Alle Bücher", books: all, custom: false))
        let finished = all.filter { $0.finished }
        if !finished.isEmpty {
            result.append(ShelfSection(id: "#gelesen", title: "Ausgelesen", books: finished, custom: false))
        }
        return result
    }

    private var resumeBook: Book? {
        library.books
            .filter { $0.lastOpened != nil && !$0.finished }
            .max { ($0.lastOpened ?? .distantPast) < ($1.lastOpened ?? .distantPast) }
    }

    private var readerPaper: Color {
        let choice = ThemeChoice(rawValue: themeRaw) ?? .auto
        return choice.resolve(systemDark: colorScheme == .dark).swiftUIBackground
    }

    var body: some View {
        NavigationStack {
            ZStack {
                RoomBackdrop(light: light)
                    .ignoresSafeArea()

                if library.books.isEmpty {
                    VStack(spacing: 0) {
                        header
                        Spacer()
                        emptyState
                        Spacer()
                    }
                } else {
                    shelfContent
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                // Mit Titel und Symbol, damit das System sie auf dem iPhone Duo in die seitliche Leiste legen kann.
                ToolbarItem(placement: .primaryAction) {
                    Button("Buch hinzufügen", systemImage: "plus") { showImporter = true }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Lesestatistik", systemImage: "chart.bar.xaxis") { showStats = true }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Neues Regalbrett", systemImage: "books.vertical") { showNewShelf = true }
                }
            }
            .tint(Wood.boardFront)
        }
        .onPreferenceChange(CoverFrameKey.self) { frameBox.frames = $0 }
        .overlay {
            if let flight, let book = library.book(flight.bookID) {
                GeometryReader { geo in
                    FlightView(
                        flight: flight,
                        image: library.cover(for: book, large: true),
                        title: book.title,
                        author: book.author,
                        container: geo.size,
                        paper: readerPaper,
                        onMid: { midFlight(flight) },
                        onDone: { endFlight(flight) }
                    )
                }
                .ignoresSafeArea()
                .id(flight.id)
            }
        }
        .fullScreenCover(item: $reader) { target in
            if let book = library.book(target.id) {
                ReaderView(book: book) { close(target.id) }
                    .environmentObject(library)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                withAnimation(.easeInOut(duration: 1.2)) { light = DayLight.current }
            }
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
        .sheet(item: $detail) { target in
            BookDetailView(bookID: target.id, onRead: {
                detail = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    if let book = library.book(target.id) { open(book) }
                }
            }, onChooseCover: {
                detail = nil
                coverTarget = target.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showPhotoPicker = true }
            })
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
        .alert("Neues Regalbrett", isPresented: $showNewShelf) {
            TextField("Name, z. B. Fantasy", text: $newShelfName)
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

    // MARK: Öffnen und Schließen

    /// Das Cover fliegt vom Regal in die Mitte. Dort übernimmt der Leser und klappt es auf.
    private func open(_ book: Book) {
        guard flight == nil, reader == nil else { return }
        Haptics.medium()
        flight = Flight(bookID: book.id, origin: frameBox.frames[book.id] ?? .zero, opening: true)
    }

    private func close(_ id: UUID) {
        flight = Flight(bookID: id, origin: frameBox.frames[id] ?? .zero, opening: false)
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            reader = nil
        }
    }

    private func midFlight(_ current: Flight) {
        guard current.opening else { return }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            reader = DetailTarget(id: current.bookID)
        }
    }

    private func endFlight(_ current: Flight) {
        if flight?.id == current.id {
            flight = nil
        }
    }

    // MARK: Kopf

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(light.greeting.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.8)
                    .foregroundStyle(.secondary)
                Text("Bibliothek")
                    .font(.system(size: 36, weight: .bold, design: .serif))
                if !library.books.isEmpty {
                    Text(library.books.count == 1 ? "Ein Buch im Regal" : "\(library.books.count) Bücher im Regal")
                        .font(.system(.footnote, design: .serif))
                        .italic()
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if library.importing > 0 {
                ProgressView().padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack(alignment: .bottom) {
                ShelfNiche().frame(height: 120)
                Text("Hier ist noch Platz")
                    .font(.system(.callout, design: .serif))
                    .italic()
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.bottom, 44)
            }
            .overlay(alignment: .bottom) { ShelfBoard().offset(y: 22).padding(.horizontal, -6) }
            .padding(.horizontal, 30)
            .padding(.bottom, 30)

            Text("Dein Regal ist leer")
                .font(.system(.title2, design: .serif).weight(.semibold))
            Text("Füge eine EPUB-Datei hinzu, um loszulegen.")
                .font(.system(.subheadline, design: .serif))
                .foregroundStyle(.secondary)
            Button { showImporter = true } label: {
                Text("Buch hinzufügen")
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 13)
                    .background(Wood.boardFront, in: Capsule())
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
            }
            .buttonStyle(CardPressStyle())
        }
        .padding(.horizontal, 20)
    }

    // MARK: Regal

    private var shelfContent: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 16
            let inset: CGFloat = 30
            let perRow = max(2, Int((geo.size.width - 2 * inset + spacing) / (104 + spacing)))
            let cellWidth = (geo.size.width - 2 * inset - spacing * CGFloat(perRow - 1)) / CGFloat(perRow)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    if let last = resumeBook {
                        resumeCard(last)
                            .padding(.top, 12)
                    }

                    ForEach(sections) { section in
                        sectionView(section, cellWidth: cellWidth, spacing: spacing, inset: inset, perRow: perRow)
                            .padding(.top, 30)
                    }
                }
                .padding(.bottom, 40)
            }
        }
    }

    private func chunk(_ books: [Book], size: Int) -> [[Book]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: books.count, by: size).map {
            Array(books[$0..<min($0 + size, books.count)])
        }
    }

    private func sectionView(_ section: ShelfSection, cellWidth: CGFloat, spacing: CGFloat,
                             inset: CGFloat, perRow: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            BrassPlate(text: section.title)
                .padding(.leading, 22)
                .contextMenu {
                    if section.custom {
                        Button(role: .destructive) {
                            library.deleteShelf(section.title)
                        } label: {
                            Label("Regalbrett entfernen", systemImage: "trash")
                        }
                    }
                }

            if section.books.isEmpty {
                shelfRow([], cellWidth: cellWidth, spacing: spacing, inset: inset, perRow: perRow,
                         hint: "Halte ein Buch gedrückt, um es hierher zu stellen.")
            } else {
                VStack(spacing: 18) {
                    ForEach(Array(chunk(section.books, size: perRow).enumerated()), id: \.offset) { _, row in
                        shelfRow(row, cellWidth: cellWidth, spacing: spacing, inset: inset, perRow: perRow, hint: nil)
                    }
                }
            }
        }
    }

    private func shelfRow(_ row: [Book], cellWidth: CGFloat, spacing: CGFloat, inset: CGFloat,
                          perRow: Int, hint: String?) -> some View {
        let bookHeight = cellWidth * 1.5
        return VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                ShelfNiche()
                    .padding(.horizontal, 12)

                if let hint {
                    Text(hint)
                        .font(.system(.footnote, design: .serif))
                        .italic()
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .frame(maxHeight: .infinity)
                }

                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(row) { book in
                        Button { open(book) } label: {
                            shelfBook(book)
                                .frame(width: cellWidth, height: bookHeight)
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
            }
            .frame(height: bookHeight + 26)

            ShelfBoard()
                .padding(.horizontal, 6)
                .zIndex(1)

            if hint == nil {
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(row) { book in
                        caption(book).frame(width: cellWidth, alignment: .leading)
                    }
                    if row.count < perRow { Spacer(minLength: 0) }
                }
                .padding(.horizontal, inset)
                .padding(.top, 12)
            }
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
                        .foregroundStyle(.white, Wood.brass)
                        .shadow(radius: 2)
                        .padding(8)
                }
            }
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: CoverFrameKey.self,
                                           value: [book.id: geo.frame(in: .global)])
                }
            )
            .opacity(flight?.bookID == book.id ? 0 : 1)
    }

    private func caption(_ book: Book) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(book.title)
                .font(.system(.caption, design: .serif).weight(.semibold))
                .lineLimit(2)
            if !book.author.isEmpty {
                Text(book.author)
                    .font(.system(.caption2, design: .serif))
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let rating = book.rating, rating > 0 {
                Text(String(repeating: "★", count: rating))
                    .font(.system(size: 9))
                    .foregroundStyle(Wood.brass)
            }
        }
    }

    @ViewBuilder
    private func menu(for book: Book) -> some View {
        Button {
            detail = DetailTarget(id: book.id)
        } label: {
            Label("Buch umdrehen", systemImage: "arrow.triangle.2.circlepath")
        }
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
                Label("Auf Regalbrett stellen", systemImage: "books.vertical")
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

    private func resumeCard(_ book: Book) -> some View {
        Button { open(book) } label: {
            HStack(spacing: 16) {
                CoverArt(image: library.cover(for: book), title: book.title, author: book.author)
                    .frame(width: 66, height: 99)
                VStack(alignment: .leading, spacing: 6) {
                    Text("WEITERLESEN")
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(1.6)
                        .foregroundStyle(Wood.brass)
                    Text(book.title)
                        .font(.system(.title3, design: .serif).weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !book.author.isEmpty {
                        Text(book.author)
                            .font(.system(.footnote, design: .serif))
                            .italic()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 10) {
                        ProgressView(value: book.progress)
                            .tint(Wood.ribbon)
                        Text("\(Int((book.progress * 100).rounded())) %")
                            .font(.system(.caption, design: .serif))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .foregroundStyle(Color.primary)
            .paperCard()
        }
        .buttonStyle(CardPressStyle())
        .padding(.horizontal, 22)
    }
}

// MARK: - Buchrückseite

/// Das Buch von nah: vorn das Cover, per Tipp umgedreht die Rückseite mit Fortschritt und Lesetagebuch.
struct BookDetailView: View {
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    let onRead: () -> Void
    let onChooseCover: () -> Void

    @State private var flipped = false
    @State private var review = ""

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateStyle = .long
        return formatter
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                if let book = library.book(bookID) {
                    VStack(spacing: 22) {
                        ZStack {
                            CoverArt(image: library.cover(for: book, large: true), title: book.title, author: book.author)
                                .opacity(flipped ? 0 : 1)
                            backSide(book)
                                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                                .opacity(flipped ? 1 : 0)
                        }
                        .frame(width: 220, height: 330)
                        .rotation3DEffect(.degrees(flipped ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
                        .onTapGesture {
                            Haptics.soft()
                            withAnimation(.spring(response: 0.7, dampingFraction: 0.78)) { flipped.toggle() }
                        }
                        .padding(.top, 10)

                        Text(flipped ? "Tippen für die Vorderseite" : "Tippen zum Umdrehen")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        VStack(spacing: 4) {
                            Text(book.title)
                                .font(.system(.title2, design: .serif).weight(.bold))
                                .multilineTextAlignment(.center)
                            if !book.author.isEmpty {
                                Text(book.author)
                                    .font(.system(.body, design: .serif))
                                    .italic()
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button(action: onRead) {
                            Text(book.started ? "Weiterlesen" : (book.finished ? "Noch einmal lesen" : "Lesen"))
                                .font(.system(.headline, design: .serif))
                                .foregroundStyle(.white)
                                .frame(maxWidth: 260)
                                .padding(.vertical, 14)
                                .background(Wood.boardFront, in: Capsule())
                        }
                        .buttonStyle(CardPressStyle())

                        journal(book)

                        Button(action: onChooseCover) {
                            Label("Cover aus Fotos wählen", systemImage: "photo")
                                .font(.subheadline)
                        }
                        .tint(Wood.brass)
                    }
                    .padding(22)
                }
            }
            .background(RoomBackdrop(light: DayLight.current).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        library.setReview(bookID, review)
                        dismiss()
                    }
                }
            }
            .onAppear { review = library.book(bookID)?.review ?? "" }
            .onDisappear { library.setReview(bookID, review) }
        }
    }

    private func backSide(_ book: Book) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ÜBER DIESES EXEMPLAR")
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Wood.brassDark)
            fact("Fortschritt", "\(Int((book.progress * 100).rounded())) %")
            fact("Kapitel", "\(book.toc?.count ?? book.spine.count)")
            fact("Lesezeichen", "\(book.bookmarks.count)")
            fact("Markierungen", "\(book.highlights?.count ?? 0)")
            fact("Im Regal seit", BookDetailView.dateFormatter.string(from: book.addedAt))
            if let finished = book.finishedAt {
                fact("Ausgelesen am", BookDetailView.dateFormatter.string(from: finished))
            }
            Spacer(minLength: 0)
            ProgressView(value: book.progress)
                .tint(Wood.ribbon)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.96, green: 0.93, blue: 0.86))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .shadow(color: .black.opacity(0.3), radius: 5, x: -3, y: 5)
    }

    private func fact(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
                .font(.system(size: 10))
                .foregroundStyle(Wood.ink.opacity(0.55))
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .serif))
                .foregroundStyle(Wood.ink)
        }
    }

    private func journal(_ book: Book) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LESETAGEBUCH")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(Wood.brass)
            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        Haptics.tap()
                        library.setRating(bookID, star)
                    } label: {
                        Image(systemName: star <= (book.rating ?? 0) ? "star.fill" : "star")
                            .font(.title2)
                            .foregroundStyle(Wood.brass)
                    }
                    .buttonStyle(.plain)
                }
            }
            TextField("Was bleibt dir von diesem Buch?", text: $review, axis: .vertical)
                .font(.system(.body, design: .serif))
                .lineLimit(3...8)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }
}

enum CoverGeometry {
    /// Wo das Cover in der Bildschirmmitte schwebt, bevor es aufklappt.
    static func centerRect(in container: CGSize) -> CGRect {
        let height = min(container.height * 0.72, container.width * 0.8 * 1.5)
        let width = height / 1.5
        return CGRect(x: (container.width - width) / 2, y: (container.height - height) / 2, width: width, height: height)
    }
}

/// Das Cover hebt sich vom Regal und schwebt in die Bildschirmmitte (oder beim Schließen zurück).
/// Das Aufklappen selbst übernimmt der Leser.
struct FlightView: View {
    let flight: Flight
    let image: UIImage?
    let title: String
    let author: String
    let container: CGSize
    let paper: Color
    let onMid: () -> Void
    let onDone: () -> Void

    @State private var centered: Bool

    init(flight: Flight, image: UIImage?, title: String, author: String, container: CGSize, paper: Color,
         onMid: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.flight = flight
        self.image = image
        self.title = title
        self.author = author
        self.container = container
        self.paper = paper
        self.onMid = onMid
        self.onDone = onDone
        _centered = State(initialValue: !flight.opening)
    }

    private var rect: CGRect {
        let center = CoverGeometry.centerRect(in: container)
        if centered { return center }
        if flight.origin.width > 1 { return flight.origin }
        return center.insetBy(dx: center.width * 0.3, dy: center.height * 0.3)
    }

    var body: some View {
        let current = rect
        ZStack {
            paper.opacity(centered ? 1 : 0)
            CoverArt(image: image, title: title, author: author)
                .frame(width: current.width, height: current.height)
                .position(x: current.midX, y: current.midY)
        }
        .frame(width: container.width, height: container.height)
        .onAppear(perform: run)
    }

    private func run() {
        if flight.opening {
            withAnimation(.spring(response: 0.48, dampingFraction: 0.82)) {
                centered = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                onMid()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    onDone()
                }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.spring(response: 0.52, dampingFraction: 0.84)) {
                    centered = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    onDone()
                }
            }
        }
    }
}
