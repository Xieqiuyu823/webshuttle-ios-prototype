import SwiftUI
import WebKit
import Network
import Darwin

extension Notification.Name {
    static let webFeaturesDidChange = Notification.Name("webFeaturesDidChange")
}

/// Settings here are independent from the original app's service. No WebShuttle
/// nodes, account details or tunnel protocol are bundled with this prototype.
@MainActor
enum WebFeatures {
    private enum Keys {
        static let blocker = "features.blocker"
        static let blockerError = "features.blockerError"
        static let scriptEnabled = "features.scriptEnabled"
        static let script = "features.script"
        static let proxyKind = "features.proxyKind"
        static let proxyHost = "features.proxyHost"
        static let proxyPort = "features.proxyPort"
    }

    enum ProxyKind: String, CaseIterable, Identifiable {
        case off, http, socks5
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: return "关闭"
            case .http: return "HTTP CONNECT"
            case .socks5: return "SOCKS5"
            }
        }
    }

    struct Settings {
        var blocker: Bool
        var scriptEnabled: Bool
        var script: String
        var proxyKind: ProxyKind
        var proxyHost: String
        var proxyPort: String

        static func load() -> Settings {
            let defaults = UserDefaults.standard
            let storedKind = defaults.string(forKey: Keys.proxyKind) ?? ProxyKind.off.rawValue
            let kind = ProxyKind(rawValue: storedKind)
            return Settings(
                blocker: defaults.bool(forKey: Keys.blocker),
                scriptEnabled: defaults.bool(forKey: Keys.scriptEnabled),
                script: defaults.string(forKey: Keys.script) ?? "",
                proxyKind: kind ?? .http,
                proxyHost: kind == nil ? "" : (defaults.string(forKey: Keys.proxyHost) ?? ""),
                proxyPort: defaults.string(forKey: Keys.proxyPort) ?? ""
            )
        }

        var validProxy: Bool {
            if proxyKind == .off { return true }
            let host = proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, host == proxyHost, host.utf8.count <= 253,
                  let port = UInt16(proxyPort), port > 0 else { return false }
            if host.contains(":") {
                var address = in6_addr()
                return host.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
            }
            guard host.range(of: "^[a-zA-Z0-9.-]+$", options: .regularExpression) != nil,
                  !host.hasPrefix("."), !host.hasSuffix("."), !host.contains("..") else { return false }
            return true
        }

        func save() {
            let defaults = UserDefaults.standard
            defaults.set(blocker, forKey: Keys.blocker)
            defaults.set(scriptEnabled, forKey: Keys.scriptEnabled)
            defaults.set(script, forKey: Keys.script)
            defaults.set(proxyKind.rawValue, forKey: Keys.proxyKind)
            defaults.set(proxyHost, forKey: Keys.proxyHost)
            defaults.set(proxyPort, forKey: Keys.proxyPort)
            NotificationCenter.default.post(name: .webFeaturesDidChange, object: nil)
        }
    }

    /// Call before the initial load. `completion` runs after the content filter
    /// has finished compiling so that the first page is not loaded unfiltered.
    static func configure(_ configuration: WKWebViewConfiguration, completion: @escaping () -> Void) {
        let settings = Settings.load()
        if settings.scriptEnabled && !settings.script.isEmpty {
            let script = WKUserScript(source: settings.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            configuration.userContentController.addUserScript(script)
        }
        if #available(iOS 17.0, *) {
            if settings.proxyKind == .off {
                configuration.websiteDataStore.proxyConfigurations = []
            } else {
                // If persisted settings are invalid, use an unreachable local
                // endpoint instead of silently falling back to a direct connection.
                let host = settings.validProxy ? settings.proxyHost : "127.0.0.1"
                let rawPort = settings.validProxy ? UInt16(settings.proxyPort)! : 9
                let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: rawPort)!)
                var proxy: ProxyConfiguration
                switch settings.proxyKind {
                case .http:
                    proxy = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
                case .socks5:
                    proxy = ProxyConfiguration(socksv5Proxy: endpoint)
                case .off:
                    completion()
                    return
                }
                proxy.allowFailover = false
                configuration.websiteDataStore.proxyConfigurations = [proxy]
            }
        }
        guard settings.blocker else { completion(); return }
        // A small built-in list, not an Adblock Plus/EasyList implementation.
        let domains = ["doubleclick\\.net", "googlesyndication\\.com", "googleadservices\\.com"]
        let patterns = domains.flatMap { domain in
            ["^https?://" + domain + "/", "^https?://[a-z0-9.-]+\\." + domain + "/"]
        }
        let rule: [[String: Any]] = patterns.map { pattern in
            ["trigger": ["url-filter": pattern], "action": ["type": "block"]]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rule),
              let encoded = String(data: data, encoding: .utf8),
              let store = WKContentRuleListStore.default() else {
            UserDefaults.standard.set(true, forKey: Keys.blockerError)
            completion()
            return
        }
        let controller = configuration.userContentController
        store.compileContentRuleList(forIdentifier: "basic-ad-domains-v1", encodedContentRuleList: encoded) { list, error in
            DispatchQueue.main.async {
                UserDefaults.standard.set(list == nil, forKey: Keys.blockerError)
                if let list { controller.add(list) }
                if let error { NSLog("Content filter unavailable: %@", error.localizedDescription) }
                completion()
            }
        }
    }
}

struct WebFeaturesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = WebFeatures.Settings.load()
    @State private var showInvalidProxy = false
    @AppStorage("features.blockerError") private var blockerError = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("基础广告拦截", isOn: $settings.blocker)
                    Text("仅拦截少量内置广告域名，不支持完整的 WebShuttle 过滤规则。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if settings.blocker && blockerError {
                        Text("上次规则编译失败，广告拦截可能未生效。请重新打开标签页。")
                            .font(.footnote).foregroundStyle(.red)
                    }
                } header: { Text("内容过滤") }
                Section {
                    Picker("代理类型", selection: $settings.proxyKind) {
                        ForEach(WebFeatures.ProxyKind.allCases) { kind in Text(kind.title).tag(kind) }
                    }
                    if settings.proxyKind != .off {
                        TextField("服务器地址", text: $settings.proxyHost)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("端口", text: $settings.proxyPort).keyboardType(.numberPad)
                    }
                    Text("仅配置 WebKit 代理，需自行提供服务器。未验证下载、脚本网络、WebRTC 或 DNS 是否全部经过代理；这不是原网梭节点，也不能保证隐藏 IP。保存后所有标签会重新加载，标签内前进和后退历史会重置。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("自定义代理") }
                Section {
                    Toggle("启用自定义脚本", isOn: $settings.scriptEnabled)
                    if settings.scriptEnabled {
                        TextEditor(text: $settings.script)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 160)
                    }
                    Text("脚本会在每个主页面运行并能读取页面内容。仅使用可信脚本；暂不支持油猴 GM 接口。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("用户脚本") }
            }
            .navigationTitle("浏览设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard settings.validProxy else { showInvalidProxy = true; return }
                        settings.save()
                        dismiss()
                    }
                }
            }
            .alert("代理设置无效", isPresented: $showInvalidProxy) {
                Button("好", role: .cancel) { }
            } message: {
                Text("请输入服务器地址和 1–65535 之间的端口。")
            }
        }
    }
}
