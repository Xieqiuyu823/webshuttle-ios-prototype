import Foundation
import Network
import SwiftUI

// Node probing and explicit activation. A successful probe does not prove that
// webpage forwarding, DNS, WebRTC, or privacy are working.
@MainActor
final class OriginalNodeDiagnostics: ObservableObject {
    struct Node: Identifiable, Decodable {
        let id: String
        let host: String
        let port: UInt16
        let country: String?
    }
    struct Resource: Decodable {
        let resource_key: String
        let resource_value: String
    }
    struct Service: Decodable { let service_url: String }
    @Published var nodes: [Node] = []
    @Published var message = "尚未获取节点。"
    @Published var results: [String: String] = [:]
    @Published private(set) var readyNodes: Set<String> = []
    @Published private(set) var probingNodes: Set<String> = []
    @Published private(set) var activatingNodeID: String?
    private var nodeKeys: [String: UInt8] = [:]
    private var connections: [String: NWConnection] = [:]
    private let fingerprint = "cb37a03c2a2d7439cadfffae2de254e9"

    func fetchNodes() {
        message = "正在获取官方节点列表…"
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        probingNodes.removeAll()
        readyNodes.removeAll()
        nodeKeys.removeAll()
        results.removeAll()
        guard let url = URL(string: "https://srv.webshuttle.org/api/service_hash?country_code=US&language_code=en&channel_code=google&device_code=&density=1&version_code=725") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let data, error == nil, data.count < 1_000_000,
                  let services = try? JSONDecoder().decode([String: Service].self, from: data),
                  let rawURL = services["browser.resource_map"]?.service_url,
                  let endpoint = URL(string: rawURL), endpoint.scheme == "https",
                  let host = endpoint.host?.lowercased(), ["webshuttle.org", "www.webshuttle.org", "srv.webshuttle.org"].contains(host),
                  endpoint.user == nil, endpoint.password == nil else {
                DispatchQueue.main.async { self?.message = "获取节点目录失败。" }; return
            }
            URLSession.shared.dataTask(with: endpoint) { data, _, error in
                guard let data, error == nil, data.count < 2_000_000,
                      let resources = try? JSONDecoder().decode([Resource].self, from: data),
                      let value = resources.first(where: { $0.resource_key == "node_conf" })?.resource_value,
                      let nodeData = value.data(using: .utf8),
                      let nodes = try? JSONDecoder().decode([Node].self, from: nodeData), nodes.count <= 100 else {
                    DispatchQueue.main.async { self?.message = "解析节点列表失败。" }; return
                }
                DispatchQueue.main.async {
                    self?.nodes = nodes.filter { !$0.host.isEmpty && $0.port > 0 }
                    self?.message = "已获取节点，点按“测试”检查握手。"
                }
            }.resume()
        }.resume()
    }

    func probe(_ node: Node) {
        guard let port = NWEndpoint.Port(rawValue: node.port) else { return }
        readyNodes.remove(node.id)
        nodeKeys.removeValue(forKey: node.id)
        connections[node.id]?.cancel()
        let connection = NWConnection(host: NWEndpoint.Host(node.host), port: port, using: .tcp)
        connections[node.id] = connection
        probingNodes.insert(node.id)
        results[node.id] = "正在测试…"
        var done = false
        func finish(_ text: String, key: UInt8? = nil) {
            guard !done else { return }
            done = true
            connection.cancel()
            guard connections[node.id] === connection else { return }
            connections[node.id] = nil
            probingNodes.remove(node.id)
            if let key {
                nodeKeys[node.id] = key
                readyNodes.insert(node.id)
            }
            results[node.id] = text
        }
        func receive(_ accumulated: Data = Data()) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 12 - accumulated.count) { content, _, complete, error in
                Task { @MainActor in
                    var bytes = accumulated
                    if let content { bytes.append(content) }
                    if bytes.count == 12 {
                        let b = [UInt8](bytes)
                        if b[0] == 12 && b[9] == 0 && b[10] < 128 {
                            finish("握手探测通过；可尝试启用", key: b[10])
                        } else {
                            finish("节点拒绝或响应不兼容")
                        }
                    } else if complete || error != nil { finish("连接关闭或握手失败") }
                    else { receive(bytes) }
                }
            }
        }
        connection.stateUpdateHandler = { state in
            Task { @MainActor in
                switch state {
                case .ready:
                    var timestamp = UInt64(Date().timeIntervalSince1970 * 1000).bigEndian
                    var version = UInt32(725).bigEndian
                    var payload = Data([11])
                    withUnsafeBytes(of: &timestamp) { payload.append(contentsOf: $0) }
                    withUnsafeBytes(of: &version) { payload.append(contentsOf: $0) }
                    payload.append(contentsOf: self.fingerprint.utf8)
                    payload.append(0)
                    connection.send(content: payload, completion: .contentProcessed { error in
                        Task { @MainActor in
                            if error != nil { finish("发送探测失败") } else { receive() }
                        }
                    })
                case .failed: finish("无法连接节点")
                default: break
                }
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finish("连接超时") }
    }

    func activate(_ node: Node) {
        guard let key = nodeKeys[node.id], activatingNodeID == nil else { return }
        activatingNodeID = node.id
        results[node.id] = "正在启动本地网关…"
        OriginalNodeGateway.shared.start(host: node.host, port: node.port, key: key) { [weak self] result in
            guard let self else {
                if case .success = result { OriginalNodeGateway.shared.stop() }
                return
            }
            self.activatingNodeID = nil
            switch result {
            case .success:
                WebFeatures.activateOriginalNode()
                self.results[node.id] = "网关已启动；请返回浏览器测试网页"
            case .failure:
                self.results[node.id] = "网关启动失败；请重试"
            }
        }
    }
}

struct OriginalNodeDiagnosticsView: View {
    @StateObject private var diagnostics = OriginalNodeDiagnostics()
    var body: some View {
        List {
            Section {
                Button("获取免费节点列表") { diagnostics.fetchNodes() }
                Text(diagnostics.message).font(.footnote).foregroundStyle(.secondary)
                Text("测试会连接原服务商的节点并发送 APK 版本与签名摘要，不发送账号密码。节点能看到你的网络地址。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("节点") {
                ForEach(diagnostics.nodes) { node in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(node.country?.uppercased() ?? "节点")
                            .font(.headline)
                        Text(diagnostics.results[node.id] ?? "尚未测试").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button(diagnostics.probingNodes.contains(node.id) ? "测试中…" : "测试") {
                                diagnostics.probe(node)
                            }
                            .buttonStyle(.bordered)
                            .disabled(diagnostics.probingNodes.contains(node.id) || diagnostics.activatingNodeID != nil)

                            Button("启用此节点") { diagnostics.activate(node) }
                                .buttonStyle(.borderedProminent)
                                .disabled(!diagnostics.readyNodes.contains(node.id) || diagnostics.activatingNodeID != nil)
                        }
                        if !diagnostics.readyNodes.contains(node.id) && !diagnostics.probingNodes.contains(node.id) {
                            Text("请先点击测试；握手通过后可启用。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Section {
                Text("启用会切换浏览器到本地代理并重新加载标签。节点转发尚未真机验证；原协议所见的异或处理不等于可靠加密，不应依赖它保护隐私。重启后需重新测试并启用。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("原节点诊断")
    }
}
