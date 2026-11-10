import SwiftUI
import UIKit
import WebKit

/// Geometrie und Schrift, von denen die Seitenzahl abhängt.
struct PageLayout: Equatable {
    var width: Int
    var height: Int
    /// 1 = Einzelseite (Außendisplay / iPhone), 2 = Doppelseite (Innendisplay / iPad quer)
    var columns: Int
    var fontSize: Int

    var hPad: Int { columns == 2 ? 30 : 24 }
    var vPad: Int { 20 }
    var size: CGSize { CGSize(width: width, height: height) }
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
        let w = layout.width
        let h = layout.height
        let pad = layout.hPad
        let vpad = layout.vPad
        let colW = w / layout.columns - 2 * pad
        let imgH = h - 2 * vpad - 8
        return """
        html { width: \(w)px !important; height: \(h)px !important; overflow: hidden !important; margin: 0 !important; padding: 0 !important; background: \(theme.backgroundHex) !important; -webkit-text-size-adjust: 100% !important; }
        body { box-sizing: border-box !important; margin: 0 !important; width: \(w)px !important; height: \(h)px !important; padding: \(vpad)px \(pad)px !important; -webkit-column-width: \(colW)px !important; column-width: \(colW)px !important; -webkit-column-gap: \(2 * pad)px !important; column-gap: \(2 * pad)px !important; column-fill: auto !important; background: \(theme.backgroundHex) !important; color: \(theme.textHex) !important; font-family: 'Iowan Old Style', Georgia, 'Times New Roman', serif !important; font-size: \(layout.fontSize)px !important; line-height: 1.55 !important; text-align: justify !important; -webkit-hyphens: auto !important; hyphens: auto !important; -webkit-user-select: none !important; user-select: none !important; -webkit-touch-callout: none !important; -webkit-tap-highlight-color: transparent !important; }
        body * { color: inherit !important; background-color: transparent !important; font-family: inherit !important; max-width: 100% !important; box-sizing: border-box !important; }
        h1, h2, h3, h4, h5, h6 { text-align: left !important; break-after: avoid !important; -webkit-column-break-after: avoid !important; line-height: 1.25 !important; }
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
        ["css": css(layout: layout, theme: theme), "W": layout.width, "page": page]
    }
}

// MARK: - Einzelne Seite

final class PageVC: UIViewController, WKNavigationDelegate {
    let chapter: Int
    let page: Int
    private let fileURL: URL
    private let root: URL
    private let layout: PageLayout
    private let theme: ReadingTheme
    private let webView: WKWebView

    init(chapter: Int, page: Int, fileURL: URL, root: URL, layout: PageLayout, theme: ReadingTheme) {
        self.chapter = chapter
        self.page = page
        self.fileURL = fileURL
        self.root = root
        self.layout = layout
        self.theme = theme

        let controller = WKUserContentController()
        controller.addUserScript(ReaderJS.viewportScript(width: layout.width))
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        webView = WKWebView(frame: CGRect(origin: .zero, size: layout.size), configuration: config)

        super.init(nibName: nil, bundle: nil)

        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = theme.background
        webView.underPageBackgroundColor = theme.background
        webView.scrollView.backgroundColor = theme.background
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.alpha = 0
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) wird nicht verwendet")
    }

    override func loadView() {
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.loadFileURL(fileURL, allowingReadAccessTo: root)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let layout = self.layout
        let theme = self.theme
        let page = self.page
        Task { @MainActor in
            _ = try? await webView.callAsyncJavaScript(
                ReaderJS.body,
                arguments: ReaderJS.arguments(layout: layout, theme: theme, page: page),
                in: nil,
                contentWorld: .page
            )
            webView.alpha = 1
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
        controller.addUserScript(ReaderJS.viewportScript(width: layout.width))
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
