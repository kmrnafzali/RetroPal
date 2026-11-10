import SwiftUI
import UIKit

struct ReaderView: View {
    @EnvironmentObject private var library: Library
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("fontSize") private var fontSize = 19
    @AppStorage("themeChoice") private var themeRaw = ThemeChoice.auto.rawValue
    @AppStorage("readingFont") private var fontRaw = ReadingFont.iowan.rawValue
    @AppStorage("lineHeight") private var lineHeight = 1.55
    @AppStorage("pageMargin") private var pageMargin = 26
    @AppStorage("hingeEffect") private var hingeEffect = true
    @AppStorage("coverOnOuter") private var coverOnOuter = false

    @StateObject private var model: ReaderModel

    private let bookID: UUID
    private let bookTitle: String
    private let bookAuthor: String
    private let onClose: () -> Void

    @State private var showSettings = false
    @State private var showContents = false
    @State private var sliderValue = 0.0
    @State private var scrubbing = false
    @State private var lastSize = CGSize.zero
    @State private var isSpread = false
    @State private var hingeDegrees: Double?
    @State private var coverAvailable = false

    private let ticker = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    init(book: Book, onClose: @escaping () -> Void) {
        bookID = book.id
        bookTitle = book.title
        bookAuthor = book.author
        self.onClose = onClose
        let root = Paths.bookDir(book.id)
        let files = book.spine.map { root.appendingPathComponent($0) }
        let stored = UserDefaults.standard.string(forKey: "themeChoice") ?? ""
        let choice = ThemeChoice(rawValue: stored) ?? .auto
        let systemDark = UITraitCollection.current.userInterfaceStyle == .dark
        let initial = ReaderModel(
            root: root,
            files: files,
            chapter: book.chapter,
            fraction: book.fraction,
            theme: choice.resolve(systemDark: systemDark)
        )
        initial.toc = book.toc ?? []
        _model = StateObject(wrappedValue: initial)
    }

    private var choice: ThemeChoice {
        ThemeChoice(rawValue: themeRaw) ?? .auto
    }

    private var theme: ReadingTheme {
        choice.resolve(systemDark: colorScheme == .dark)
    }

    private var forcedScheme: ColorScheme? {
        switch choice {
        case .auto: return nil
        case .dark: return .dark
        case .paper, .sepia: return .light
        }
    }

    private var coverImage: UIImage? {
        guard let book = library.book(bookID) else { return nil }
        return library.cover(for: book, large: true)
    }

    var body: some View {
        ZStack {
            theme.swiftUIBackground.ignoresSafeArea()

            GeometryReader { geo in
                let spread = geo.size.width >= 560
                PagerView(model: model, spread: spread)
                    .id(spread)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .onAppear { configure(geo.size) }
                    .onChange(of: geo.size) { _, newSize in configure(newSize) }
            }

            hingeCover

            if model.isPaginating {
                loadingOverlay
            }
            if model.chrome && !model.isPaginating {
                chromeOverlay
            }
        }
        .preferredColorScheme(forcedScheme)
        .statusBarHidden(!model.chrome)
        .animation(.easeInOut(duration: 0.22), value: model.chrome)
        .animation(.easeInOut(duration: 0.25), value: model.isPaginating)
        .onChange(of: fontSize) { _, _ in configure(lastSize) }
        .onChange(of: fontRaw) { _, _ in configure(lastSize) }
        .onChange(of: lineHeight) { _, _ in configure(lastSize) }
        .onChange(of: pageMargin) { _, _ in configure(lastSize) }
        .onChange(of: theme) { _, newTheme in model.setTheme(newTheme) }
        .onChange(of: model.progress) { _, value in
            if !scrubbing { sliderValue = value }
        }
        .onReceive(ticker) { _ in
            if scenePhase == .active && !model.isPaginating && !showSettings && !showContents {
                library.addReading(seconds: 5)
            }
        }
        .onAppear {
            let id = bookID
            model.onPosition = { chapter, fraction, progress in
                library.updatePosition(id, chapter: chapter, fraction: fraction, progress: progress)
            }
            model.setTheme(theme)
            library.markOpened(id)
            library.ensureTOC(id)
            model.toc = library.book(id)?.toc ?? []
        }
        .onDisappear {
            library.flushStats()
        }
        .modifier(DuoSupport(
            info: CoverDisplayInfo(image: coverImage, title: bookTitle, author: bookAuthor, progress: model.progress),
            coverActive: coverOnOuter && isSpread && scenePhase == .active,
            hingeDegrees: $hingeDegrees,
            coverAvailable: $coverAvailable
        ))
        .sheet(isPresented: $showSettings) {
            ReaderSettingsView(coverAvailable: coverAvailable)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showContents) {
            ContentsView(bookID: bookID, model: model)
        }
    }

    // MARK: Layout

    private func configure(_ size: CGSize) {
        lastSize = size
        let width = Int(size.width.rounded(.down))
        let height = Int(size.height.rounded(.down))
        guard width > 100, height > 100 else { return }
        // Breit (Innendisplay, iPad, Querformat): aufgeschlagenes Buch. Schmal (Außendisplay): Einzelseite.
        let spread = width >= 560
        isSpread = spread
        model.update(layout: PageLayout(
            pageWidth: spread ? width / 2 : width,
            height: height,
            spread: spread,
            fontSize: fontSize,
            font: ReadingFont(rawValue: fontRaw) ?? .iowan,
            lineHeight: lineHeight,
            margin: pageMargin + (spread ? 6 : 0)
        ))
    }

    // MARK: Scharnier-Effekt

    /// Beim Aufklappen des Duo schwingt der Buchdeckel mit dem Scharnier auf.
    @ViewBuilder
    private var hingeCover: some View {
        if hingeEffect, isSpread, let degrees = hingeDegrees, degrees < 118 {
            let t = min(1, max(0, (degrees - 62) / 56))
            GeometryReader { geo in
                CoverArt(image: coverImage, title: bookTitle, author: bookAuthor)
                    .frame(width: geo.size.width / 2, height: geo.size.height)
                    .rotation3DEffect(.degrees(-178 * t), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: 0.35)
                    .offset(x: geo.size.width / 2)
                    .opacity(t > 0.5 ? 0 : 1)
                CoverBack(theme: theme)
                    .frame(width: geo.size.width / 2, height: geo.size.height)
                    .rotation3DEffect(.degrees(178 * (1 - t)), axis: (x: 0, y: 1, z: 0), anchor: .trailing, perspective: 0.35)
                    .opacity(t > 0.5 ? Double(2 - 2 * t) : 0)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    // MARK: Oberflächen

    private var loadingOverlay: some View {
        VStack(spacing: 16) {
            CoverArt(image: coverImage, title: bookTitle, author: bookAuthor)
                .frame(width: 96, height: 144)
            ProgressView(value: model.progressValue)
                .frame(width: 170)
                .tint(Color.primary.opacity(0.6))
            Text("Seiten werden gesetzt …")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private var pageLabel: String {
        let total = max(1, model.totalPages)
        if model.spread {
            let left = model.index + 1
            let right = min(total, model.index + 2)
            return left == right ? "Seite \(left) von \(total)" : "Seiten \(left)–\(right) von \(total)"
        }
        return "Seite \(model.index + 1) von \(total)"
    }

    private var chromeOverlay: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Button { close() } label: { Image(systemName: "chevron.down") }
                VStack(spacing: 1) {
                    Text(bookTitle)
                        .font(.system(.subheadline, design: .serif).weight(.semibold))
                        .lineLimit(1)
                    if !model.currentTitle.isEmpty {
                        Text(model.currentTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
                Button { toggleBookmark() } label: {
                    Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                        .contentTransition(.symbolEffect(.replace))
                }
                Button { showContents = true } label: { Image(systemName: "list.bullet") }
                Button { showSettings = true } label: { Image(systemName: "textformat.size") }
            }
            .font(.title3)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .transition(.move(edge: .top).combined(with: .opacity))

            Spacer()

            VStack(spacing: 6) {
                Slider(value: $sliderValue, in: 0...1) { editing in
                    scrubbing = editing
                    if !editing { model.jump(toGlobalFraction: sliderValue) }
                }
                HStack {
                    Text(pageLabel)
                    Spacer()
                    Text("\(Int((model.progress * 100).rounded())) %")
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .tint(Color.primary)
    }

    private func close() {
        library.flushStats()
        onClose()
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
            $0.chapter == model.chapter && $0.fraction >= range.0 - 0.0001 && $0.fraction < range.1 - 0.0001
        }
    }

    private var isBookmarked: Bool {
        bookmarkOnPage() != nil
    }

    private func toggleBookmark() {
        guard let range = pageRange() else { return }
        Haptics.tap()
        if let existing = bookmarkOnPage() {
            library.removeBookmark(bookID, existing.id)
        } else {
            let chapterTitle = model.currentTitle
            let label = chapterTitle.isEmpty ? "Seite \(model.index + 1)" : "\(chapterTitle) · Seite \(model.index + 1)"
            library.addBookmark(bookID, Bookmark(chapter: model.chapter, fraction: range.0, label: label))
        }
    }
}

/// Innenseite des Buchdeckels für den Scharnier-Effekt.
private struct CoverBack: View {
    let theme: ReadingTheme

    var body: some View {
        ZStack {
            theme.swiftUIBackground
            LinearGradient(colors: [.clear, .black.opacity(0.18)], startPoint: .leading, endPoint: .trailing)
        }
    }
}

// MARK: - Einstellungen

struct ReaderSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let coverAvailable: Bool

    @AppStorage("fontSize") private var fontSize = 19
    @AppStorage("themeChoice") private var themeRaw = ThemeChoice.auto.rawValue
    @AppStorage("readingFont") private var fontRaw = ReadingFont.iowan.rawValue
    @AppStorage("lineHeight") private var lineHeight = 1.55
    @AppStorage("pageMargin") private var pageMargin = 26
    @AppStorage("pageSound") private var pageSound = false
    @AppStorage("hingeEffect") private var hingeEffect = true
    @AppStorage("coverOnOuter") private var coverOnOuter = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Darstellung") {
                    HStack(spacing: 14) {
                        ForEach(ThemeChoice.allCases) { item in
                            Button {
                                Haptics.tap()
                                themeRaw = item.rawValue
                            } label: {
                                VStack(spacing: 6) {
                                    swatch(item)
                                        .frame(width: 44, height: 44)
                                        .overlay(
                                            Circle().stroke(themeRaw == item.rawValue ? Color.accentColor : Color.gray.opacity(0.35),
                                                            lineWidth: themeRaw == item.rawValue ? 3 : 1)
                                        )
                                    Text(item.title).font(.caption)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Schrift") {
                    Picker("Schriftart", selection: $fontRaw) {
                        ForEach(ReadingFont.allCases) { font in
                            Text(font.title).font(font.preview).tag(font.rawValue)
                        }
                    }
                    Stepper(value: $fontSize, in: 13...30) {
                        LabeledContent("Größe", value: "\(fontSize) pt")
                    }
                    Picker("Zeilenabstand", selection: $lineHeight) {
                        Text("Eng").tag(1.35)
                        Text("Normal").tag(1.55)
                        Text("Weit").tag(1.8)
                    }
                    .pickerStyle(.segmented)
                    Picker("Seitenrand", selection: $pageMargin) {
                        Text("Schmal").tag(16)
                        Text("Normal").tag(26)
                        Text("Breit").tag(40)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Gefühl") {
                    Toggle("Umblättergeräusch", isOn: $pageSound)
                    if DuoFeatures.hingeCompiled {
                        Toggle("Buchdeckel folgt dem Scharnier", isOn: $hingeEffect)
                    }
                }

                if DuoFeatures.coverCompiled {
                    Section {
                        Toggle("Cover auf dem Außendisplay", isOn: $coverOnOuter)
                        if coverOnOuter {
                            LabeledContent("Status", value: coverAvailable ? "Wird angezeigt" : "Nicht verfügbar")
                        }
                    } header: {
                        Text("iPhone Duo")
                    } footer: {
                        Text("iOS erlaubt Inhalte auf dem Außendisplay nur, während die Kamera aktiv ist. Wenn du das einschaltest, läuft die Kamera beim Lesen im Hintergrund mit. Es wird nichts aufgenommen oder gespeichert, aber der Akku wird stärker belastet und der grüne Kamerapunkt leuchtet.")
                    }
                }
            }
            .navigationTitle("Leseeinstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func swatch(_ item: ThemeChoice) -> some View {
        switch item {
        case .auto:
            ZStack {
                Circle().fill(ReadingTheme.paper.swiftUIBackground)
                Circle().trim(from: 0, to: 0.5).fill(ReadingTheme.dark.swiftUIBackground).rotationEffect(.degrees(-90))
            }
        case .paper:
            Circle().fill(ReadingTheme.paper.swiftUIBackground)
        case .sepia:
            Circle().fill(ReadingTheme.sepia.swiftUIBackground)
        case .dark:
            Circle().fill(ReadingTheme.dark.swiftUIBackground)
        }
    }
}

// MARK: - Inhalt und Lesezeichen

struct ContentsView: View {
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    @ObservedObject var model: ReaderModel
    @State private var tab = 0

    private var bookmarks: [Bookmark] {
        library.book(bookID)?.bookmarks ?? []
    }

    private var currentEntry: TOCEntry? {
        model.toc.last { $0.chapter <= model.chapter }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Inhalt").tag(0)
                    Text("Lesezeichen").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if tab == 0 {
                    contents
                } else {
                    bookmarkList
                }
            }
            .navigationTitle(tab == 0 ? "Inhalt" : "Lesezeichen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }

    private var contents: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(model.toc) { entry in
                    Button {
                        model.jump(chapter: entry.chapter, fraction: 0)
                        dismiss()
                    } label: {
                        HStack {
                            Text(entry.title)
                                .font(.system(.body, design: .serif))
                                .fontWeight(entry.id == currentEntry?.id ? .semibold : .regular)
                            Spacer()
                            if entry.id == currentEntry?.id {
                                Image(systemName: "book.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .id(entry.id)
                }
            }
            .listStyle(.plain)
            .overlay {
                if model.toc.isEmpty {
                    ContentUnavailableView("Kein Inhaltsverzeichnis", systemImage: "list.bullet",
                                           description: Text("Dieses Buch bringt kein Inhaltsverzeichnis mit."))
                }
            }
            .onAppear {
                if let current = currentEntry {
                    proxy.scrollTo(current.id, anchor: .center)
                }
            }
        }
    }

    private var bookmarkList: some View {
        List {
            ForEach(bookmarks) { bookmark in
                Button {
                    model.jump(chapter: bookmark.chapter, fraction: bookmark.fraction)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bookmark.label)
                            .font(.system(.body, design: .serif))
                        Text(bookmark.date, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
            }
            .onDelete { offsets in
                let ids = offsets.map { bookmarks[$0].id }
                for id in ids { library.removeBookmark(bookID, id) }
            }
        }
        .listStyle(.plain)
        .overlay {
            if bookmarks.isEmpty {
                ContentUnavailableView("Keine Lesezeichen", systemImage: "bookmark",
                                       description: Text("Tippe oben auf das Lesezeichen, um die aktuelle Seite zu merken."))
            }
        }
    }
}
