import Foundation
import Network
import Darwin

@main
struct GatewayHarness {
    static func main() {
        guard CommandLine.arguments.count == 4,
              let port = UInt16(CommandLine.arguments[2]),
              let key = UInt8(CommandLine.arguments[3]) else {
            fputs("Usage: GatewayHarness host port key\n", stderr)
            exit(2)
        }
        let host = CommandLine.arguments[1]
        Task { @MainActor in
            OriginalNodeGateway.shared.start(host: host, port: port, key: key) { result in
                switch result {
                case .success(let localPort):
                    guard let user = OriginalNodeGateway.shared.username,
                          let password = OriginalNodeGateway.shared.password else {
                        fputs("Gateway credentials missing\n", stderr)
                        exit(1)
                    }
                    print("GATEWAY_READY=\(localPort) \(user) \(password)")
                    fflush(stdout)
                case .failure(let error):
                    fputs("Gateway startup failed: \(error)\n", stderr)
                    exit(1)
                }
            }
        }
        dispatchMain()
    }
}
