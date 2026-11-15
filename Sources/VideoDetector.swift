import Foundation
import SwiftUI
import WebKit

/// Records URLs exposed by the current page. This does not fetch them or
/// inspect protected media, and cannot recover blob/MediaSource streams.
@MainActor
final class VideoDetector: NSObject, ObservableObject, WKScriptMessageHandler {
    struct Resource: Identifiable {
        var id: String { url.absoluteString }
        let url: URL
        let isPlaylist: Bool
    }

    @Published private(set) var resources: [Resource] = []
    private var seen = Set<String>()
    private static let handler = "browserMediaResource"

    /// Call before constructing the WKWebView. The controller retains this
    /// handler for the lifetime of its web view.
    func install(configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        controller.add(self, name: Self.handler)
        controller.addUserScript(WKUserScript(source: Self.source,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
    }

    func reset() {
        resources.removeAll()
        seen.removeAll()
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == Self.handler, resources.count < 200,
              let value = message.body as? String, value.utf8.count <= 8192,
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host != nil, components.user == nil, components.password == nil,
              let url = components.url else { return }
        let key = url.absoluteString
        guard seen.insert(key).inserted else { return }
        let ext = url.pathExtension.lowercased()
        resources.append(Resource(url: url, isPlaylist: ext == "m3u8" || ext == "mpd"))
    }

    /// Observe DOM media and Performance resource entries exposed to the page.
    /// Only URLs are passed to native code; no network requests are made here.
    private static let source = #"""
    (() => {
      if (window.__browserMediaDetectorInstalled) return;
      window.__browserMediaDetectorInstalled = true;
      const sent = new Set();
      const report = (raw, fromElement = false) => {
        if (!raw || sent.size >= 200) return;
        try {
          const url = new URL(raw, document.baseURI);
          if (url.protocol !== 'http:' && url.protocol !== 'https:') return;
          if (!fromElement && !/\.(m3u8|mpd|mp4|m4v|mov|webm|mp3|m4a|aac|ogg|oga|wav)$/i.test(url.pathname)) return;
          const str = url.href;
          if (str.length > 8192 || sent.has(str)) return;
          sent.add(str);
          window.webkit.messageHandlers.browserMediaResource.postMessage(str);
        } catch (_) {}
      };
      const scan = () => {
        document.querySelectorAll('video,audio').forEach(el => {
          report(el.currentSrc || el.src, true);
          el.querySelectorAll('source[src]').forEach(s => report(s.src, true));
        });
        if (window.performance && performance.getEntriesByType) {
          performance.getEntriesByType('resource').forEach(entry => report(entry.name));
        }
      };
      let pending = false;
      const schedule = () => {
        if (pending) return;
        pending = true;
        setTimeout(() => { pending = false; scan(); }, 500);
      };
      document.addEventListener('DOMContentLoaded', schedule, {once: true});
      document.addEventListener('play', schedule, true);
      try {
        new MutationObserver(schedule).observe(document, {
          subtree: true, childList: true, attributes: true, attributeFilter: ['src']
        });
        new PerformanceObserver(list => list.getEntries().forEach(entry => report(entry.name)))
          .observe({entryTypes: ['resource']});
      } catch (_) {}
      schedule();
    })();
    """#
}

struct VideoResourcesView: View {
    @ObservedObject var detector: VideoDetector
    let webView: WKWebView
    let downloadManager: DownloadManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if detector.resources.isEmpty {
                    ContentUnavailableView("未检测到媒体", systemImage: "play.rectangle",
                        description: Text("尝试播放网页中的视频或音频后再查看。"))
                } else {
                    List(detector.resources) { resource in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(resource.url.lastPathComponent.isEmpty ? "媒体资源" : resource.url.lastPathComponent)
                                .lineLimit(2)
                            Text(resource.url.host ?? "")
                                .font(.caption).foregroundStyle(.secondary)
                            if resource.isPlaylist {
                                Text("这是播放列表，下载文件不等于下载完整视频。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button {
                                    webView.startDownload(using: URLRequest(url: resource.url)) { download in
                                        downloadManager.attach(download)
                                    }
                                    dismiss()
                                } label: { Label("下载文件", systemImage: "arrow.down.circle") }
                                ShareLink(item: resource.url) { Label("分享链接", systemImage: "square.and.arrow.up") }
                            }
                            .buttonStyle(.borderless)
                            .font(.subheadline)
                        }
                    }
                }
            }
            .navigationTitle("媒体资源")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                Text("仅显示网页可访问的资源；加密、受保护或动态流媒体可能无法下载。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(8).frame(maxWidth: .infinity).background(.regularMaterial)
            }
        }
    }
}
