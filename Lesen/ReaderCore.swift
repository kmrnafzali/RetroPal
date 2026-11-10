import SwiftUI
import UIKit
import WebKit

/// Geometrie und Schrift einer Buchseite. Davon hängt die Seitenzahl ab.
struct PageLayout: Equatable {
    /// Breite einer einzelnen Buchseite (im Doppelseiten-Modus die halbe Bildschirmbreite).
    var pageWidth: Int
    var height: Int
    /// true = aufgeschlagenes Buch mit zwei Seiten (Innendisplay), false = Einzelseite (Außendisplay).
    var spread: Bool
    var fontSize: Int
    var font: ReadingFont
    var lineHeight: Double
    var margin: Int

    var topPad: Int { 24 }
    var bottomPad: Int { 46 }
    var size: CGSize { CGSize(width: pageWidth, height: height) }
}

enum PageSide {
    case single
    case left
    case right
}

struct PageInfo {
    var chapter: Int
    var page: Int
    var number: Int
    var title: String
}

enum ReaderJS {
    static func viewportScript(width: Int) -> WKUserScript {
        let source = """
        (function () {
          try {
            var NS = 'http://www.w3.org/1999/xhtml';
            var m = document.createElementNS(NS, 'meta');
            m.setAttribute('name', 'viewport');
            m.setAttribute('content', 'width=\(width), initial-scale=1, maximum-scale=1, user-scalable=no');
            (document.head || document.documentElement).appendChild(m);
          } catch (e) {}
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    static func css(layout: PageLayout, theme: ReadingTheme) -> String {
        let w = layout.pageWidth
        let h = layout.height
        let pad = layout.margin
        let colW = w - 2 * pad
        let imgH = h - layout.topPad - layout.bottomPad - 8
        let lineHeight = String(format: "%.2f", layout.lineHeight)
        return """
        html { width: \(w)px !important; height: \(h)px !important; overflow: hidden !important; margin: 0 !important; padding: 0 !important; background: \(theme.backgroundHex) !important; -webkit-text-size-adjust: 100% !important; }
        body { box-sizing: border-box !important; margin: 0 !important; width: \(w)px !important; height: \(h)px !important; padding: \(layout.topPad)px \(pad)px \(layout.bottomPad)px \(pad)px !important; -webkit-column-width: \(colW)px !important; column-width: \(colW)px !important; -webkit-column-gap: \(2 * pad)px !important; column-gap: \(2 * pad)px !important; column-fill: auto !important; background: \(theme.backgroundHex) !important; color: \(theme.textHex) !important; font-family: \(layout.font.css) !important; font-size: \(layout.fontSize)px !important; line-height: \(lineHeight) !important; text-align: justify !important; -webkit-hyphens: auto !important; hyphens: auto !important; -webkit-user-select: none !important; user-select: none !important; -webkit-touch-callout: none !important; -webkit-tap-highlight-color: transparent !important; text-rendering: optimizeLegibility !important; -webkit-font-smoothing: antialiased !important; font-variant-ligatures: common-ligatures !important; font-feature-settings: 'kern' 1, 'liga' 1, 'onum' 1 !important; orphans: 2 !important; widows: 2 !important; }
        body * { color: inherit !important; background-color: transparent !important; font-family: inherit !important; max-width: 100% !important; box-sizing: border-box !important; line-height: inherit !important; }
        h1, h2, h3, h4, h5, h6 { text-align: left !important; break-after: avoid !important; -webkit-column-break-after: avoid !important; line-height: 1.25 !important; letter-spacing: 0.01em !important; -webkit-hyphens: none !important; hyphens: none !important; }
        img { max-width: \(colW)px !important; max-height: \(imgH)px !important; width: auto !important; height: auto !important; object-fit: contain !important; break-inside: avoid !important; }
        svg { width: \(colW)px !important; height: \(imgH)px !important; max-height: \(imgH)px !important; break-inside: avoid !important; }
        a { text-decoration: none !important; }
        """
    }

    /// Wird nach dem Laden einer Datei ausgeführt. Gibt die Seitenzahl zurück.
    static let body = """
    var NS = 'http://www.w3.org/1999/xhtml';
    var st = document.createElementNS(NS, 'style');
    st.textContent = css;
    (document.head || document.documentElement).appendChild(st);
    if (!document.documentElement.getAttribute('lang')) {
      document.documentElement.setAttribute('lang', 'de');
    }
    try { await document.fonts.ready; } catch (e) {}
    var imgs = Array.prototype.slice.call(document.images || []);
    await Promise.all(imgs.map(function (i) {
      return i.complete ? Promise.resolve() : new Promise(function (r) { i.onload = r; i.onerror = r; });
    }));
    await new Promise(function (r) { setTimeout(r, 40); });
    var sw = document.documentElement.scrollWidth;
    if (document.body) { sw = Math.max(sw, document.body.scrollWidth); }
    var pages = Math.max(1, Math.ceil((sw - 3) / W));
    window.scrollTo(page * W, 0);
    document.documentElement.scrollLeft = page * W;
    return pages;
    """

    static func arguments(layout: PageLayout, theme: ReadingTheme, page: Int) -> [String: Any] {
        ["css": css(layout: layout, theme: theme), "W": layout.pageWidth, "page": page]
    }
}

// MARK: - Einzelne Buchseite

final class PageVC: UIViewController, WKNavigationDelegate {
    /// Fortlaufender Seitenindex über das ganze Buch.
    let index: Int
    let info: PageInfo?

    private let fileURL: URL?
    private let root: URL
    private let layout: PageLayout
    private let theme: ReadingTheme
    private let side: PageSide

    private var webView: WKWebView?
    private let titleLabel = UILabel()
    private let numberLabel = UILabel()
    private let spineShadow = CAGradientLayer()

    init(index: Int, info: PageInfo?, fileURL: URL?, root: URL, layout: PageLayout,
         theme: ReadingTheme, side: PageSide) {
        self.index = index
        self.info = info
        self.fileURL = fileURL
        self.root = root
        self.layout = layout
        self.theme = theme
        self.side = side
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) wird nicht verwendet")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = theme.background
        view.clipsToBounds = true

        if let info, let fileURL {
            let controller = WKUserContentController()
            controller.addUserScript(ReaderJS.viewportScript(width: layout.pageWidth))
            let config = WKWebViewConfiguration()
            config.userContentController = controller
            let web = WKWebView(frame: CGRect(origin: .zero, size: layout.size), configuration: config)
            web.navigationDelegate = self
            web.isOpaque = false
            web.backgroundColor = theme.background
            web.underPageBackgroundColor = theme.background
            web.scrollView.backgroundColor = theme.background
            web.scrollView.isScrollEnabled = false
            web.scrollView.bounces = false
            web.scrollView.contentInsetAdjustmentBehavior = .never
            web.isUserInteractionEnabled = false
            web.alpha = 0
            view.addSubview(web)
            webView = web
            web.loadFileURL(fileURL, allowingReadAccessTo: root)

            let footerFont = UIFont.systemFont(ofSize: 11, weight: .medium)
            titleLabel.font = footerFont
            titleLabel.textColor = theme.footerColor
            titleLabel.text = info.title.uppercased()
            titleLabel.lineBreakMode = .byTruncatingTail
            numberLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            numberLabel.textColor = theme.footerColor
            numberLabel.text = "\(info.number)"
            view.addSubview(titleLabel)
            view.addSubview(numberLabel)
        }

        // Schatten am Buchfalz, damit die Doppelseite wie ein aufgeschlagenes Buch wirkt.
        if side != .single {
            let strength: CGFloat = theme.isDark ? 0.5 : 0.14
            spineShadow.colors = [
                UIColor.black.withAlphaComponent(0).cgColor,
                UIColor.black.withAlphaComponent(strength * 0.35).cgColor,
                UIColor.black.withAlphaComponent(strength).cgColor
            ]
            spineShadow.locations = [0, 0.7, 1]
            if side == .left {
                spineShadow.startPoint = CGPoint(x: 0, y: 0.5)
                spineShadow.endPoint = CGPoint(x: 1, y: 0.5)
            } else {
                spineShadow.startPoint = CGPoint(x: 1, y: 0.5)
                spineShadow.endPoint = CGPoint(x: 0, y: 0.5)
            }
            view.layer.addSublayer(spineShadow)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        webView?.frame = CGRect(origin: .zero, size: layout.size)

        let margin = CGFloat(layout.margin)
        let footerY = bounds.height - 30
        let numberWidth: CGFloat = 50
        let titleWidth = max(0, bounds.width - 2 * margin - numberWidth - 8)
        if side == .left {
            // Linke Seite: Seitenzahl außen links, Kapitel innen.
            numberLabel.textAlignment = .left
            titleLabel.textAlignment = .right
            numberLabel.frame = CGRect(x: margin, y: footerY, width: numberWidth, height: 16)
            titleLabel.frame = CGRect(x: margin + numberWidth + 8, y: footerY, width: titleWidth, height: 16)
        } else {
            numberLabel.textAlignment = .right
            titleLabel.textAlignment = .left
            titleLabel.frame = CGRect(x: margin, y: footerY, width: titleWidth, height: 16)
            numberLabel.frame = CGRect(x: bounds.width - margin - numberWidth, y: footerY, width: numberWidth, height: 16)
        }

        let shadowWidth: CGFloat = 34
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if side == .left {
            spineShadow.frame = CGRect(x: bounds.width - shadowWidth, y: 0, width: shadowWidth, height: bounds.height)
        } else if side == .right {
            spineShadow.frame = CGRect(x: 0, y: 0, width: shadowWidth, height: bounds.height)
        }
        CATransaction.commit()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let layout = self.layout
        let theme = self.theme
        let page = info?.page ?? 0
        Task { @MainActor in
            _ = try? await webView.callAsyncJavaScript(
                ReaderJS.body,
                arguments: ReaderJS.arguments(layout: layout, theme: theme, page: page),
                in: nil,
                contentWorld: .page
            )
            UIView.animate(withDuration: 0.12) {
                webView.alpha = 1
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        webView.alpha = 1
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.navigationType == .linkActivated ? .cancel : .allow)
    }
}

// MARK: - Seitenzählung

/// Lädt jede Kapiteldatei unsichtbar und zählt die Seiten.
@MainActor
final class Paginator: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?

    func count(files: [URL], root: URL, layout: PageLayout, theme: ReadingTheme,
               progress: @escaping (Double) -> Void) async -> [Int] {
        let controller = WKUserContentController()
        controller.addUserScript(ReaderJS.viewportScript(width: layout.pageWidth))
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        let webView = WKWebView(frame: CGRect(origin: .zero, size: layout.size), configuration: config)
        webView.navigationDelegate = self
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        attach(webView)
        defer { webView.removeFromSuperview() }

        var result: [Int] = []
        for (index, url) in files.enumerated() {
            if Task.isCancelled { return [] }
            await load(url, root: root, in: webView)
            var pages = 1
            let value = try? await webView.callAsyncJavaScript(
                ReaderJS.body,
                arguments: ReaderJS.arguments(layout: layout, theme: theme, page: 0),
                in: nil,
                contentWorld: .page
            )
            if let number = value as? NSNumber {
                pages = max(1, number.intValue)
            }
            result.append(pages)
            progress(Double(index + 1) / Double(max(1, files.count)))
        }
        return result
    }

    private func attach(_ webView: WKWebView) {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        window?.insertSubview(webView, at: 0)
    }

    private func load(_ url: URL, root: URL, in webView: WKWebView) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
            webView.loadFileURL(url, allowingReadAccessTo: root)
        }
    }

    private func finishLoading() {
        let cont = continuation
        continuation = nil
        cont?.resume()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoading()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishLoading()
    }
}
