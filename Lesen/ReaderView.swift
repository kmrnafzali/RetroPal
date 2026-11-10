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
    @State private var lookupTerm: LookupTerm?
    @State private var noteTarget: UUID?
    @State private var noteText = ""
    @State private var showNote = false
    @State private var lid: LidPhase = .closed
    @State private var closing = false

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
        initial.bookmarks = book.bookmarks
        initial.highlights = book.highlights ?? []
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
        case .paper, .sepia, .candle: return .light
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
                let fold = DuoFold.division(geo)
                if let fold, fold.width > fold.height, fold.minY > 160 {
                    // Tisch-Modus: Seite oben, Steuerung unter dem Falz
                    VStack(spacing: 0) {
                        pager(size: CGSize(width: geo.size.width, height: fold.minY))
                        Color.clear.frame(height: fold.height)
                        TabletopPanel(model: model, title: bookTitle, pageLabel: pageLabel,
                                      onClose: close, onSettings: { showSettings = true },
                                      onContents: { showContents = true })
                            .frame(height: max(0, geo.size.height - fold.maxY))
                    }
                } else {
                    pager(size: geo.size)
                }
            }

            if theme == .candle {
                CandleGlow()
            }


            if model.isPaginating {
                loadingOverlay
            }
            if model.chrome && !model.isPaginating && model.selection == nil {
                chromeOverlay
            }
            if let selection = model.selection {
                VStack {
                    Spacer()
                    selectionCard(selection)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            coverLid
        }
        .modifier(ImmersiveBars())
        .preferredColorScheme(forcedScheme)
        .statusBarHidden(!model.chrome)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: model.chrome)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: model.selection)
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
        .onAppear(perform: start)
        .onChange(of: isSpread) { old, new in
            // Beim Aufklappen des Duo klappt auch der Buchdeckel noch einmal auf.
            if new && !old && lid == .gone && !closing { openLid() }
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
            ContentsView(bookID: bookID, model: model, onChange: syncDecor)
        }
        .sheet(item: $lookupTerm) { term in
            DictionaryView(term: term.text)
                .presentationDetents([.medium, .large])
        }
        .alert("Notiz", isPresented: $showNote) {
            TextField("Dein Gedanke dazu", text: $noteText)
            Button("Sichern") {
                if let target = noteTarget {
                    library.setNote(bookID, highlightID: target, note: noteText)
                    syncDecor()
                }
            }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    private func pager(size: CGSize) -> some View {
        let spread = size.width >= 560
        return PagerView(model: model, spread: spread)
            .id(spread)
            .frame(width: size.width, height: size.height)
            .onAppear { configure(size) }
            .onChange(of: size) { _, newSize in configure(newSize) }
    }

    private func start() {
        let id = bookID
        model.onPosition = { chapter, fraction, progress in
            library.updatePosition(id, chapter: chapter, fraction: fraction, progress: progress)
        }
        model.onToggleBookmark = { index in
            toggleBookmark(at: index)
        }
        openLid()
        model.setTheme(theme)
        library.markOpened(id)
        library.ensureTOC(id)
        model.toc = library.book(id)?.toc ?? []
        syncDecor()
    }

    /// Lesezeichen und Markierungen aus der Bibliothek in die Seiten übernehmen.
    private func syncDecor() {
        guard let book = library.book(bookID) else { return }
        model.bookmarks = book.bookmarks
        model.highlights = book.highlights ?? []
        model.refreshDecor()
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
            margin: pageMargin + (spread ? 8 : 0)
        ))
    }

    // MARK: Buchdeckel

    /// Der Deckel liegt beim Öffnen in der Bildschirmmitte und klappt auf.
    /// Beim Schließen klappt er wieder zu, bevor das Buch ins Regal zurückfliegt.
    @ViewBuilder
    private var coverLid: some View {
        if lid != .gone {
            GeometryReader { geo in
                let rect = CoverGeometry.centerRect(in: geo.size)
                let open = lid == .open
                ZStack {
                    theme.swiftUIBackground
                        .opacity(open ? 0 : 1)
                    CoverArt(image: coverImage, title: bookTitle, author: bookAuthor)
                        .frame(width: rect.width, height: rect.height)
                        .scaleEffect(open ? 1.25 : 1, anchor: .leading)
                        .rotation3DEffect(.degrees(open ? -118 : 0), axis: (x: 0, y: 1, z: 0),
                                          anchor: .leading, perspective: 0.42)
                        .opacity(open ? 0 : 1)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(lid == .closed)
        }
    }

    private func openLid() {
        lid = .closed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeInOut(duration: 0.75)) {
                lid = .open
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if lid == .open { lid = .gone }
            }
        }
    }

    // MARK: Oberflächen

    private var loadingOverlay: some View {
        VStack(spacing: 16) {
            CoverArt(image: coverImage, title: bookTitle, author: bookAuthor)
                .frame(width: 96, height: 144)
            ProgressView(value: model.progressValue)
                .frame(width: 170)
                .tint(Wood.brass)
            Text("Das Buch wird gesetzt …")
                .font(.system(.footnote, design: .serif))
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
            HStack(spacing: 6) {
                chromeButton("chevron.down", action: close)
                VStack(spacing: 2) {
                    Text(bookTitle)
                        .font(.system(.subheadline, design: .serif).weight(.semibold))
                        .lineLimit(1)
                    if !model.currentTitle.isEmpty {
                        Text(model.currentTitle.uppercased())
                            .font(.system(size: 10, weight: .medium))
                            .tracking(1)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
                chromeButton(isBookmarked ? "bookmark.fill" : "bookmark") {
                    toggleBookmark(at: model.index)
                }
                chromeButton("list.bullet") { showContents = true }
                chromeButton("textformat.size") { showSettings = true }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5) }
            .transition(.move(edge: .top).combined(with: .opacity))

            Spacer()

            VStack(spacing: 6) {
                Slider(value: $sliderValue, in: 0...1) { editing in
                    scrubbing = editing
                    if !editing { model.jump(toGlobalFraction: sliderValue) }
                }
                .tint(Wood.brass)
                HStack {
                    Text(pageLabel)
                    Spacer()
                    Text("\(Int((model.progress * 100).rounded())) %")
                }
                .font(.system(.caption, design: .serif))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5) }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func chromeButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 42, height: 42)
                .contentShape(Rectangle())
        }
        .tint(Color.primary)
    }

    // MARK: Auswahl

    private func selectionCard(_ selection: TextSelection) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(selection.wordText)
                    .font(.system(.title3, design: .serif).weight(.semibold))
                Spacer()
                Button {
                    model.select(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            Text(selection.sentenceText)
                .font(.system(.footnote, design: .serif))
                .italic()
                .foregroundStyle(.secondary)
                .lineLimit(3)

            HStack(spacing: 10) {
                actionButton("Nachschlagen", "character.book.closed") {
                    lookupTerm = LookupTerm(text: selection.wordText)
                }
                if let existing = selection.highlightID {
                    actionButton("Notiz", "square.and.pencil") {
                        beginNote(for: existing)
                    }
                    actionButton("Entfernen", "highlighter") {
                        library.removeHighlight(bookID, existing)
                        syncDecor()
                        model.select(nil)
                    }
                } else {
                    actionButton("Markieren", "highlighter") {
                        _ = addHighlight(selection)
                        model.select(nil)
                    }
                    actionButton("Notiz", "square.and.pencil") {
                        let id = addHighlight(selection)
                        beginNote(for: id)
                    }
                }
                ShareLink(item: "„\(selection.sentenceText)“\n— \(bookTitle)") {
                    actionLabel("Teilen", "square.and.arrow.up")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 18, y: 6)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: 520)
    }

    private func actionLabel(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func actionButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            actionLabel(title, symbol)
        }
        .buttonStyle(.plain)
    }

    private func addHighlight(_ selection: TextSelection) -> UUID {
        let highlight = Highlight(
            chapter: selection.chapter,
            start: selection.sentence.location,
            length: selection.sentence.length,
            text: selection.sentenceText
        )
        library.addHighlight(bookID, highlight)
        syncDecor()
        return highlight.id
    }

    private func beginNote(for highlightID: UUID) {
        noteTarget = highlightID
        noteText = library.book(bookID)?.highlights?.first(where: { $0.id == highlightID })?.note ?? ""
        model.select(nil)
        showNote = true
    }

    private func close() {
        guard !closing else { return }
        closing = true
        library.flushStats()
        lid = .open
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            withAnimation(.easeInOut(duration: 0.5)) {
                lid = .closed
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                onClose()
            }
        }
    }

    // MARK: Lesezeichen

    private var isBookmarked: Bool {
        guard let location = model.locate(model.index) else { return false }
        return model.bookmark(chapter: location.chapter, page: location.page) != nil
    }

    private func toggleBookmark(at index: Int) {
        guard let location = model.locate(index) else { return }
        Haptics.tap()
        if let existing = model.bookmark(chapter: location.chapter, page: location.page) {
            library.removeBookmark(bookID, existing.id)
        } else {
            let chapterTitle = model.title(forChapter: location.chapter)
            let label = chapterTitle.isEmpty ? "Seite \(index + 1)" : "\(chapterTitle) · Seite \(index + 1)"
            library.addBookmark(bookID, Bookmark(
                chapter: location.chapter,
                fraction: model.fraction(chapter: location.chapter, page: location.page),
                label: label
            ))
        }
        syncDecor()
    }
}

enum LidPhase {
    case closed
    case open
    case gone
}

struct LookupTerm: Identifiable {
    let id = UUID()
    let text: String
}

/// Das eingebaute iOS-Wörterbuch (funktioniert offline, sobald ein Wörterbuch geladen ist).
struct DictionaryView: UIViewControllerRepresentable {
    let term: String

    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController {
        UIReferenceLibraryViewController(term: term)
    }

    func updateUIViewController(_ controller: UIReferenceLibraryViewController, context: Context) {}
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

/// Warmer Lichtkegel mit dunklen Rändern für das Kerzenlicht-Thema.
private struct CandleGlow: View {
    @State private var flicker = false

    var body: some View {
        RadialGradient(
            colors: [.clear, Color(red: 0.25, green: 0.12, blue: 0.02).opacity(flicker ? 0.50 : 0.42)],
            center: .center,
            startRadius: 120,
            endRadius: 620
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                flicker = true
            }
        }
    }
}

/// Steuerung unter dem Falz, wenn das Duo halb aufgeklappt auf dem Tisch steht.
private struct TabletopPanel: View {
    @ObservedObject var model: ReaderModel
    let title: String
    let pageLabel: String
    let onClose: () -> Void
    let onSettings: () -> Void
    let onContents: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(.headline, design: .serif))
                    .lineLimit(1)
                Text(model.currentTitle.isEmpty ? pageLabel : "\(model.currentTitle) · \(pageLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ProgressView(value: model.progress)
                .tint(Wood.brass)
                .padding(.horizontal, 30)

            HStack(spacing: 14) {
                turnButton("chevron.left", forward: false)
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        smallButton("chevron.down", action: onClose)
                        smallButton("list.bullet", action: onContents)
                        smallButton("textformat.size", action: onSettings)
                    }
                }
                turnButton("chevron.right", forward: true)
            }
            .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private func turnButton(_ symbol: String, forward: Bool) -> some View {
        Button {
            model.turnHandler?(forward)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 74)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func smallButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 48, height: 48)
                .background(Color.primary.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
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
                Section("Papier") {
                    HStack(spacing: 8) {
                        ForEach(ThemeChoice.allCases) { item in
                            Button {
                                Haptics.tap()
                                themeRaw = item.rawValue
                            } label: {
                                VStack(spacing: 6) {
                                    swatch(item)
                                        .frame(width: 42, height: 42)
                                        .overlay(
                                            Circle().stroke(themeRaw == item.rawValue ? Wood.brass : Color.gray.opacity(0.35),
                                                            lineWidth: themeRaw == item.rawValue ? 3 : 1)
                                        )
                                    Text(item.title).font(.caption2)
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

                Section {
                    Toggle("Umblättergeräusch", isOn: $pageSound)
                } header: {
                    Text("Gefühl")
                } footer: {
                    Text("Tippe auf die obere Seitenecke für ein Eselsohr. Halte ein Wort gedrückt, um es nachzuschlagen oder den Satz zu markieren.")
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
        case .candle:
            Circle().fill(
                RadialGradient(colors: [ReadingTheme.candle.swiftUIBackground, Color(red: 0.55, green: 0.36, blue: 0.15)],
                               center: .center, startRadius: 4, endRadius: 26)
            )
        case .dark:
            Circle().fill(ReadingTheme.dark.swiftUIBackground)
        }
    }
}

// MARK: - Inhalt, Lesezeichen, Markierungen

struct ContentsView: View {
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    @ObservedObject var model: ReaderModel
    let onChange: () -> Void
    @State private var tab = 0

    private var bookmarks: [Bookmark] {
        library.book(bookID)?.bookmarks ?? []
    }

    private var highlights: [Highlight] {
        (library.book(bookID)?.highlights ?? []).sorted {
            ($0.chapter, $0.start) < ($1.chapter, $1.start)
        }
    }

    private var currentEntry: TOCEntry? {
        model.toc.last(where: { $0.chapter <= model.chapter })
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Inhalt").tag(0)
                    Text("Lesezeichen").tag(1)
                    Text("Markierungen").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                switch tab {
                case 0: contents
                case 1: bookmarkList
                default: highlightList
                }
            }
            .navigationTitle(tab == 0 ? "Inhalt" : (tab == 1 ? "Lesezeichen" : "Markierungen"))
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
                                    .foregroundStyle(Wood.brass)
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
                onChange()
            }
        }
        .listStyle(.plain)
        .overlay {
            if bookmarks.isEmpty {
                ContentUnavailableView("Keine Lesezeichen", systemImage: "bookmark",
                                       description: Text("Tippe auf die obere Seitenecke, um ein Eselsohr zu knicken."))
            }
        }
    }

    private var highlightList: some View {
        List {
            ForEach(highlights) { highlight in
                Button {
                    model.jump(chapter: highlight.chapter,
                               fraction: model.fraction(chapter: highlight.chapter, offset: highlight.start))
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(highlight.text)
                            .font(.system(.callout, design: .serif))
                            .italic()
                            .lineLimit(5)
                            .padding(.leading, 10)
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color(red: 0.95, green: 0.76, blue: 0.22))
                                    .frame(width: 3)
                            }
                        if let note = highlight.note {
                            Label(note, systemImage: "square.and.pencil")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        let chapterTitle = model.title(forChapter: highlight.chapter)
                        if !chapterTitle.isEmpty {
                            Text(chapterTitle.uppercased())
                                .font(.system(size: 10, weight: .medium))
                                .tracking(1)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .foregroundStyle(.primary)
            }
            .onDelete { offsets in
                let ids = offsets.map { highlights[$0].id }
                for id in ids { library.removeHighlight(bookID, id) }
                onChange()
            }
        }
        .listStyle(.plain)
        .overlay {
            if highlights.isEmpty {
                ContentUnavailableView("Keine Markierungen", systemImage: "highlighter",
                                       description: Text("Halte ein Wort gedrückt und wähle „Markieren“, um den Satz anzustreichen."))
            }
        }
    }
}
