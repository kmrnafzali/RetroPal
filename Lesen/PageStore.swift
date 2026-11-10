import os
import QuartzCore
import UIKit

/// Hält die Seiten rund um die Lesestelle als fertige Bilder bereit.
/// Gezeichnet wird auf einer eigenen Warteschlange, der Hauptthread zeigt nur noch an.
@MainActor
final class PageStore {
    private struct Entry {
        let image: UIImage
        let decor: PageDecor
    }

    private var entries: [Int: Entry] = [:]
    private var pending: [Int: PageDecor] = [:]
    private var waiters: [Int: [() -> Void]] = [:]
    private var generation = 0
    private let queue = DispatchQueue(label: "lesen.seiten", qos: .userInitiated)
    private var memoryObserver: NSObjectProtocol?

    /// Wird gerufen, sobald ein Seitenbild fertig ist.
    var onReady: ((Int) -> Void)?

    init() {
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.entries.removeAll()
            }
        }
    }

    deinit {
        if let memoryObserver {
            NotificationCenter.default.removeObserver(memoryObserver)
        }
    }

    /// Alles verwerfen (neue Schrift, neues Format, neues Thema).
    func reset() {
        generation += 1
        entries.removeAll()
        pending.removeAll()
        flushAllWaiters()
    }

    private func flushAllWaiters() {
        let waiting = waiters
        waiters.removeAll()
        for list in waiting.values {
            for done in list { done() }
        }
    }

    private func flushWaiters(_ index: Int) {
        guard let list = waiters.removeValue(forKey: index) else { return }
        for done in list { done() }
    }

    func image(_ index: Int, decor: PageDecor) -> UIImage? {
        guard let entry = entries[index], entry.decor == decor else { return nil }
        return entry.image
    }

    func isReady(_ job: PageJob) -> Bool {
        entries[job.spec.index]?.decor == job.decor
    }

    /// Seite im Hintergrund zeichnen lassen. `done` kommt genau einmal zurück.
    func request(_ job: PageJob, done: (() -> Void)? = nil) {
        let index = job.spec.index
        if isReady(job) {
            done?()
            return
        }
        if let done {
            waiters[index, default: []].append(done)
        }
        if pending[index] == job.decor { return }
        pending[index] = job.decor
        let expected = generation
        queue.async { [weak self] in
            let image = PageRenderer.render(job)
            DispatchQueue.main.async {
                guard let self, expected == self.generation, self.pending[index] == job.decor else { return }
                self.pending.removeValue(forKey: index)
                self.entries[index] = Entry(image: image, decor: job.decor)
                self.flushWaiters(index)
                self.onReady?(index)
            }
        }
    }

    func prepare(_ jobs: [PageJob], done: @escaping () -> Void) {
        var remaining = jobs.count
        guard remaining > 0 else {
            done()
            return
        }
        for job in jobs {
            request(job) {
                remaining -= 1
                if remaining == 0 { done() }
            }
        }
    }

    func prepare(_ jobs: [PageJob]) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            prepare(jobs) {
                continuation.resume()
            }
        }
    }

    /// Notlösung: Seite sofort auf dem Hauptthread zeichnen. Das ist genau der Ruckler,
    /// den das Vorab-Zeichnen verhindern soll – deshalb wird jeder Fall gezählt.
    func renderNow(_ job: PageJob, counted: Bool) -> UIImage {
        let index = job.spec.index
        if counted {
            ReaderDiagnostics.shared.recordSyncRender()
        }
        let image = PageRenderer.render(job)
        pending.removeValue(forKey: index)
        entries[index] = Entry(image: image, decor: job.decor)
        flushWaiters(index)
        return image
    }

    /// Bilder außerhalb des Fensters um die Lesestelle freigeben.
    func trim(keeping range: ClosedRange<Int>) {
        for key in entries.keys where !range.contains(key) {
            entries.removeValue(forKey: key)
        }
    }

    var count: Int { entries.count }
}

// MARK: - Messwerte

/// Sammelt Messwerte zum Umblättern und zur Bildschirmgeometrie.
/// Sie stehen in den Leseeinstellungen unter „Diagnose" und in den automatischen Tests.
final class ReaderDiagnostics: @unchecked Sendable {
    static let shared = ReaderDiagnostics()
    static let signposter = OSSignposter(subsystem: "de.kmrn.lesen", category: "Lesen")

    private let lock = NSLock()
    private var renders = 0
    private var renderTotal = 0.0
    private var renderMax = 0.0
    private var syncRenders = 0
    private var mainBuilds = 0
    private var turns = 0
    private var worstFrame = 0.0
    private var lastWorstFrame = 0.0
    private var lastRate = 0.0
    private var geometry: [String] = []
    private var mismatch = ""

    func reset() {
        lock.lock()
        renders = 0
        renderTotal = 0
        renderMax = 0
        syncRenders = 0
        mainBuilds = 0
        turns = 0
        worstFrame = 0
        lastWorstFrame = 0
        lastRate = 0
        mismatch = ""
        lock.unlock()
    }

    func recordRender(milliseconds: Double) {
        lock.lock()
        renders += 1
        renderTotal += milliseconds
        renderMax = max(renderMax, milliseconds)
        lock.unlock()
    }

    func recordSyncRender() {
        lock.lock()
        syncRenders += 1
        lock.unlock()
    }

    /// Ein Kapitel musste auf dem Hauptthread gesetzt werden.
    func recordMainBuild() {
        lock.lock()
        mainBuilds += 1
        lock.unlock()
    }

    func recordTurn(worstFrame milliseconds: Double, rate: Double) {
        lock.lock()
        turns += 1
        lastWorstFrame = milliseconds
        lastRate = rate
        worstFrame = max(worstFrame, milliseconds)
        lock.unlock()
    }

    func setGeometry(_ lines: [String]) {
        lock.lock()
        geometry = lines
        lock.unlock()
    }

    func noteMismatch(expected: CGSize, actual: CGSize) {
        lock.lock()
        mismatch = "Seitenfläche \(Int(actual.width))×\(Int(actual.height)) statt \(Int(expected.width))×\(Int(expected.height))"
        lock.unlock()
    }

    var syncRenderCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return syncRenders
    }

    var mainBuildCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return mainBuilds
    }

    var turnCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return turns
    }

    var worstFrameMilliseconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return worstFrame
    }

    var hasMismatch: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !mismatch.isEmpty
    }

    /// Lesbare Zusammenfassung.
    func summary(maximumRate: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var lines: [String] = []
        lines.append("Display: bis \(maximumRate) Hz")
        if turns > 0 {
            lines.append(String(format: "Umblättern: %d×, zuletzt %.0f Bilder/s, längstes Bild %.1f ms (schlechtestes %.1f ms)",
                                turns, lastRate, lastWorstFrame, worstFrame))
        } else {
            lines.append("Umblättern: noch nicht gemessen")
        }
        if renders > 0 {
            lines.append(String(format: "Seiten vorab gezeichnet: %d, im Schnitt %.1f ms, längstens %.1f ms",
                                renders, renderTotal / Double(renders), renderMax))
        }
        lines.append("Seiten erst beim Blättern gezeichnet: \(syncRenders)")
        lines.append("Kapitel erst beim Blättern gesetzt: \(mainBuilds)")
        lines.append(contentsOf: geometry)
        if !mismatch.isEmpty {
            lines.append(mismatch)
        }
        return lines
    }
}

/// Misst während des Umblätterns den Abstand zwischen zwei Bildern
/// und bittet das Display dabei um 120 Hz.
@MainActor
final class FrameMonitor: NSObject {
    private var link: CADisplayLink?
    private var first: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var worst: CFTimeInterval = 0
    private var frames = 0
    private var signpost: OSSignpostIntervalState?

    func begin() {
        guard link == nil else { return }
        first = 0
        last = 0
        worst = 0
        frames = 0
        signpost = ReaderDiagnostics.signposter.beginInterval("Umblättern")
        let created = CADisplayLink(target: self, selector: #selector(tick(_:)))
        created.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        created.add(to: .main, forMode: .common)
        link = created
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if last > 0 {
            worst = max(worst, now - last)
            frames += 1
        } else {
            first = now
        }
        last = now
    }

    func end() {
        guard let link else { return }
        link.invalidate()
        self.link = nil
        if let signpost {
            ReaderDiagnostics.signposter.endInterval("Umblättern", signpost)
        }
        signpost = nil
        let duration = last - first
        guard frames >= 4, duration > 0 else { return }
        ReaderDiagnostics.shared.recordTurn(worstFrame: worst * 1000, rate: Double(frames) / duration)
    }
}
