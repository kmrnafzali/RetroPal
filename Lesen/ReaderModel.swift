import SwiftUI

struct JumpTarget: Equatable {
    let id = UUID()
    let index: Int
}

@MainActor
final class ReaderModel: ObservableObject {
    let root: URL
    let files: [URL]
    let engine: BookEngine
    var toc: [TOCEntry] = []

    @Published var counts: [Int] = []
    @Published var layout: PageLayout?
    @Published var theme: ReadingTheme
    @Published var version = 0
    @Published var isPaginating = true
    @Published var progressValue = 0.0
    /// Fortlaufender Index der aktuellen Seite (im Doppelseiten-Modus die linke Seite).
    @Published var index = 0
    @Published var chapter = 0
    @Published var page = 0
    @Published var chrome = true
    @Published var pendingJump: JumpTarget?
    @Published var selection: TextSelection?
    /// Wird erhöht, wenn sich Markierungen, Auswahl oder Lesezeichen ändern.
    @Published var decorVersion = 0

    var bookmarks: [Bookmark] = []
    var highlights: [Highlight] = []

    var startChapter: Int
    var startFraction: Double
    var onPosition: ((Int, Double, Double) -> Void)?
    var onToggleBookmark: ((Int) -> Void)?
    /// Vom Blätter-Controller gesetzt, damit auch Schaltflächen umblättern können.
    var turnHandler: ((Bool) -> Void)?

    private var offsets: [Int] = []
    private var pagination: Pagination?
    private var task: Task<Void, Never>?

    init(root: URL, files: [URL], chapter: Int, fraction: Double, theme: ReadingTheme) {
        self.root = root
        self.files = files
        self.engine = BookEngine(root: root, files: files)
        self.theme = theme
        self.chapter = chapter
        self.startChapter = chapter
        self.startFraction = fraction
    }

    var totalPages: Int { counts.reduce(0, +) }
    var spread: Bool { layout?.spread ?? false }

    var progress: Double {
        let total = totalPages
        guard total > 1 else { return 0 }
        return min(1, Double(index + (spread ? 1 : 0)) / Double(total - 1))
    }

    // MARK: Index-Umrechnung

    func locate(_ global: Int) -> (chapter: Int, page: Int)? {
        guard global >= 0, global < totalPages else { return nil }
        var remaining = global
        for (chapter, count) in counts.enumerated() {
            if remaining < count { return (chapter, remaining) }
            remaining -= count
        }
        return nil
    }

    /// Anteil des Kapiteltexts, der vor dieser Seite liegt.
    func fraction(chapter: Int, page: Int) -> Double {
        guard let pagination, chapter < pagination.starts.count, page < pagination.starts[chapter].count else { return 0 }
        return Double(pagination.starts[chapter][page]) / Double(max(1, pagination.lengths[chapter]))
    }

    func globalIndex(chapter: Int, fraction: Double) -> Int {
        guard let pagination, !counts.isEmpty else { return 0 }
        let target = min(max(0, chapter), counts.count - 1)
        let offset = Int(fraction * Double(pagination.lengths[target]) + 0.5)
        var page = 0
        for (candidate, start) in pagination.starts[target].enumerated() where start <= offset {
            page = candidate
        }
        return offsets[target] + page
    }

    var startIndex: Int {
        globalIndex(chapter: startChapter, fraction: startFraction)
    }

    func title(forChapter chapter: Int) -> String {
        toc.last(where: { $0.chapter <= chapter })?.title ?? ""
    }

    var currentTitle: String {
        title(forChapter: chapter)
    }

    // MARK: Layout und Thema

    private func captureStart() {
        if !counts.isEmpty, chapter < counts.count {
            startChapter = chapter
            startFraction = fraction(chapter: chapter, page: page)
        }
    }

    /// Neue Geometrie oder Schrift: Seiten neu aufteilen, Leseposition behalten.
    func update(layout newLayout: PageLayout) {
        if newLayout == layout { return }
        captureStart()
        layout = newLayout
        counts = []
        offsets = []
        pagination = nil
        isPaginating = true
        progressValue = 0
        task?.cancel()
        engine.configure(layout: newLayout, theme: theme)

        let theme = self.theme
        task = Task { [weak self] in
            guard let engine = self?.engine else { return }
            let result = await engine.paginate(layout: newLayout, theme: theme) { value in
                self?.progressValue = value
            }
            guard !Task.isCancelled, let self, let result, self.layout == newLayout else { return }
            var running = 0
            var prefix: [Int] = []
            for pages in result.starts {
                prefix.append(running)
                running += max(1, pages.count)
            }
            self.pagination = result
            self.offsets = prefix
            self.counts = result.starts.map { max(1, $0.count) }
            self.isPaginating = false
            self.version += 1
        }
    }

    func setTheme(_ newTheme: ReadingTheme) {
        guard newTheme != theme else { return }
        captureStart()
        theme = newTheme
        if let layout {
            engine.configure(layout: layout, theme: newTheme)
        }
        if !counts.isEmpty { version += 1 }
    }

    // MARK: Position

    func setCurrent(index newIndex: Int) {
        guard let location = locate(newIndex) else { return }
        index = newIndex
        chapter = location.chapter
        page = location.page
        onPosition?(location.chapter, fraction(chapter: location.chapter, page: location.page), progress)
        engine.prefetch(location.chapter + 1)
        engine.prefetch(location.chapter - 1)
    }

    func jump(toGlobalFraction value: Double) {
        let total = totalPages
        guard total > 0 else { return }
        let target = min(total - 1, max(0, Int((value * Double(total - 1)).rounded())))
        pendingJump = JumpTarget(index: target)
    }

    func jump(chapter: Int, fraction: Double) {
        guard !counts.isEmpty else { return }
        pendingJump = JumpTarget(index: globalIndex(chapter: chapter, fraction: fraction))
    }

    // MARK: Lesezeichen, Markierungen, Auswahl

    func pageRange(chapter: Int, page: Int) -> NSRange? {
        guard let pagination, chapter >= 0, chapter < pagination.starts.count,
              page >= 0, page < pagination.starts[chapter].count else { return nil }
        let start = pagination.starts[chapter][page]
        let end = page + 1 < pagination.starts[chapter].count ? pagination.starts[chapter][page + 1] : pagination.lengths[chapter]
        return NSRange(location: start, length: max(1, end - start))
    }

    func fraction(chapter: Int, offset: Int) -> Double {
        guard let pagination, chapter >= 0, chapter < pagination.lengths.count else { return 0 }
        return Double(offset) / Double(max(1, pagination.lengths[chapter]))
    }

    func bookmark(chapter: Int, page: Int) -> Bookmark? {
        guard let pagination, let range = pageRange(chapter: chapter, page: page) else { return nil }
        let length = Double(pagination.lengths[chapter])
        return bookmarks.first {
            $0.chapter == chapter && NSLocationInRange(Int($0.fraction * length + 0.5), range)
        }
    }

    func hasBookmark(chapter: Int, range: NSRange) -> Bool {
        guard let pagination, chapter < pagination.lengths.count else { return false }
        let length = Double(pagination.lengths[chapter])
        return bookmarks.contains {
            $0.chapter == chapter && NSLocationInRange(Int($0.fraction * length + 0.5), range)
        }
    }

    func select(_ newSelection: TextSelection?) {
        selection = newSelection
        decorVersion += 1
    }

    func refreshDecor() {
        decorVersion += 1
    }
}
