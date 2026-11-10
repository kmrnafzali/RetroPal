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
        context.coordinator.attach()
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
        let scale = pager.traitCollection.displayScale
        if scale > 0, abs(scale - model.displayScale) > 0.01 {
            let model = self.model
            DispatchQueue.main.async { model.setScale(scale) }
        }
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
        private var token = 0
        private var current = 0
        private let frames = FrameMonitor()

        init(model: ReaderModel, spread: Bool) {
            self.model = model
            self.spread = spread
        }

        private var step: Int { spread ? 2 : 1 }

        /// Fertige Seitenbilder landen sofort in den wartenden Seiten.
        func attach() {
            model.pages.onReady = { [weak self] index in
                guard let self, self.builtVersion == self.model.version, !self.model.isPaginating else { return }
                self.cache[index]?.refresh(allowSync: false, counted: false)
                if abs(index - self.current) <= self.step + 1 {
                    self.controller(index)?.loadViewIfNeeded()
                }
            }
        }

        // MARK: Zustand abgleichen

        func showPlaceholders() {
            guard let pager else { return }
            func blank(_ index: Int, _ side: PageSide) -> PageVC {
                PageVC(index: index, spec: nil, model: model, theme: model.theme, side: side)
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
                    present(model.startIndex, animated: false, forward: true)
                }
            }
            if let jump = model.pendingJump, jump.id != lastJump {
                lastJump = jump.id
                if !model.counts.isEmpty {
                    present(jump.index, animated: false, forward: true)
                }
            }
            if decorVersion != model.decorVersion {
                decorVersion = model.decorVersion
                guard !model.counts.isEmpty, !model.isPaginating else { return }
                for controller in cache.values {
                    // Sichtbare Seiten sofort neu zeichnen, alle anderen im Hintergrund.
                    controller.refresh(allowSync: controller.viewIfLoaded?.window != nil, counted: false)
                }
                model.requestPages(Array(model.window(around: current)))
            }
        }

        /// Zeigt eine Seite (oder Doppelseite). Liegen die Bilder noch nicht bereit, werden sie
        /// erst im Hintergrund gezeichnet – der Hauptthread bleibt dabei frei.
        private func present(_ index: Int, animated: Bool, forward: Bool, completion: (() -> Void)? = nil) {
            let first = spread ? index - index % 2 : index
            let indices = spread ? [first, first + 1] : [first]
            token += 1
            let expected = token
            if model.pagesReady(indices) {
                commit(indices, animated: animated, forward: forward, completion: completion)
                return
            }
            model.preparePages(indices) { [weak self] in
                guard let self, self.token == expected, self.model.pagesReady(indices) else {
                    completion?()
                    return
                }
                self.commit(indices, animated: animated, forward: forward, completion: completion)
            }
        }

        private func commit(_ indices: [Int], animated: Bool, forward: Bool, completion: (() -> Void)?) {
            guard let pager else {
                completion?()
                return
            }
            let controllers = indices.compactMap { controller($0) }
            guard controllers.count == indices.count, let first = controllers.first else {
                completion?()
                return
            }
            current = first.index
            if animated {
                frames.begin()
                pager.setViewControllers(controllers, direction: forward ? .forward : .reverse, animated: true) { [weak self] _ in
                    self?.frames.end()
                    completion?()
                    // Erst nach der Animation melden, damit währenddessen nichts anderes rechnet.
                    self?.report(first.index)
                }
            } else {
                pager.setViewControllers(controllers, direction: forward ? .forward : .reverse, animated: false, completion: nil)
                completion?()
                report(first.index)
            }
        }

        // MARK: Seiten

        private func controller(_ index: Int) -> PageVC? {
            if let existing = cache[index] { return existing }
            guard let spec = model.spec(index) else { return nil }
            let created = PageVC(index: index, spec: spec, model: model, theme: model.theme, side: spec.side)
            cache[index] = created
            return created
        }

        private func report(_ index: Int) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.current = index
                self.model.setCurrent(index: index)
                self.prefetch(around: index)
            }
        }

        /// Zeichnet die Nachbarseiten im Hintergrund vor und räumt weiter entfernte ab.
        private func prefetch(around index: Int) {
            let range = model.window(around: index)
            model.requestPages(Array(range))
            model.pages.trim(keeping: (range.lowerBound - step)...(range.upperBound + step))
            for stale in cache.keys where !range.contains(stale) {
                cache.removeValue(forKey: stale)
            }
            let base = spread ? index - index % 2 : index
            for neighbour in (base - step)...(base + 2 * step - 1) where model.pagesReady([neighbour]) {
                controller(neighbour)?.loadViewIfNeeded()
            }
        }

        // MARK: Datenquelle

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? PageVC, page.index >= 0 else { return nil }
            return controller(page.index + 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? PageVC, page.index >= 0 else { return nil }
            return controller(page.index - 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                willTransitionTo pendingViewControllers: [UIViewController]) {
            frames.begin()
        }

        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            frames.end()
            guard completed, let page = pageViewController.viewControllers?.first as? PageVC else { return }
            Haptics.soft()
            PageSound.shared.play()
            report(page.index)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                spineLocationFor orientation: UIInterfaceOrientation) -> UIPageViewController.SpineLocation {
            pageViewController.isDoubleSided = spread
            let needed = spread ? 2 : 1
            if (pageViewController.viewControllers?.count ?? 0) != needed {
                if model.counts.isEmpty {
                    showPlaceholders()
                } else {
                    present(model.index, animated: false, forward: true)
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
                  let page = pager.viewControllers?.first as? PageVC, page.index >= 0 else { return }
            let target = page.index + (forward ? step : -step)
            guard target >= 0, target < model.pageLimit else { return }
            animating = true
            Haptics.soft()
            PageSound.shared.play()
            present(target, animated: true, forward: forward) { [weak self] in
                self?.animating = false
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
