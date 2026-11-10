import SwiftUI
import UIKit

/// Blättert mit dem echten Seitenumblätter-Effekt (wie Apple Books).
struct PagerView: UIViewControllerRepresentable {
    @ObservedObject var model: ReaderModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: nil
        )
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        pager.isDoubleSided = false
        context.coordinator.pager = pager

        for recognizer in pager.gestureRecognizers where recognizer is UITapGestureRecognizer {
            recognizer.isEnabled = false
        }
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        pager.view.addGestureRecognizer(tap)
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        pager.view.backgroundColor = model.theme.background
        context.coordinator.sync()
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate,
                             UIGestureRecognizerDelegate {
        let model: ReaderModel
        weak var pager: UIPageViewController?
        private var builtVersion = -1
        private var lastJump: UUID?
        private var cache: [String: PageVC] = [:]
        private var animating = false

        init(model: ReaderModel) {
            self.model = model
        }

        // MARK: Zustand abgleichen

        func sync() {
            if builtVersion != model.version {
                builtVersion = model.version
                rebuild()
            }
            if let jump = model.pendingJump, jump.id != lastJump {
                lastJump = jump.id
                show(jump.chapter, jump.page, animated: false, forward: true)
            }
        }

        private func rebuild() {
            cache.removeAll()
            guard !model.counts.isEmpty else { return }
            let chapter = min(max(0, model.startChapter), model.counts.count - 1)
            let count = model.counts[chapter]
            let page = min(count - 1, max(0, Int(model.startFraction * Double(count))))
            show(chapter, page, animated: false, forward: true)
        }

        private func show(_ chapter: Int, _ page: Int, animated: Bool, forward: Bool) {
            guard let pager, let controller = makeController(chapter, page) else { return }
            pager.setViewControllers(
                [controller],
                direction: forward ? .forward : .reverse,
                animated: animated,
                completion: nil
            )
            report(controller)
        }

        // MARK: Seiten

        private func key(_ chapter: Int, _ page: Int) -> String {
            "\(chapter)-\(page)"
        }

        private func makeController(_ chapter: Int, _ page: Int) -> PageVC? {
            guard let layout = model.layout,
                  chapter >= 0, chapter < model.counts.count, chapter < model.files.count,
                  page >= 0, page < model.counts[chapter] else { return nil }
            let id = key(chapter, page)
            if let existing = cache[id] { return existing }
            let controller = PageVC(
                chapter: chapter,
                page: page,
                fileURL: model.files[chapter],
                root: model.root,
                layout: layout,
                theme: model.theme
            )
            cache[id] = controller
            return controller
        }

        private func next(_ chapter: Int, _ page: Int) -> (Int, Int)? {
            guard chapter < model.counts.count else { return nil }
            if page + 1 < model.counts[chapter] { return (chapter, page + 1) }
            if chapter + 1 < model.counts.count { return (chapter + 1, 0) }
            return nil
        }

        private func previous(_ chapter: Int, _ page: Int) -> (Int, Int)? {
            if page > 0 { return (chapter, page - 1) }
            if chapter > 0, chapter - 1 < model.counts.count { return (chapter - 1, model.counts[chapter - 1] - 1) }
            return nil
        }

        private func report(_ controller: PageVC) {
            let chapter = controller.chapter
            let page = controller.page
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.model.setCurrent(chapter: chapter, page: page)
                self.prefetch(chapter, page)
            }
        }

        /// Lädt Nachbarseiten vor, damit beim Umblättern keine leere Seite erscheint.
        private func prefetch(_ chapter: Int, _ page: Int) {
            var keep: Set<String> = [key(chapter, page)]
            if let n = next(chapter, page), let c = makeController(n.0, n.1) {
                c.loadViewIfNeeded()
                keep.insert(key(n.0, n.1))
            }
            if let p = previous(chapter, page), let c = makeController(p.0, p.1) {
                c.loadViewIfNeeded()
                keep.insert(key(p.0, p.1))
            }
            for stale in cache.keys where !keep.contains(stale) {
                cache.removeValue(forKey: stale)
            }
        }

        // MARK: Datenquelle

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let current = viewController as? PageVC,
                  let target = next(current.chapter, current.page) else { return nil }
            return makeController(target.0, target.1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let current = viewController as? PageVC,
                  let target = previous(current.chapter, current.page) else { return nil }
            return makeController(target.0, target.1)
        }

        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let current = pageViewController.viewControllers?.first as? PageVC else { return }
            report(current)
        }

        // MARK: Tippen

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let x = recognizer.location(in: view).x / max(1, view.bounds.width)
            if x < 0.22 {
                turn(forward: false)
            } else if x > 0.78 {
                turn(forward: true)
            } else {
                model.chrome.toggle()
            }
        }

        private func turn(forward: Bool) {
            guard !animating, let pager,
                  let current = pager.viewControllers?.first as? PageVC else { return }
            let target = forward ? next(current.chapter, current.page) : previous(current.chapter, current.page)
            guard let target, let controller = makeController(target.0, target.1) else { return }
            animating = true
            pager.setViewControllers(
                [controller],
                direction: forward ? .forward : .reverse,
                animated: true
            ) { [weak self] _ in
                self?.animating = false
                self?.report(controller)
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
