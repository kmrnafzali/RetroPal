import SwiftUI

struct JumpTarget: Equatable {
    let id = UUID()
    let index: Int
}

@MainActor
final class ReaderModel: ObservableObject {
    let root: URL
    let files: [URL]
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

    var startChapter: Int
    var startFraction: Double
    var onPosition: ((Int, Double, Double) -> Void)?

    private var offsets: [Int] = []
    private var task: Task<Void, Never>?

    init(root: URL, files: [URL], chapter: Int, fraction: Double, theme: ReadingTheme) {
        self.root = root
        self.files = files
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

    func globalIndex(chapter: Int, fraction: Double) -> Int {
        guard !counts.isEmpty else { return 0 }
        let target = min(max(0, chapter), counts.count - 1)
        let count = counts[target]
        let page = min(count - 1, max(0, Int(fraction * Double(count) + 0.0001)))
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
            startFraction = Double(page) / Double(max(1, counts[chapter]))
        }
    }

    /// Neue Geometrie oder Schrift: Seiten neu zählen, Leseposition behalten.
    func update(layout newLayout: PageLayout) {
        if newLayout == layout { return }
        captureStart()
        layout = newLayout
        counts = []
        offsets = []
        isPaginating = true
        progressValue = 0
        task?.cancel()

        let paginator = Paginator()
        let files = self.files
        let root = self.root
        let theme = self.theme
        task = Task { [weak self] in
            let result = await paginator.count(files: files, root: root, layout: newLayout, theme: theme) { value in
                self?.progressValue = value
            }
            guard !Task.isCancelled, let self, result.count == files.count else { return }
            var running = 0
            var prefix: [Int] = []
            for count in result {
                prefix.append(running)
                running += count
            }
            self.offsets = prefix
            self.counts = result
            self.isPaginating = false
            self.version += 1
        }
    }

    func setTheme(_ newTheme: ReadingTheme) {
        guard newTheme != theme else { return }
        captureStart()
        theme = newTheme
        if !counts.isEmpty { version += 1 }
    }

    // MARK: Position

    func setCurrent(index newIndex: Int) {
        guard let location = locate(newIndex) else { return }
        index = newIndex
        chapter = location.chapter
        page = location.page
        let fraction = Double(location.page) / Double(max(1, counts[location.chapter]))
        onPosition?(location.chapter, fraction, progress)
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
}
