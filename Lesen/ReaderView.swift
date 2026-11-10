import SwiftUI

struct ReaderView: View {
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @AppStorage("fontSize") private var fontSize = 19
    @AppStorage("theme") private var themeRaw = ReadingTheme.paper.rawValue
    @StateObject private var model: ReaderModel

    private let bookID: UUID
    private let bookTitle: String

    @State private var showSettings = false
    @State private var showBookmarks = false
    @State private var sliderValue = 0.0
    @State private var scrubbing = false
    @State private var lastSize = CGSize.zero

    init(book: Book) {
        bookID = book.id
        bookTitle = book.title
        let root = Paths.bookDir(book.id)
        let files = book.spine.map { root.appendingPathComponent($0) }
        let stored = UserDefaults.standard.string(forKey: "theme") ?? ""
        let theme = ReadingTheme(rawValue: stored) ?? .paper
        _model = StateObject(wrappedValue: ReaderModel(
            root: root,
            files: files,
            chapter: book.chapter,
            fraction: book.fraction,
            theme: theme
        ))
    }

    private var theme: ReadingTheme {
        ReadingTheme(rawValue: themeRaw) ?? .paper
    }

    var body: some View {
        ZStack {
            theme.swiftUIBackground.ignoresSafeArea()

            GeometryReader { geo in
                PagerView(model: model)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .onAppear { configure(geo.size) }
                    .onChange(of: geo.size) { _, newSize in configure(newSize) }
            }

            if model.isPaginating {
                loadingOverlay
            }
            if model.chrome && !model.isPaginating {
                chromeOverlay
            }
        }
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .animation(.easeInOut(duration: 0.2), value: model.chrome)
        .onChange(of: fontSize) { _, _ in configure(lastSize) }
        .onChange(of: themeRaw) { _, _ in model.setTheme(theme) }
        .onChange(of: model.progress) { _, value in
            if !scrubbing { sliderValue = value }
        }
        .onAppear {
            let id = bookID
            model.onPosition = { chapter, fraction, progress in
                library.updatePosition(id, chapter: chapter, fraction: fraction, progress: progress)
            }
            library.markOpened(id)
        }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsView(fontSize: $fontSize, themeRaw: $themeRaw)
                .presentationDetents([.height(230)])
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarksView(bookID: bookID, model: model)
        }
    }

    // MARK: Layout

    private func configure(_ size: CGSize) {
        lastSize = size
        let width = Int(size.width.rounded(.down))
        let height = Int(size.height.rounded(.down))
        guard width > 100, height > 100 else { return }
        // Breit (Innendisplay, iPad, Querformat): Doppelseite. Schmal (Außendisplay, iPhone): Einzelseite.
        let columns = width >= 560 ? 2 : 1
        model.update(layout: PageLayout(width: width, height: height, columns: columns, fontSize: fontSize))
    }

    // MARK: Oberflächen

    private var loadingOverlay: some View {
        VStack(spacing: 14) {
            ProgressView(value: model.progressValue)
                .frame(width: 180)
            Text("Seiten werden berechnet …")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var chromeOverlay: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                Button { dismiss() } label: { Image(systemName: "chevron.down") }
                Text(bookTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                Button { toggleBookmark() } label: {
                    Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                }
                Button { showBookmarks = true } label: { Image(systemName: "list.bullet") }
                Button { showSettings = true } label: { Image(systemName: "textformat.size") }
            }
            .font(.title3)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)

            Spacer()

            VStack(spacing: 6) {
                Slider(value: $sliderValue, in: 0...1) { editing in
                    scrubbing = editing
                    if !editing { model.jump(toGlobalFraction: sliderValue) }
                }
                Text("Seite \(model.globalPage + 1) von \(max(1, model.totalPages))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
        .transition(.opacity)
    }

    // MARK: Lesezeichen

    private func pageRange() -> (Double, Double)? {
        guard model.chapter < model.counts.count else { return nil }
        let count = Double(max(1, model.counts[model.chapter]))
        return (Double(model.page) / count, Double(model.page + 1) / count)
    }

    private func bookmarkOnPage() -> Bookmark? {
        guard let range = pageRange(), let book = library.book(bookID) else { return nil }
        return book.bookmarks.first {
            $0.chapter == model.chapter && $0.fraction >= range.0 - 0.0001 && $0.fraction < range.1
        }
    }

    private var isBookmarked: Bool {
        bookmarkOnPage() != nil
    }

    private func toggleBookmark() {
        guard let range = pageRange() else { return }
        if let existing = bookmarkOnPage() {
            library.removeBookmark(bookID, existing.id)
        } else {
            let percent = Int((model.progress * 100).rounded())
            library.addBookmark(bookID, Bookmark(
                chapter: model.chapter,
                fraction: range.0,
                label: "Lesezeichen bei \(percent) %"
            ))
        }
    }
}

// MARK: - Einstellungen

struct ReaderSettingsView: View {
    @Binding var fontSize: Int
    @Binding var themeRaw: String

    var body: some View {
        VStack(spacing: 26) {
            HStack(spacing: 24) {
                Button { fontSize = max(13, fontSize - 1) } label: {
                    Text("A").font(.system(size: 16, weight: .semibold))
                        .frame(width: 52, height: 44)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                Text("\(fontSize) pt")
                    .font(.headline)
                    .monospacedDigit()
                    .frame(width: 70)
                Button { fontSize = min(30, fontSize + 1) } label: {
                    Text("A").font(.system(size: 26, weight: .semibold))
                        .frame(width: 52, height: 44)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }

            HStack(spacing: 26) {
                ForEach(ReadingTheme.allCases) { theme in
                    Button { themeRaw = theme.rawValue } label: {
                        VStack(spacing: 6) {
                            Circle()
                                .fill(theme.swiftUIBackground)
                                .frame(width: 46, height: 46)
                                .overlay(Circle().stroke(themeRaw == theme.rawValue ? Color.accentColor : Color.gray.opacity(0.4),
                                                         lineWidth: themeRaw == theme.rawValue ? 3 : 1))
                            Text(theme.title).font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Lesezeichen-Liste

struct BookmarksView: View {
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    @ObservedObject var model: ReaderModel

    private var bookmarks: [Bookmark] {
        library.book(bookID)?.bookmarks ?? []
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(bookmarks) { bookmark in
                    Button {
                        model.jump(chapter: bookmark.chapter, fraction: bookmark.fraction)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bookmark.label)
                            Text(bookmark.date, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { bookmarks[$0].id }
                    for id in ids { library.removeBookmark(bookID, id) }
                }
            }
            .overlay {
                if bookmarks.isEmpty {
                    ContentUnavailableView("Keine Lesezeichen", systemImage: "bookmark",
                                           description: Text("Tippe oben auf das Lesezeichen, um die aktuelle Seite zu merken."))
                }
            }
            .navigationTitle("Lesezeichen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}
