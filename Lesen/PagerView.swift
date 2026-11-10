import SwiftUI
import UIKit

/// Blättert mit dem echten Seitenumblätter-Effekt.
/// Im Doppelseiten-Modus liegt der Buchrücken in der Mitte wie bei einem aufgeschlagenen Buch.
struct PagerView: UIViewControllerRepresentable {
    @ObservedObject var model: ReaderModel
    let spread: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, spread: spread)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let spine: UIPageViewController.SpineLocation = spread ? .mid : .min
        let pager = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: [.spineLocation: NSNumber(value: spine.rawValue)]
        )
        pager.isDoubleSided = spread
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        pager.view.backgroundColor = model.theme.background
        context.coordinator.pager = pager
        context.coordinator.showPlaceholders()
        let coordinator = context.coordinator
        model.turnHandler = { [weak coordinator] forward in
            coordinator?.turn(forward: forward)
        }

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
        let spread: Bool
        weak var pager: UIPageViewController?

        private var builtVersion = -1
        private var decorVersion = -1
        private var lastJump: UUID?
        private var cache: [Int: PageVC] = [:]
        private var animating = false

        init(model: ReaderModel, spread: Bool) {
            self.model = model
            self.spread = spread
        }

        /// Anzahl der Seiten inklusive einer leeren Schlussseite, damit die Doppelseite aufgeht.
        private var limit: Int {
            let total = model.totalPages
            return spread ? total + total % 2 : total
        }

        // MARK: Zustand abgleichen

        func showPlaceholders() {
            guard let pager else { return }
            let layout = model.layout ?? PageLayout(pageWidth: 300, height: 500, spread: spread, fontSize: 18,
                                                    font: .iowan, lineHeight: 1.5, margin: 24)
            func blank(_ index: Int, _ side: PageSide) -> PageVC {
                PageVC(index: index, info: nil, model: model, layout: layout, theme: model.theme, side: side)
            }
            let controllers = spread ? [blank(-2, .left), blank(-1, .right)] : [blank(-1, .single)]
            pager.setViewControllers(controllers, direction: .forward, animated: false, completion: nil)
        }

        func sync() {
            guard model.layout?.spread == spread else { return }
            if builtVersion != model.version {
                builtVersion = model.version
                cache.removeAll()
                if !model.counts.isEmpty {
                    show(model.startIndex, animated: false, forward: true)
                }
            }
            if let jump = model.pendingJump, jump.id != lastJump {
                lastJump = jump.id
                if !model.counts.isEmpty {
                    show(jump.index, animated: false, forward: true)
                }
            }
            if decorVersion != model.decorVersion {
                decorVersion = model.decorVersion
                for controller in cache.values {
                    controller.reloadDecor()
                }
            }
        }

        private func show(_ index: Int, animated: Bool, forward: Bool, completion: (() -> Void)? = nil) {
            guard let pager else { return }
            let controllers: [PageVC]
            if spread {
                let left = index - index % 2
                guard let first = controller(left), let second = controller(left + 1) else { return }
                controllers = [first, second]
            } else {
                guard let single = controller(index) else { return }
                controllers = [single]
            }
            pager.setViewControllers(
                controllers,
                direction: forward ? .forward : .reverse,
                animated: animated
            ) { _ in
                completion?()
            }
            report(controllers[0].index)
        }

        // MARK: Seiten

        private func controller(_ index: Int) -> PageVC? {
            guard let layout = model.layout, index >= 0, index < limit else { return nil }
            if let existing = cache[index] { return existing }

            let side: PageSide = spread ? (index % 2 == 0 ? .left : .right) : .single
            var info: PageInfo?
            if let location = model.locate(index), location.chapter < model.files.count {
                info = PageInfo(
                    chapter: location.chapter,
                    page: location.page,
                    number: index + 1,
                    title: model.title(forChapter: location.chapter)
                )
            }
            let created = PageVC(index: index, info: info, model: model, layout: layout,
                                 theme: model.theme, side: side)
            cache[index] = created
            return created
        }

        private func report(_ index: Int) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.model.setCurrent(index: index)
                self.prefetch(around: index)
            }
        }

        /// Hält die Nachbarseiten bereit und räumt weiter entfernte ab.
        private func prefetch(around index: Int) {
            let base = spread ? index - index % 2 : index
            let range = spread ? (base - 4)...(base + 5) : (base - 2)...(base + 2)
            for neighbour in range {
                controller(neighbour)?.loadViewIfNeeded()
            }
            for stale in cache.keys where !range.contains(stale) {
                cache.removeValue(forKey: stale)
            }
        }

        // MARK: Datenquelle

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let current = viewController as? PageVC, current.index >= 0 else { return nil }
            return controller(current.index + 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let current = viewController as? PageVC, current.index >= 0 else { return nil }
            return controller(current.index - 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let current = pageViewController.viewControllers?.first as? PageVC else { return }
            Haptics.soft()
            PageSound.shared.play()
            report(current.index)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                spineLocationFor orientation: UIInterfaceOrientation) -> UIPageViewController.SpineLocation {
            pageViewController.isDoubleSided = spread
            let needed = spread ? 2 : 1
            if (pageViewController.viewControllers?.count ?? 0) != needed {
                if model.counts.isEmpty {
                    showPlaceholders()
                } else {
                    show(model.index, animated: false, forward: true)
                }
            }
            return spread ? .mid : .min
        }

        // MARK: Tippen

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }

            // Auswahl aufheben, falls eine besteht
            if model.selection != nil {
                model.select(nil)
                return
            }

            // Tippen auf die äußere obere Ecke knickt ein Eselsohr
            if let pages = pager?.viewControllers as? [PageVC] {
                for page in pages where page.isViewLoaded {
                    let local = recognizer.location(in: page.view)
                    if page.view.bounds.contains(local), page.isCorner(local) {
                        Haptics.medium()
                        model.onToggleBookmark?(page.index)
                        return
                    }
                }
            }

            let x = recognizer.location(in: view).x / max(1, view.bounds.width)
            let edge = spread ? 0.16 : 0.24
            if x < edge {
                turn(forward: false)
            } else if x > 1 - edge {
                turn(forward: true)
            } else {
                model.chrome.toggle()
            }
        }

        func turn(forward: Bool) {
            guard !animating, !model.counts.isEmpty, let pager,
                  let current = pager.viewControllers?.first as? PageVC, current.index >= 0 else { return }
            let step = spread ? 2 : 1
            let target = current.index + (forward ? step : -step)
            guard target >= 0, target < limit else { return }
            animating = true
            show(target, animated: true, forward: forward) { [weak self] in
                self?.animating = false
            }
            Haptics.soft()
            PageSound.shared.play()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
