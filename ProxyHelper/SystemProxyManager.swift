import Foundation

@MainActor
final class SystemProxyManager {
    static let shared = SystemProxyManager()

    private init() {}

    private func activeNetworkService() -> String? {
        let output = shell("-listallnetworkservices")
        let lines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("An asterisk") && !$0.hasPrefix("*") }
        return lines.first { $0 == "Wi-Fi" } ?? lines.first
    }

    func enable(httpPort: Int, socksPort: Int) {
        guard let service = activeNetworkService() else { return }
        shell("-setwebproxy", service, "127.0.0.1", "\(httpPort)")
        shell("-setsecurewebproxy", service, "127.0.0.1", "\(httpPort)")
        shell("-setsocksfirewallproxy", service, "127.0.0.1", "\(socksPort)")
        shell("-setwebproxystate", service, "on")
        shell("-setsecurewebproxystate", service, "on")
        shell("-setsocksfirewallproxystate", service, "on")
    }

    func disable() {
        guard let service = activeNetworkService() else { return }
        shell("-setwebproxystate", service, "off")
        shell("-setsecurewebproxystate", service, "off")
        shell("-setsocksfirewallproxystate", service, "off")
    }

    func isEnabled(httpPort: Int) -> Bool {
        guard let service = activeNetworkService() else { return false }
        let output = shell("-getwebproxy", service)
        return output.contains("127.0.0.1") && output.contains("\(httpPort)")
            && output.contains("Enabled: Yes")
    }

    @discardableResult
    private func shell(_ args: String...) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = Array(args)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
