import Foundation
import Network

/// Browser-only local SOCKS5 bridge for the observed original-node TCP protocol.
/// It listens on IPv4 loopback only, never falls back to a direct connection and
/// is deliberately in-memory: neither node details nor the key are persisted.
/// This protocol's XOR transform is not encryption.
@MainActor
final class OriginalNodeGateway {
    static let shared = OriginalNodeGateway()
    private(set) var port: UInt16?
    private(set) var username: String?
    private(set) var password: String?
    var isReady: Bool { port != nil && username != nil && password != nil && listener != nil }
    private var listener: NWListener?
    private var sessions: [UUID: OriginalNodeSession] = [:]
    private var generation = UUID()
    private var pending: ((Result<UInt16, Error>) -> Void)?

    enum GatewayError: LocalizedError {
        case invalidEndpoint, startFailed, cancelled
        var errorDescription: String? {
            switch self {
            case .invalidEndpoint: return "节点配置无效"
            case .startFailed: return "本地代理启动失败"
            case .cancelled: return "本地代理已停止"
            }
        }
    }

    /// Completion is delivered once on the main actor. A key is obtained from
    /// a fresh probe separately; this bridge never obtains or persists one.
    func start(host: String, port remotePort: UInt16, key: UInt8,
               completion: @escaping (Result<UInt16, Error>) -> Void) {
        stop()
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              host == host.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.contains("/"), !host.contains("@"), remotePort > 0, key < 128,
              let endpointPort = NWEndpoint.Port(rawValue: remotePort) else {
            completion(.failure(GatewayError.invalidEndpoint)); return
        }
        generation = UUID()
        let token = generation
        let generatedUsername = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let generatedPassword = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        username = generatedUsername
        password = generatedPassword
        pending = completion
        let parameters = NWParameters.tcp
        // Binding to a specific loopback address is essential. An unspecified
        // host would expose an unauthenticated SOCKS proxy on the LAN.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        do {
            let created = try NWListener(using: parameters, on: .any)
            listener = created
            created.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.generation == token, self.port != nil else {
                        connection.cancel(); return
                    }
                    // In addition to binding loopback, reject any unexpected
                    // inbound endpoint or more than 64 concurrent sessions.
                    guard case let .hostPort(remoteHost, _) = connection.endpoint,
                          case let .ipv4(address) = remoteHost,
                          address == IPv4Address("127.0.0.1"), self.sessions.count < 64 else {
                        connection.cancel(); return
                    }
                    let id = UUID()
                    let session = OriginalNodeSession(local: connection, remoteHost: host,
                                                      remotePort: endpointPort, key: key,
                                                      username: generatedUsername, password: generatedPassword) { [weak self] in
                        self?.sessions.removeValue(forKey: id)
                    }
                    self.sessions[id] = session
                    session.start()
                }
            }
            created.stateUpdateHandler = { [weak self, weak created] state in
                Task { @MainActor in
                    guard let self, self.generation == token, let created else { return }
                    switch state {
                    case .ready:
                        guard let value = created.port?.rawValue, value > 0 else {
                            self.listenerFailed(token: token); return
                        }
                        self.port = value
                        let callback = self.pending
                        self.pending = nil
                        callback?(.success(value))
                    case .failed:
                        self.listenerFailed(token: token)
                    case .cancelled:
                        self.listenerFailed(token: token)
                    default: break
                    }
                }
            }
            created.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.generation == token, self.port == nil else { return }
                self.listenerFailed(token: token)
            }
        } catch {
            listenerFailed(token: token)
        }
    }

    func stop() {
        generation = UUID()
        let callback = pending
        pending = nil
        let wasRunning = port != nil
        port = nil
        username = nil
        password = nil
        let oldListener = listener
        listener = nil
        let oldSessions = Array(sessions.values)
        sessions.removeAll()
        oldListener?.cancel()
        for session in oldSessions { session.stop() }
        callback?(.failure(GatewayError.cancelled))
        if wasRunning {
            NotificationCenter.default.post(name: Notification.Name("originalNodeGatewayDidStop"), object: nil)
        }
    }

    private func listenerFailed(token: UUID) {
        guard generation == token else { return }
        generation = UUID()
        let callback = pending
        pending = nil
        let wasRunning = port != nil
        port = nil
        username = nil
        password = nil
        let oldListener = listener
        listener = nil
        let oldSessions = Array(sessions.values)
        sessions.removeAll()
        oldListener?.cancel()
        for session in oldSessions { session.stop() }
        callback?(.failure(GatewayError.startFailed))
        if wasRunning {
            NotificationCenter.default.post(name: Notification.Name("originalNodeGatewayDidStop"), object: nil)
        }
    }
}

/// One SOCKS client, one original-node TCP connection. All state lives on the
/// main actor; reads accumulate exact frame lengths and may be fragmented.
@MainActor
private final class OriginalNodeSession {
    private let local: NWConnection
    private let remote: NWConnection
    private let key: UInt8
    private let username: Data
    private let password: Data
    private var isStopped = false
    private var established = false
    private var localEnded = false
    private var remoteEnded = false
    private var onClose: (() -> Void)?
    private let success = Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0])
    private let failure = Data([5, 3, 0, 1, 0, 0, 0, 0, 0, 0])

    init(local: NWConnection, remoteHost: String, remotePort: NWEndpoint.Port,
         key: UInt8, username: String, password: String, onClose: @escaping () -> Void) {
        self.local = local
        self.remote = NWConnection(host: NWEndpoint.Host(remoteHost), port: remotePort, using: .tcp)
        self.key = key
        self.username = Data(username.utf8)
        self.password = Data(password.utf8)
        self.onClose = onClose
    }

    func start() {
        local.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, !self.isStopped else { return }
                switch state {
                case .ready: self.readGreeting()
                case .failed, .cancelled: self.stop()
                default: break
                }
            }
        }
        local.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, !self.established else { return }
            self.stop()
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        local.stateUpdateHandler = nil
        remote.stateUpdateHandler = nil
        local.cancel()
        remote.cancel()
        let callback = onClose
        onClose = nil
        callback?()
    }

    private func transform(_ data: Data) -> Data { Data(data.map { $0 ^ key }) }

    private func matches(_ received: Data, _ expected: Data) -> Bool {
        guard received.count == expected.count else { return false }
        return zip(received, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func readExactly(_ connection: NWConnection, count: Int,
                             accumulated: Data = Data(), completion: @escaping (Data) -> Void) {
        guard !isStopped, count >= 0, accumulated.count <= count else { stop(); return }
        if accumulated.count == count { completion(accumulated); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: count - accumulated.count) { [weak self] content, _, isComplete, error in
            Task { @MainActor in
                guard let self, !self.isStopped else { return }
                guard error == nil else { self.stop(); return }
                var result = accumulated
                if let content { result.append(content) }
                if result.count == count { completion(result) }
                else if isComplete || content?.isEmpty != false { self.stop() }
                else { self.readExactly(connection, count: count, accumulated: result, completion: completion) }
            }
        }
    }

    private func send(_ data: Data, to connection: NWConnection, completion: @escaping () -> Void) {
        guard !isStopped else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard let self, !self.isStopped else { return }
                if error != nil { self.stop() } else { completion() }
            }
        })
    }

    private func reject(_ response: Data? = nil) {
        guard !isStopped else { return }
        guard let response else { stop(); return }
        send(response, to: local) { [weak self] in self?.stop() }
    }

    private func readGreeting() {
        readExactly(local, count: 2) { [weak self] data in
            guard let self else { return }
            let bytes = [UInt8](data)
            guard bytes[0] == 5, bytes[1] > 0 else { self.stop(); return }
            self.readExactly(self.local, count: Int(bytes[1])) { [weak self] methods in
                guard let self else { return }
                guard methods.contains(2) else { self.reject(Data([5, 255])); return }
                self.send(Data([5, 2]), to: self.local) { [weak self] in self?.readAuthentication() }
            }
        }
    }

    private func readAuthentication() {
        readExactly(local, count: 2) { [weak self] data in
            guard let self else { return }
            let bytes = [UInt8](data)
            guard bytes[0] == 1, bytes[1] > 0 else { self.reject(Data([1, 1])); return }
            self.readExactly(self.local, count: Int(bytes[1])) { [weak self] candidateUser in
                guard let self else { return }
                self.readExactly(self.local, count: 1) { [weak self] length in
                    guard let self else { return }
                    guard let count = length.first, count > 0 else { self.reject(Data([1, 1])); return }
                    self.readExactly(self.local, count: Int(count)) { [weak self] candidatePassword in
                        guard let self else { return }
                        guard self.matches(candidateUser, self.username), self.matches(candidatePassword, self.password) else {
                            self.reject(Data([1, 1])); return
                        }
                        self.send(Data([1, 0]), to: self.local) { [weak self] in self?.connectRemote() }
                    }
                }
            }
        }
    }

    private func connectRemote() {
        remote.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, !self.isStopped else { return }
                switch state {
                case .ready: self.remoteGreeting()
                case .failed, .cancelled: self.stop()
                default: break
                }
            }
        }
        remote.start(queue: .main)
    }

    private func remoteGreeting() {
        send(transform(Data([7, 0])), to: remote) { [weak self] in
            guard let self else { return }
            self.readExactly(self.remote, count: 2) { [weak self] encoded in
                guard let self else { return }
                let bytes = [UInt8](self.transform(encoded))
                guard bytes[0] == 8 else { self.stop(); return }
                self.readRequestHeader()
            }
        }
    }

    private func readRequestHeader() {
        readExactly(local, count: 4) { [weak self] data in
            guard let self else { return }
            let bytes = [UInt8](data)
            guard bytes[0] == 5, bytes[1] == 1, bytes[2] == 0 else { self.reject(self.failure); return }
            switch bytes[3] {
            case 1: self.readRequestTail(prefix: data, count: 6)
            case 4: self.readRequestTail(prefix: data, count: 18)
            case 3:
                self.readExactly(self.local, count: 1) { [weak self] length in
                    guard let self else { return }
                    guard let count = length.first, count > 0 else { self.reject(self.failure); return }
                    self.readRequestTail(prefix: data + length, count: Int(count) + 2)
                }
            default: self.reject(self.failure)
            }
        }
    }

    private func readRequestTail(prefix: Data, count: Int) {
        readExactly(local, count: count) { [weak self] tail in
            guard let self else { return }
            var request = prefix + tail
            request[request.startIndex] = 9
            self.send(self.transform(request), to: self.remote) { [weak self] in
                guard let self else { return }
                self.readExactly(self.remote, count: 2) { [weak self] data in
                    guard let self else { return }
                    let reply = [UInt8](self.transform(data))
                    guard reply[0] == 10, reply[1] == 0 else { self.reject(self.failure); return }
                    self.send(self.success, to: self.local) { [weak self] in
                        guard let self else { return }
                        self.established = true
                        self.relay(from: self.local, to: self.remote, localSource: true)
                        self.relay(from: self.remote, to: self.local, localSource: false)
                    }
                }
            }
        }
    }

    /// Apply back-pressure by issuing the next read only after the prior write
    /// finishes. Propagate TCP half-close so the opposite response can finish.
    private func relay(from source: NWConnection, to destination: NWConnection, localSource: Bool) {
        guard !isStopped else { return }
        source.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] content, _, isComplete, error in
            Task { @MainActor in
                guard let self, !self.isStopped else { return }
                guard error == nil else { self.stop(); return }
                let forwardNext = { [weak self] in
                    guard let self, !self.isStopped else { return }
                    if isComplete {
                        if localSource { self.localEnded = true } else { self.remoteEnded = true }
                        destination.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                         completion: .contentProcessed { [weak self] error in
                            Task { @MainActor in
                                guard let self, !self.isStopped else { return }
                                if error != nil || (self.localEnded && self.remoteEnded) { self.stop() }
                            }
                        })
                    } else {
                        self.relay(from: source, to: destination, localSource: localSource)
                    }
                }
                if let content, !content.isEmpty {
                    self.send(self.transform(content), to: destination, completion: forwardNext)
                } else if isComplete { forwardNext() }
                else { self.stop() }
            }
        }
    }
}
