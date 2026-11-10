import SwiftUI

struct JumpTarget: Equatable {
    let id = UUID()
    let chapter: Int
    let page: Int
}

@MainActor
final class ReaderModel: ObservableObject {
    let root: URL
    let files: [URL]

    @Published var counts: [Int] = []
    @Published var layout: PageLayout?
    @Published var theme: ReadingTheme
    @Published var version = 0
    @Published var isPaginating = true
    @Published var progressValue = 0.0
    @Published var chapter = 0
    @Published var page = 0
    @Published var chrome = true
    @Published var pendingJump: JumpTarget?

    var startChapter: Int
    var startFraction: Double
    var onPosition: ((Int, Double, Double) -> Void)?

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

    var globalPage: Int {
        guard chapter < counts.count else { return 0 }
        return counts.prefix(chapter).reduce(0, +) + page
    }

    var progress: Double {
        let total = totalPages
        guard total > 1 else { return 0 }
        return Double(globalPage) / Double(total - 1)
    }

    private func captureStart() {
        if !counts.isEmpty, chapter < counts.count {
            startChapter = chapter
            startFraction = Double(page) / Double(max(1, counts[chapter]))
        }
    }

    /// Neue Geometrie oder Schriftgröße: Seiten neu zählen, Leseposition behalten.
    func update(layout newLayout: PageLayout) {
        if newLayout == layout { return }
        captureStart()
        layout = newLayout
        counts = []
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
            guard !Task.isCancelled, let self else { return }
            self.counts = result
            self.isPaginating = false
            self.version += 1
        }
    }

    func setTheme(_ newTheme: ReadingTheme) {
        guard newTheme != theme else { return }
        captureStart()
        theme = newTheme
        version += 1
    }

    func setCurrent(chapter: Int, page: Int) {
        self.chapter = chapter
        self.page = page
        guard chapter < counts.count else { return }
        let fraction = Double(page) / Double(max(1, counts[chapter]))
        onPosition?(chapter, fraction, progress)
    }

    func jump(toGlobalFraction value: Double) {
        let total = totalPages
        guard total > 0 else { return }
        var remaining = Int((value * Double(total - 1)).rounded())
        for (index, count) in counts.enumerated() {
            if remaining < count {
                pendingJump = JumpTarget(chapter: index, page: remaining)
                return
            }
            remaining -= count
        }
    }

    func jump(chapter: Int, fraction: Double) {
        guard !counts.isEmpty else { return }
        let target = min(max(0, chapter), counts.count - 1)
        let count = counts[target]
        let page = min(count - 1, max(0, Int(fraction * Double(count))))
        pendingJump = JumpTarget(chapter: target, page: page)
    }
}
