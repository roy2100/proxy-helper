import SwiftUI
import Observation

@MainActor
@Observable
final class AppState {
    var isRunning: Bool = false
    var isStarting: Bool = false
    var isStopping: Bool = false
    var systemProxyEnabled: Bool = false
    var errorMessage: String? = nil
    var configs: [ConfigFile] = []
    var configFolderSet: Bool = !(UserDefaults.standard.string(forKey: "configFolderPath") ?? "").isEmpty
    var logEntries: [LogEntry] = []
    var kernelVersion: String? = nil

    // 存储属性 + didSet 确保 @Observable 能追踪变更
    var activeConfigPath: String = UserDefaults.standard.string(forKey: "activeConfigPath") ?? "" {
        didSet { UserDefaults.standard.set(activeConfigPath, forKey: "activeConfigPath") }
    }

    var tunEnabled: Bool = UserDefaults.standard.bool(forKey: "tunEnabled") {
        didSet { UserDefaults.standard.set(tunEnabled, forKey: "tunEnabled") }
    }

    @ObservationIgnored
    var mihomoPath: String {
        get { UserDefaults.standard.string(forKey: "mihomoPath") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "mihomoPath") }
    }

    @ObservationIgnored
    var configFolderPath: String {
        get { UserDefaults.standard.string(forKey: "configFolderPath") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "configFolderPath") }
    }

    var effectiveMihomoPath: String {
        if !mihomoPath.isEmpty { return mihomoPath }
        let candidates = [
            "/opt/homebrew/bin/mihomo",
            "/usr/local/bin/mihomo",
        ]
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        } ?? ""
    }

    var activeConfig: ConfigFile? {
        configs.first { $0.path == activeConfigPath }
    }

    var startBlockReason: String? {
        if configs.isEmpty { return "配置文件夹中未找到 .yaml 文件" }
        if !configs.contains(where: { $0.path == activeConfigPath }) { return "请先选择配置文件" }
        return nil
    }

    var apiConfig: (baseURL: String, secret: String) {
        guard !activeConfigPath.isEmpty else {
            return ("http://127.0.0.1:9090", "")
        }
        return ConfigManager.shared.parseAPIConfig(at: activeConfigPath)
    }

    var proxyPorts: (http: Int, socks: Int) {
        guard !activeConfigPath.isEmpty else {
            return (7890, 7891)
        }
        return ConfigManager.shared.parseProxyPorts(at: activeConfigPath)
    }

    init() {
        configs = ConfigManager.shared.scan(folderPath: configFolderPath)
    }
}

struct ConfigFile: Identifiable, Hashable {
    let id = UUID()
    let path: String
    let name: String
    let modifiedAt: Date

    static func == (lhs: ConfigFile, rhs: ConfigFile) -> Bool { lhs.path == rhs.path }
    func hash(into hasher: inout Hasher) { hasher.combine(path) }
}
