import Combine
import SwiftUI
import UIKit
import WebKit

/// An independently owned web view per tab keeps navigation history when switching tabs.
@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()
    let webView: WKWebView
    let videoDetector: VideoDetector
    let isPrivate: Bool
    @Published var desktopMode: Bool
    @Published var title = "新标签页"
    @Published var address = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var errorMessage: String?
    var onVisit: ((URL, String) -> Void)?
    private let downloadManager: DownloadManager
    private var observations: [NSKeyValueObservation] = []

    init(configuration: WKWebViewConfiguration, downloadManager: DownloadManager, isPrivate: Bool = false, desktopMode: Bool = false) {
        self.downloadManager = downloadManager
        self.isPrivate = isPrivate
        self.desktopMode = desktopMode
        let detector = VideoDetector()
        self.videoDetector = detector
        configuration.defaultWebpagePreferences.preferredContentMode = desktopMode ? .desktop : .mobile
        detector.install(configuration: configuration)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observations = [
            webView.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.title = view.title?.isEmpty == false ? (view.title ?? "") : "新标签页" }
            },
            webView.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.address = view.url?.absoluteString ?? "" }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.canGoForward = view.canGoForward }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.isLoading = view.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.progress = view.estimatedProgress }
            }
        ]
    }

    func load(_ url: URL) {
        errorMessage = nil
        webView.load(URLRequest(url: url))
    }

    func toggleDesktopMode() {
        desktopMode.toggle()
        webView.reload()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        errorMessage = nil
        videoDetector.reset()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        onVisit?(url, webView.title ?? url.host ?? url.absoluteString)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        show(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        show(error)
    }

    private func show(_ error: Error) {
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
        errorMessage = error.localizedDescription
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.preferredContentMode = desktopMode ? .desktop : .mobile
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let http = navigationResponse.response as? HTTPURLResponse
        let attachment = http?.value(forHTTPHeaderField: "Content-Disposition")?
            .lowercased().trimmingCharacters(in: .whitespaces).hasPrefix("attachment") ?? false
        decisionHandler(!navigationResponse.canShowMIMEType || (navigationResponse.isForMainFrame && attachment) ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        downloadManager.attach(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        downloadManager.attach(download)
    }

    private func presenter() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              var controller = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return nil }
        while let presented = controller.presentedViewController { controller = presented }
        return controller
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let presenter = presenter() else { completionHandler(); return }
        let alert = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler() })
        presenter.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let presenter = presenter() else { completionHandler(false); return }
        let alert = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        presenter.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        guard let presenter = presenter() else { completionHandler(nil); return }
        let alert = UIAlertController(title: frame.request.url?.host, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text)
        })
        presenter.present(alert, animated: true)
    }

    // Open target=_blank links in the existing tab, rather than silently dropping them.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

struct BrowserEntry: Codable, Identifiable, Equatable {
    var id: String { url }
    let url: String
    var title: String
    var visited: Date
}

@MainActor
final class BrowserStore: ObservableObject {
    @Published private(set) var tabs: [BrowserTab] = []
    @Published var selectedID: UUID?
    @Published private(set) var bookmarks: [BrowserEntry] = []
    @Published private(set) var history: [BrowserEntry] = []
    @Published private(set) var isRebuilding = false
    private var configurationGeneration = UUID()
    let downloadManager = DownloadManager()
    private let defaults: UserDefaults
    private let bookmarkKey = "browser.bookmarks.v1"
    private let historyKey = "browser.history.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bookmarks = Self.read(bookmarkKey, defaults: defaults)
        history = Self.read(historyKey, defaults: defaults)
        addTab()
    }

    var selectedTab: BrowserTab? { tabs.first { $0.id == selectedID } }

    func addTab(url: URL? = nil, select: Bool = true, isPrivate: Bool = false, desktopMode: Bool = false, completion: (() -> Void)? = nil) {
        let generation = configurationGeneration
        let configuration = WKWebViewConfiguration()
        if isPrivate { configuration.websiteDataStore = .nonPersistent() }
        WebFeatures.configure(configuration) { [weak self] in
            guard let self, self.configurationGeneration == generation else { return }
            let tab = BrowserTab(configuration: configuration, downloadManager: self.downloadManager, isPrivate: isPrivate, desktopMode: desktopMode)
            if !isPrivate { tab.onVisit = { [weak self] url, title in self?.recordVisit(url, title: title) } }
            self.tabs.append(tab)
            if select || self.selectedID == nil { self.selectedID = tab.id }
            if let url { tab.load(url) }
            completion?()
        }
    }

    /// Re-create all web views after settings change, so old tabs cannot keep
    /// loading with a previously selected proxy configuration. Page navigation
    /// stacks are intentionally not restored.
    func applyFeatureChanges() {
        let pages = tabs.map { (url: $0.webView.url, isPrivate: $0.isPrivate, desktop: $0.desktopMode) }
        let selectedIndex = tabs.firstIndex { $0.id == selectedID } ?? 0
        configurationGeneration = UUID()
        let generation = configurationGeneration
        isRebuilding = true
        downloadManager.cancelAllForConfigurationChange()
        for tab in tabs {
            tab.webView.stopLoading()
            tab.webView.navigationDelegate = nil
            tab.webView.uiDelegate = nil
        }
        tabs.removeAll()
        selectedID = nil
        let restored = pages.isEmpty ? [(url: Optional<URL>.none, isPrivate: false, desktop: false)] : pages
        func restore(_ index: Int) {
            guard self.configurationGeneration == generation else { return }
            guard index < restored.count else { self.isRebuilding = false; return }
            let page = restored[index]
            self.addTab(url: page.url, select: index == selectedIndex, isPrivate: page.isPrivate, desktopMode: page.desktop) { restore(index + 1) }
        }
        restore(0)
    }

    func closeTab(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.webView.stopLoading()
        tab.webView.navigationDelegate = nil
        tab.webView.uiDelegate = nil
        tabs.remove(at: index)
        if tabs.isEmpty { addTab(); return }
        if selectedID == tab.id { selectedID = tabs[min(index, tabs.count - 1)].id }
    }

    func navigate(_ input: String) {
        guard let url = Self.url(for: input) else { return }
        selectedTab?.load(url)
    }

    static func url(for input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
           ["http", "https"].contains(scheme), components.host != nil {
            return components.url
        }
        if !text.contains(" "), !text.contains("\n"),
           let components = URLComponents(string: "https://" + text),
           let host = components.host, (host.contains(".") || host == "localhost"),
           components.user == nil, components.password == nil {
            return components.url
        }
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: text)]
        return components?.url
    }

    func isBookmarked(_ url: URL?) -> Bool {
        guard let url else { return false }
        return bookmarks.contains { $0.url == url.absoluteString }
    }

    func toggleBookmark(for tab: BrowserTab) {
        guard let url = tab.webView.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        if isBookmarked(url) {
            bookmarks.removeAll { $0.url == url.absoluteString }
        } else {
            bookmarks.insert(BrowserEntry(url: url.absoluteString, title: tab.webView.title ?? url.host ?? url.absoluteString, visited: Date()), at: 0)
        }
        save(bookmarks, key: bookmarkKey)
    }

    func deleteBookmark(_ entry: BrowserEntry) {
        bookmarks.removeAll { $0.url == entry.url }
        save(bookmarks, key: bookmarkKey)
    }

    func deleteHistory(_ entry: BrowserEntry) {
        history.removeAll { $0.url == entry.url }
        save(history, key: historyKey)
    }

    func clearHistory() {
        history.removeAll()
        save(history, key: historyKey)
    }

    private func recordVisit(_ url: URL, title: String) {
        history.removeAll { $0.url == url.absoluteString }
        history.insert(BrowserEntry(url: url.absoluteString, title: title, visited: Date()), at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
        save(history, key: historyKey)
    }

    private static func read(_ key: String, defaults: UserDefaults) -> [BrowserEntry] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([BrowserEntry].self, from: data)) ?? []
    }

    private func save(_ entries: [BrowserEntry], key: String) {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) }
    }
}

struct BrowserWebView: UIViewRepresentable {
    let tab: BrowserTab
    func makeUIView(context: Context) -> WKWebView { tab.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowserRootView: View {
    @StateObject private var store = BrowserStore()
    @State private var showTabs = false
    @State private var showLibrary = false
    @State private var showDownloads = false
    @State private var showSettings = false
    @State private var showVideo = false

    var body: some View {
        Group {
            if let tab = store.selectedTab {
                BrowserTabScreen(tab: tab, store: store,
                                 showTabs: $showTabs, showLibrary: $showLibrary,
                                 showDownloads: $showDownloads, showSettings: $showSettings, showVideo: $showVideo)
                    .id(tab.id)
            } else {
                ProgressView()
            }
        }
        .sheet(isPresented: $showTabs) { BrowserTabsSheet(store: store) }
        .sheet(isPresented: $showLibrary) { BrowserLibrarySheet(store: store) }
        .sheet(isPresented: $showDownloads) { DownloadsView(manager: store.downloadManager) }
        .sheet(isPresented: $showSettings) { WebFeaturesView() }
        .sheet(isPresented: $showVideo) {
            if let tab = store.selectedTab {
                VideoResourcesView(detector: tab.videoDetector, webView: tab.webView, downloadManager: store.downloadManager)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .webFeaturesDidChange)) { _ in
            store.applyFeatureChanges()
        }
        .overlay {
            if store.isRebuilding {
                ZStack {
                    Color(uiColor: .systemBackground).ignoresSafeArea()
                    ProgressView("正在更新浏览设置…")
                }
            }
        }
    }
}

private struct BrowserTabScreen: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var store: BrowserStore
    @Binding var showTabs: Bool
    @Binding var showLibrary: Bool
    @Binding var showDownloads: Bool
    @Binding var showSettings: Bool
    @Binding var showVideo: Bool
    @State private var input = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: tab.webView.url?.scheme == "https" ? "lock.fill" : "magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("搜索或输入网址", text: $input)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.go).focused($addressFocused)
                    .onSubmit { store.navigate(input); addressFocused = false }
                    .accessibilityLabel("搜索或输入网址")
                if !input.isEmpty && addressFocused {
                    Button { input = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .accessibilityLabel("清除地址")
                }
                Button {
                    if tab.isLoading { tab.webView.stopLoading() } else { tab.webView.reload() }
                } label: { Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise") }
                .accessibilityLabel(tab.isLoading ? "停止加载" : "刷新")
            }
            .padding(10).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12).padding(.vertical, 8)
            if tab.isLoading { ProgressView(value: tab.progress).progressViewStyle(.linear) }
            ZStack {
                BrowserWebView(tab: tab)
                if tab.address.isEmpty && !tab.isLoading {
                    VStack(spacing: 12) {
                        Image(systemName: "globe").font(.system(size: 46)).foregroundStyle(.secondary)
                        Text("搜索或输入网址开始浏览").foregroundStyle(.secondary)
                    }.allowsHitTesting(false)
                }
                if let message = tab.errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                        Text("无法加载网页").font(.headline)
                        Text(message).font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("重试") { tab.errorMessage = nil; tab.webView.reload() }.buttonStyle(.bordered)
                    }.padding(24).frame(maxWidth: 340).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Button { tab.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!tab.canGoBack).accessibilityLabel("后退")
                Spacer()
                Button { tab.webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!tab.canGoForward).accessibilityLabel("前进")
                Spacer()
                Button { store.toggleBookmark(for: tab) } label: {
                    Image(systemName: store.isBookmarked(tab.webView.url) ? "star.fill" : "star")
                }.disabled(tab.webView.url == nil).accessibilityLabel(store.isBookmarked(tab.webView.url) ? "移除书签" : "添加书签")
                Spacer()
                Menu {
                    Button { showLibrary = true } label: { Label("书签与历史", systemImage: "book") }
                    Button { showDownloads = true } label: { Label("下载", systemImage: "arrow.down.circle") }
                    Button { showVideo = true } label: { Label("媒体资源", systemImage: "play.rectangle") }
                    Button { tab.toggleDesktopMode() } label: { Label(tab.desktopMode ? "请求移动版网站" : "请求桌面版网站", systemImage: "desktopcomputer") }
                    Button { showSettings = true } label: { Label("设置", systemImage: "gearshape") }
                    if let url = tab.webView.url { ShareLink(item: url) { Label("分享网页", systemImage: "square.and.arrow.up") } }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("更多")
                Spacer()
                Button { showTabs = true } label: {
                    Text("\(store.tabs.count)").font(.caption.bold()).frame(width: 23, height: 23)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(lineWidth: 1.5))
                }.accessibilityLabel("标签页，\(store.tabs.count) 个")
            }.font(.system(size: 18)).padding(.horizontal, 25).padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemBackground))
        .onAppear { input = tab.address }
        .onChange(of: tab.address) { value in if !addressFocused { input = value } }
        .onChange(of: addressFocused) { focused in if !focused { input = tab.address } }
    }
}

private struct BrowserTabsSheet: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(store.tabs) { tab in
                    HStack {
                        Button { store.selectedID = tab.id; dismiss() } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(tab.isPrivate ? "无痕：\(tab.title)" : tab.title).lineLimit(1)
                                Text(tab.address.isEmpty ? "新标签页" : tab.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        if store.selectedID == tab.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        Button { store.closeTab(tab) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("关闭标签页")
                    }
                }
            }
            .navigationTitle("标签页")
            .safeAreaInset(edge: .bottom) {
                Text("无痕标签不保存浏览历史和网站数据；下载文件及手动保存的书签仍会保留。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(8).frame(maxWidth: .infinity).background(.regularMaterial)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("新建标签页") { store.addTab(); dismiss() }
                        Button("新建无痕标签页") { store.addTab(isPrivate: true); dismiss() }
                    } label: { Image(systemName: "plus") }.accessibilityLabel("新建标签页")
                }
            }
        }
    }
}

private struct BrowserLibrarySheet: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection = 0
    var body: some View {
        NavigationStack {
            VStack {
                Picker("浏览数据", selection: $selection) {
                    Text("书签").tag(0)
                    Text("历史").tag(1)
                }.pickerStyle(.segmented).padding(.horizontal)
                let entries = selection == 0 ? store.bookmarks : store.history
                if entries.isEmpty {
                    Spacer()
                    Text(selection == 0 ? "暂无书签" : "暂无历史记录").foregroundStyle(.secondary)
                    Spacer()
                } else {
                    List(entries) { entry in
                        Button {
                            if let url = URL(string: entry.url) { store.selectedTab?.load(url) }
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.title).lineLimit(1)
                                Text(entry.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.swipeActions {
                            Button("删除", role: .destructive) {
                                if selection == 0 { store.deleteBookmark(entry) } else { store.deleteHistory(entry) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("书签与历史")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                if selection == 1 && !store.history.isEmpty {
                    ToolbarItem(placement: .primaryAction) { Button("清空") { store.clearHistory() } }
                }
            }
        }
    }
}
