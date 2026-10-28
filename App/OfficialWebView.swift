import SwiftUI
import WebKit
import ExViewerCore

struct WebDestination: Identifiable {
    let id = UUID()
    var title: String
    var url: URL
    var login = false
    static var login: Self { .init(title: "站点登录", url: URL(string: "https://forums.e-hentai.org/index.php?act=Login&CODE=00")!, login: true) }
}
struct OfficialWebView: View {
    var destination: WebDestination
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var ready = false
    @State private var loading = false
    @State private var error: String?
    @State private var verifying = false
    @State private var operation: UUID?
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 5) { Image(systemName: "lock.fill"); Text(destination.url.host ?? "").textSelection(.enabled); Spacer(); if loading { ProgressView() } }.font(.caption).foregroundStyle(.secondary).padding(.horizontal).padding(.vertical, 10).background(FloatingChrome.background)
                if let error { Text(error).font(.caption).foregroundStyle(.red).padding() }
                if ready { SiteWebSurface(url: destination.url, store: session.webStore, loading: $loading, error: $error) }
                else { Spacer(); ProgressView(); Spacer() }
                if destination.login {
                    HStack(spacing: 12) {
                        Text("在站点页面完成登录，再验证会话。").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(verifying ? "验证中…" : "完成登录") {
                            verifying = true
                            Task {
                                do { guard let operation else { throw ViewerError.stale }; try await session.captureWebSession(operation: operation); library.load(owner: session.owner); await session.verify(); dismiss() }
                                catch { self.error = (error as? ViewerError)?.localizedDescription ?? "会话保存失败" }
                                verifying = false
                            }
                        }.buttonStyle(AppActionButtonStyle(tone: .accent)).disabled(verifying)
                    }.padding().background(FloatingChrome.background)
                }
            }.navigationTitle(destination.title).navigationBarTitleDisplayMode(.inline).appNavigationChrome()
                .toolbar { AppToolbarItem(placement: .cancellationAction) { Button("关闭") { if let operation { session.endWebOperation(operation) }; dismiss() } } }
                .task {
                    do { let operation = try session.beginWebOperation(); self.operation = operation; try await session.prepareWebSession(operation: operation); try Task.checkCancellation(); ready = true }
                    catch { self.error = (error as? ViewerError)?.localizedDescription ?? "网页会话准备未完成，请重新打开。" }
                }
                .onDisappear { if let operation { session.endWebOperation(operation) } }
        }
    }
}
struct SiteWebSurface: UIViewRepresentable {
    var url: URL
    var store: WKWebsiteDataStore
    @Binding var loading: Bool
    @Binding var error: String?
    func makeCoordinator() -> Coordinator { Coordinator(loading: $loading, error: $error) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = store
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        if AppMode.qa && AppMode.screen == "web-compat" {
            view.loadHTMLString(WebCompatibilityQA.html, baseURL: GallerySite.eh.baseURL)
        } else if URLPolicy.account(url) { view.load(URLRequest(url: url)) }
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        @Binding var loading: Bool
        @Binding var error: String?
        init(loading: Binding<Bool>, error: Binding<String?>) { _loading = loading; _error = error }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if SiteWebNavigation.allows(url, isMainFrame: navigationAction.targetFrame?.isMainFrame) { decisionHandler(.allow) }
            else { error = "此链接不属于已识别的站点页面，已停止跳转。"; decisionHandler(.cancel) }
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true; error = nil }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError: Error) { loading = false; error = "页面未能加载，请检查网络后重新打开。" }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError: Error) { loading = false; error = "页面加载未完成，请重试。" }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url, URLPolicy.account(url) { webView.load(URLRequest(url: url)) }
            return nil
        }
    }
}

enum WebCompatibilityQA {
    static let html = #"""
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
    <body><p>本机网页子页面检查</p><iframe title="Local bootstrap check" style="width:100%;height:160px;border:0" srcdoc="&lt;html&gt;&lt;body&gt;&lt;script&gt;document.body.textContent='子页面兼容检查通过';&lt;/script&gt;&lt;/body&gt;&lt;/html&gt;"></iframe></body></html>
    """#
}
struct WebCompatibilityQAView: View {
    @State private var loading = false
    @State private var error: String?
    private let store = WKWebsiteDataStore.nonPersistent()
    var body: some View {
        NavigationStack {
            VStack {
                if let error { Text(error).foregroundStyle(.red) }
                SiteWebSurface(url: GallerySite.eh.baseURL, store: store, loading: $loading, error: $error)
            }.navigationTitle("网页兼容检查")
        }
    }
}
