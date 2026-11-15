import Foundation
import SwiftUI
import WebKit

/// Keeps WebKit downloads in the app's Documents directory. Using WKDownload
/// preserves the web view's session and proxy settings; this class does not
/// start a second, unproxied URLSession.
@MainActor
final class DownloadManager: NSObject, ObservableObject, WKDownloadDelegate {
    enum State: Equatable {
        case downloading
        case finished
        case failed(String)
    }

    struct Item: Identifiable {
        let id: UUID
        var name: String
        var state: State
        var fileURL: URL?
    }

    @Published private(set) var items: [Item] = []
    private struct ActiveDownload {
        let id: UUID
        let download: WKDownload
        var temporaryURL: URL?
    }
    private var active: [ObjectIdentifier: ActiveDownload] = [:]
    private let directory: URL
    private let temporaryDirectory: URL

    override init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("Downloads", isDirectory: true)
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserDownloads", isDirectory: true)
        super.init()
        loadFinishedDownloads()
    }

    /// Retain this manager for the lifetime of the download. Call from either
    /// WKNavigationDelegate `didBecome` callback.
    func attach(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        guard active[key] == nil else { return }
        let id = UUID()
        active[key] = ActiveDownload(id: id, download: download, temporaryURL: nil)
        items.insert(Item(id: id, name: "正在准备下载", state: .downloading, fileURL: nil), at: 0)
        download.delegate = self
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let key = ObjectIdentifier(download)
        guard let id = active[key]?.id, let index = items.firstIndex(where: { $0.id == id }) else {
            completionHandler(nil)
            return
        }
        let proposed = (suggestedFilename as NSString).lastPathComponent
        let filename = proposed.isEmpty || proposed == "." || proposed == ".." ? "download" : proposed
        let folder = temporaryDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(filename, isDirectory: false)
            items[index].name = filename
            active[key]?.temporaryURL = url
            completionHandler(url)
        } catch {
            items[index].state = .failed("无法创建下载文件：\(error.localizedDescription)")
            active.removeValue(forKey: key)
            completionHandler(nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let entry = active.removeValue(forKey: ObjectIdentifier(download)),
              let index = items.firstIndex(where: { $0.id == entry.id }),
              let temporaryURL = entry.temporaryURL else { return }
        let destinationFolder = directory.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        let destination = destinationFolder.appendingPathComponent(temporaryURL.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            items[index].fileURL = destination
            items[index].state = .finished
        } catch {
            items[index].state = .failed("无法保存文件：\(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: temporaryURL.deletingLastPathComponent())
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let entry = active.removeValue(forKey: ObjectIdentifier(download)),
              let index = items.firstIndex(where: { $0.id == entry.id }) else { return }
        if let temporaryURL = entry.temporaryURL {
            try? FileManager.default.removeItem(at: temporaryURL.deletingLastPathComponent())
        }
        items[index].fileURL = nil
        items[index].state = .failed(error.localizedDescription)
    }

    /// Request cancellation before replacing proxy settings or their web views.
    /// WebKit completes cancellation asynchronously; a request already in flight
    /// may not stop until its cancellation callback runs.
    func cancelAllForConfigurationChange() {
        let entries = Array(active.values)
        active.removeAll()
        for entry in entries {
            if let index = items.firstIndex(where: { $0.id == entry.id }) {
                items[index].state = .failed("设置已更改，正在取消下载")
                items[index].fileURL = nil
            }
            entry.download.cancel { [weak self] _ in
                if let temporaryURL = entry.temporaryURL {
                    try? FileManager.default.removeItem(at: temporaryURL.deletingLastPathComponent())
                }
                if let index = self?.items.firstIndex(where: { $0.id == entry.id }) {
                    self?.items[index].state = .failed("设置已更改，下载已取消")
                }
            }
        }
    }

    func delete(_ item: Item) {
        guard item.state != .downloading else { return }
        if let url = item.fileURL {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        items.removeAll { $0.id == item.id }
    }

    private func loadFinishedDownloads() {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return }
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent),
                  let files = try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
                  ), let file = files.first,
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            items.append(Item(id: id, name: file.lastPathComponent, state: .finished, fileURL: file))
        }
    }
}

struct DownloadsView: View {
    @ObservedObject var manager: DownloadManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if manager.items.isEmpty {
                    ContentUnavailableView("没有下载", systemImage: "arrow.down.circle")
                } else {
                    List(manager.items) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.name).lineLimit(2)
                                switch item.state {
                                case .downloading:
                                    Text("下载中").font(.caption).foregroundStyle(.secondary)
                                case .finished:
                                    Text("已完成").font(.caption).foregroundStyle(.secondary)
                                case .failed(let message):
                                    Text("下载失败：\(message)").font(.caption).foregroundStyle(.red)
                                }
                            }
                            Spacer()
                            if item.state == .finished, let url = item.fileURL {
                                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                                    .accessibilityLabel("分享或保存 \(item.name)")
                            }
                            if item.state != .downloading {
                                Button(role: .destructive) { manager.delete(item) } label: {
                                    Image(systemName: "trash")
                                }.accessibilityLabel("删除 \(item.name)")
                            }
                        }
                    }
                }
            }
            .navigationTitle("下载")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
