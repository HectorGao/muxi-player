import SwiftUI
import WebKit
import Observation
import MuxiCore

@MainActor @Observable final class WebsiteBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let store: ViewingSiteStore
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var pageFinished = false
    var currentURL: URL?
    var title = ""
    var loading = false
    var canGoBack = false
    var canGoForward = false
    var error: String?

    init(store: ViewingSiteStore) {
        self.store = store
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.updateMetadata() }
            },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.updateMetadata() }
            }
        ]
    }

    func load(_ url: URL) {
        guard (try? ViewingSite.checkedURL(url.absoluteString)) != nil else { error = "网页地址无效。"; return }
        error = nil; currentURL = url
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
        guard (try? ViewingSite.checkedURL(url.absoluteString)) != nil else { decisionHandler(.cancel); return }
        if action.targetFrame == nil {
            load(url)
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true; error = nil; pageFinished = false
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageFinished = true; update()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loading = false; error = "网页进程已结束，请重新加载。"
    }
    private func failed(_ error: Error) {
        guard (error as? URLError)?.code != .cancelled else { return }
        update(); self.error = "网页暂时无法打开，请重试或切换站点。"
    }
    private func update() {
        loading = false; updateMetadata()
    }
    private func updateMetadata() {
        currentURL = webView.url; title = webView.title ?? ""
        canGoBack = webView.canGoBack; canGoForward = webView.canGoForward
        if pageFinished, let url = webView.url { store.recordVisit(url: url, title: title) }
    }
}

private struct WebsiteWebView: NSViewRepresentable {
    let browser: WebsiteBrowser
    func makeNSView(context: Context) -> WKWebView { browser.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    static func dismantleNSView(_ nsView: WKWebView, coordinator: ()) {
        nsView.stopLoading()
        nsView.loadHTMLString("", baseURL: nil)
        nsView.navigationDelegate = nil; nsView.uiDelegate = nil
    }
}

struct WebsiteView: View {
    let url: URL
    let store: ViewingSiteStore
    let close: () -> Void
    @ViewState private var browser: WebsiteBrowser

    init(url: URL, store: ViewingSiteStore, close: @escaping () -> Void) {
        self.url = url; self.store = store; self.close = close
        _browser = ViewState(wrappedValue: WebsiteBrowser(store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!browser.canGoBack).help("后退")
                Button { browser.webView.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!browser.canGoForward).help("前进")
                Button { browser.webView.reload() } label: { Image(systemName: "arrow.clockwise") }.help("重新加载网页")
                if browser.loading { ProgressView().controlSize(.small) }
                Text(browser.currentURL?.host ?? url.host ?? "观影网站").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Link(destination: browser.currentURL ?? url) { Label("浏览器打开", systemImage: "arrow.up.right.square") }
                Button("返回站点", action: close)
            }.buttonStyle(.borderless).padding(14).background(.regularMaterial)
            if let error = browser.error {
                HStack { Label(error, systemImage: "exclamationmark.triangle"); Spacer(); Button("重试") { browser.load(url) } }
                    .font(.callout).padding(14)
            }
            WebsiteWebView(browser: browser)
        }.onAppear { browser.load(url) }.onChange(of: url) { _, value in browser.load(value) }
    }
}
