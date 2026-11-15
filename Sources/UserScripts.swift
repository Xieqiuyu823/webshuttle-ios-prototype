import SwiftUI
import WebKit

/// Scripts run in the page's main frame and may read or change that page.
/// This deliberately does not expose native network, filesystem or credential APIs.
struct UserScriptItem: Codable, Identifiable {
    var id = UUID()
    var name: String
    var source: String
    var enabled = false
}

@MainActor
enum UserScripts {
    private static let key = "features.userScripts.v1"
    private static let legacyScript = "features.script"
    private static let legacyEnabled = "features.scriptEnabled"

    static func load() -> [UserScriptItem] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key) {
            return (try? JSONDecoder().decode([UserScriptItem].self, from: data)) ?? []
        }
        // Preserve the prototype's previous one-script setting on upgrade.
        let source = defaults.string(forKey: legacyScript) ?? ""
        let scripts = source.isEmpty ? [] : [UserScriptItem(name: "原自定义脚本", source: source, enabled: defaults.bool(forKey: legacyEnabled))]
        persist(scripts, notify: false)
        return scripts
    }

    private static func persist(_ scripts: [UserScriptItem], notify: Bool) {
        guard let data = try? JSONEncoder().encode(scripts) else { return }
        UserDefaults.standard.set(data, forKey: key)
        if notify { NotificationCenter.default.post(name: .webFeaturesDidChange, object: nil) }
    }

    static func save(_ scripts: [UserScriptItem]) { persist(scripts, notify: true) }

    /// Extract supported metadata from the standard userscript header only.
    static func metadata(_ source: String) -> (matches: [String], excludes: [String], documentStart: Bool) {
        var inside = false
        var foundHeader = false
        var closedHeader = false
        var malformed = false
        var matches: [String] = []
        var excludes: [String] = []
        var documentStart = false
        for line in source.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line == "// ==UserScript==" { inside = true; foundHeader = true; continue }
            if line == "// ==/UserScript==" { closedHeader = true; break }
            guard inside, line.hasPrefix("//") else { continue }
            let body = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            let parts = body.split(whereSeparator: { $0.isWhitespace })
            guard let directive = parts.first else { continue }
            switch directive {
            case "@match", "@include":
                if parts.count >= 2 { matches.append(String(parts[1])) } else { malformed = true }
            case "@exclude", "@exclude-match":
                if parts.count >= 2 { excludes.append(String(parts[1])) } else { malformed = true }
            case "@run-at":
                if parts.count >= 2 { documentStart = parts[1] == "document-start" } else { malformed = true }
            default: break
            }
        }
        // A broken header must never silently become an all-sites script.
        if malformed || (foundHeader && !closedHeader) { matches = ["<invalid-userscript-header>"] }
        return (matches, excludes, documentStart)
    }

    static func configure(_ controller: WKUserContentController) {
        for item in load() where item.enabled && !item.source.isEmpty {
            let info = metadata(item.source)
            // With no metadata the user explicitly enables the script for all HTTP(S) pages.
            let patterns = info.matches.isEmpty ? ["<all_urls>"] : info.matches
            guard let data = try? JSONSerialization.data(withJSONObject: patterns),
                  let encoded = String(data: data, encoding: .utf8),
                  let excludeData = try? JSONSerialization.data(withJSONObject: info.excludes),
                  let excluded = String(data: excludeData, encoding: .utf8) else { continue }
            let key = "__browser_userscript_\(item.id.uuidString)_"
            guard let keyData = try? JSONSerialization.data(withJSONObject: [key]),
                  let keyArray = String(data: keyData, encoding: .utf8) else { continue }
            let prefix = #"""
            (() => {
              'use strict';
              const patterns = PATTERNS;
              const excludes = EXCLUSIONS;
              const wildcard = (text, pattern) => {
                let expression = '^';
                for (const char of pattern) {
                  if (char === '*') expression += '.*';
                  else expression += /[\\^$.*+?()[\]{}|]/.test(char) ? '\\' + char : char;
                }
                try { return new RegExp(expression + '$').test(text); } catch (_) { return false; }
              };
              const matches = pattern => {
                if (location.protocol !== 'http:' && location.protocol !== 'https:') return false;
                if (pattern === '<all_urls>') return true;
                // @include uses a glob over the full URL; @match host wildcards also
                // match the base domain, as in browser userscript managers.
                const match = pattern.match(/^(\*|https?):\/\/([^/]+)(\/.*)$/i);
                if (!match) return wildcard(location.href, pattern);
                const scheme = match[1].toLowerCase();
                if (scheme !== '*' && location.protocol !== scheme + ':') return false;
                const host = match[2].toLowerCase();
                const current = location.hostname.toLowerCase();
                let hostOK = host === '*' || host === current;
                if (host.startsWith('*.')) {
                  const domain = host.slice(2);
                  hostOK = current === domain || current.endsWith('.' + domain);
                }
                return hostOK && wildcard(location.pathname + location.search, match[3]);
              };
              if (!patterns.some(matches) || excludes.some(matches)) return;
              const storageKey = KEY[0];
              // Values are isolated per script and web origin, not GM's cross-origin storage.
              const GM_getValue = (name, fallback) => {
                try { const value = localStorage.getItem(storageKey + name); return value === null ? fallback : JSON.parse(value); }
                catch (_) { return fallback; }
              };
              const GM_setValue = (name, value) => { try { localStorage.setItem(storageKey + name, JSON.stringify(value)); } catch (_) {} };
              const GM_deleteValue = name => { try { localStorage.removeItem(storageKey + name); } catch (_) {} };
              const GM_addStyle = css => {
                const style = document.createElement('style'); style.textContent = css;
                (document.head || document.documentElement).appendChild(style); return style;
              };
              const GM = { getValue: async (name, fallback) => GM_getValue(name, fallback),
                           setValue: async (name, value) => GM_setValue(name, value),
                           deleteValue: async name => GM_deleteValue(name), addStyle: GM_addStyle };
              (function() {
            """#
            let script = prefix.replacingOccurrences(of: "PATTERNS", with: encoded)
                .replacingOccurrences(of: "EXCLUSIONS", with: excluded)
                .replacingOccurrences(of: "KEY", with: keyArray) + "\n" + item.source + "\n}).call(window);\n})();"
            controller.addUserScript(WKUserScript(
                source: script,
                injectionTime: info.documentStart ? .atDocumentStart : .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }
    }
}

struct UserScriptsView: View {
    @State private var scripts = UserScripts.load()
    @State private var editing: UserScriptItem?
    @State private var showingEditor = false

    var body: some View {
        List {
            Section {
                ForEach(scripts) { script in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { scripts.first(where: { $0.id == script.id })?.enabled ?? false },
                            set: { value in
                                guard let index = scripts.firstIndex(where: { $0.id == script.id }) else { return }
                                scripts[index].enabled = value
                                UserScripts.save(scripts)
                            }
                        )) { Text(script.name) }
                        Button("编辑") { editing = script; showingEditor = true }
                            .buttonStyle(.borderless)
                    }
                }
                .onDelete { offsets in scripts.remove(atOffsets: offsets); UserScripts.save(scripts) }
            } footer: {
                Text("仅运行可信脚本。支持 @match、@include、@exclude、@exclude-match 和 @run-at document-start；未声明匹配规则时在所有 HTTP(S) 主页面运行。GM 值按网站单独保存，页面可能读取这些值，请勿存放密码；不支持 GM 网络请求及扩展 API。")
            }
        }
        .navigationTitle("用户脚本")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = UserScriptItem(name: "新脚本", source: ""); showingEditor = true } label: {
                    Image(systemName: "plus")
                }.accessibilityLabel("添加脚本")
            }
        }
        .sheet(isPresented: $showingEditor) {
            if let item = editing {
                UserScriptEditor(item: item) { updated in
                    if let index = scripts.firstIndex(where: { $0.id == updated.id }) { scripts[index] = updated }
                    else { scripts.append(updated) }
                    UserScripts.save(scripts)
                }
            }
        }
    }
}

private struct UserScriptEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var item: UserScriptItem
    let onSave: (UserScriptItem) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("脚本名称", text: $item.name)
                Toggle("启用", isOn: $item.enabled)
                Section("JavaScript") {
                    TextEditor(text: $item.source)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 280)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("编辑脚本")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let trimmed = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        item.name = trimmed.isEmpty ? "未命名脚本" : trimmed
                        onSave(item); dismiss()
                    }.disabled(item.source.isEmpty)
                }
            }
        }
    }
}
