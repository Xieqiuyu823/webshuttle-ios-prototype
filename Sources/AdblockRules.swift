import Foundation
import SwiftUI
import WebKit
import UniformTypeIdentifiers

/// An intentionally conservative subset of ABP syntax. Unsupported lines are
/// counted and skipped rather than converted to a broader blocking rule.
@MainActor
enum AdblockRules {
    static let rulesKey = "adblock.customRules"
    static let errorKey = "features.blockerError"
    private static let maxRules = 10_000

    struct Translation {
        var blocks: [[String: Any]] = []
        var exceptions: [[String: Any]] = []
        var accepted = 0
        var skipped = 0
    }

    static func translate(_ text: String) -> Translation {
        var result = Translation()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { continue }
            guard result.accepted < maxRules else { result.skipped += 1; continue }
            if let cosmetic = cosmeticRule(line) {
                result.blocks.append(cosmetic)
                result.accepted += 1
                continue
            }
            var body = line
            let isException = body.hasPrefix("@@")
            if isException { body.removeFirst(2) }
            let pieces = body.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
            let pattern = String(pieces[0])
            guard pattern.hasPrefix("||"), pattern.hasSuffix("^"), pattern.count > 3 else {
                result.skipped += 1; continue
            }
            let domain = String(pattern.dropFirst(2).dropLast()).lowercased()
            guard validDomain(domain) else { result.skipped += 1; continue }
            var thirdParty = false
            if pieces.count == 2 {
                // Other options can change the rule's scope; do not broaden it.
                guard pieces[1] == "third-party" else { result.skipped += 1; continue }
                thirdParty = true
            }
            let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
            // Explicit variants avoid unsupported grouping/alternation in WebKit's
            // content-blocker regex subset and prevent domain-prefix matches.
            let prefixes = ["^https?://" + escaped, "^https?://[a-z0-9.-]+\\." + escaped]
            let patterns = prefixes.flatMap { [$0 + "/", $0 + ":[0-9]+/"] }
            for pattern in patterns {
                var trigger: [String: Any] = ["url-filter": pattern]
                if thirdParty { trigger["load-type"] = ["third-party"] }
                let action = isException ? "ignore-previous-rules" : "block"
                let translated: [String: Any] = ["trigger": trigger, "action": ["type": action]]
                if isException { result.exceptions.append(translated) }
                else { result.blocks.append(translated) }
            }
            result.accepted += 1
        }
        return result
    }

    private static func validDomain(_ domain: String) -> Bool {
        guard domain.count <= 253, domain.contains("."),
              domain.range(of: "^[a-z0-9.-]+$", options: .regularExpression) != nil,
              !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.contains("..") else { return false }
        return domain.split(separator: ".").allSatisfy { !$0.hasPrefix("-") && !$0.hasSuffix("-") && $0.count <= 63 }
    }

    private static func cosmeticRule(_ line: String) -> [String: Any]? {
        let pieces = line.components(separatedBy: "##")
        guard pieces.count == 2, validDomain(pieces[0].lowercased()),
              pieces[1].range(of: "^[.#][a-zA-Z_][a-zA-Z0-9_-]*$", options: .regularExpression) != nil else { return nil }
        return [
            "trigger": ["url-filter": ".*", "if-domain": ["*" + pieces[0].lowercased()]],
            "action": ["type": "css-display-none", "selector": pieces[1]]
        ]
    }

    static func compile(configuration: WKWebViewConfiguration, completion: @escaping () -> Void) {
        let builtIn = "||doubleclick.net^\n||googlesyndication.com^\n||googleadservices.com^"
        let custom = UserDefaults.standard.string(forKey: rulesKey) ?? ""
        let parsed = translate(builtIn + "\n" + custom)
        let rules = parsed.blocks + parsed.exceptions
        guard let json = try? JSONSerialization.data(withJSONObject: rules),
              let encoded = String(data: json, encoding: .utf8),
              let store = WKContentRuleListStore.default() else {
            UserDefaults.standard.set(true, forKey: errorKey)
            completion(); return
        }
        store.compileContentRuleList(forIdentifier: "user-adblock-rules-v1", encodedContentRuleList: encoded) { list, error in
            DispatchQueue.main.async {
                UserDefaults.standard.set(list == nil, forKey: errorKey)
                if let list { configuration.userContentController.add(list) }
                if let error { NSLog("Content filter unavailable: %@", error.localizedDescription) }
                completion()
            }
        }
    }
}

struct AdblockRulesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rules = UserDefaults.standard.string(forKey: AdblockRules.rulesKey) ?? ""
    @State private var showLargeError = false
    @State private var showImporter = false
    @State private var importError: String?
    private let limit = 2_000_000
    private enum ImportError: LocalizedError {
        case tooLarge, notUTF8
        var errorDescription: String? {
            switch self {
            case .tooLarge: return "规则文件不能超过 2 MB。"
            case .notUTF8: return "规则文件必须为 UTF-8 文本。"
            }
        }
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $rules).font(.system(.body, design: .monospaced)).frame(minHeight: 260)
                Button("从文件导入规则") { showImporter = true }
            } header: { Text("自定义规则") } footer: {
                Text("每行一条。支持 ||example.com^、@@||example.com^、$third-party 和 example.com##.ad-banner；其他语法会跳过。可粘贴订阅文本，本版不会自动联网更新订阅。")
            }
            Section {
                let translated = AdblockRules.translate(rules)
                Text("支持 \(translated.accepted) 条；跳过 \(translated.skipped) 条")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("广告规则")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    guard rules.utf8.count <= limit else { showLargeError = true; return }
                    UserDefaults.standard.set(rules, forKey: AdblockRules.rulesKey)
                    NotificationCenter.default.post(name: .webFeaturesDidChange, object: nil)
                    dismiss()
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.plainText]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                if let size = values.fileSize, size > limit { throw ImportError.tooLarge }
                let data = try Data(contentsOf: url)
                guard data.count <= limit else { throw ImportError.tooLarge }
                guard let contents = String(data: data, encoding: .utf8) else { throw ImportError.notUTF8 }
                rules = contents
            } catch { importError = error.localizedDescription }
        }
        .alert("导入失败", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("好", role: .cancel) { importError = nil }
        } message: { Text(importError ?? "未知错误") }
        .alert("规则过大", isPresented: $showLargeError) {
            Button("好", role: .cancel) { }
        } message: { Text("最多支持 2 MB 的规则文本。") }
    }
}
