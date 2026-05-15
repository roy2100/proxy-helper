import Foundation
import Yams

@MainActor
final class ConfigManager {
    static let shared = ConfigManager()
    private var folderMonitor: DispatchSourceFileSystemObject?
    private var monitoredFolderFD: Int32 = -1

    private init() {}

    func scan(folderPath: String) -> [ConfigFile] {
        guard !folderPath.isEmpty else { return [] }
        let url = URL(fileURLWithPath: folderPath)
        let fm = FileManager.default

        guard let items = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return items
            .filter { ["yaml", "yml"].contains($0.pathExtension.lowercased()) }
            .compactMap { fileURL -> ConfigFile? in
                let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
                return ConfigFile(
                    path: fileURL.path,
                    name: fileURL.deletingPathExtension().lastPathComponent,
                    modifiedAt: attrs?.contentModificationDate ?? .distantPast
                )
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func startWatching(folderPath: String, onChange: @escaping @MainActor () -> Void) {
        stopWatching()
        guard !folderPath.isEmpty else { return }

        let fd = open(folderPath, O_EVTONLY)
        guard fd >= 0 else { return }
        monitoredFolderFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.main
        )
        source.setEventHandler {
            Task { @MainActor in onChange() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        folderMonitor = source
    }

    func stopWatching() {
        folderMonitor?.cancel()
        folderMonitor = nil
    }

    func switchConfig(
        to config: ConfigFile,
        appState: AppState,
        restart: Bool = true
    ) async {
        let previousPath = appState.activeConfigPath
        appState.activeConfigPath = config.path

        guard appState.isRunning && restart else { return }

        // 旧 API 配置（mihomo 还在监听旧端口/secret）
        let apiCfg = ConfigManager.shared.parseAPIConfig(at: previousPath)
        let api = MihomoAPI(baseURL: apiCfg.baseURL, secret: apiCfg.secret)

        // 配置可能不在 mihomo home 目录下（如 iCloud），用 payload 形式绕过路径白名单
        let payload = try? String(contentsOfFile: config.path, encoding: .utf8)

        do {
            try await api.reloadConfig(path: config.path, payload: payload)
        } catch {
            appState.errorMessage = "切换配置失败：\(error.localizedDescription)"
            appState.activeConfigPath = previousPath
            return
        }

        // 让 KernelManager 在崩溃自动重启时也用新配置
        KernelManager.shared.setCurrentConfigPath(config.path)

        // 配置可能改了系统代理端口，重置一次
        let ports = appState.proxyPorts
        SystemProxyManager.shared.disable()
        SystemProxyManager.shared.enable(httpPort: ports.http, socksPort: ports.socks)
        appState.systemProxyEnabled = true

        // TUN 状态在 reload 后会被新配置覆盖，按用户偏好重新应用
        if appState.tunEnabled, KernelManager.shared.processIsRoot() {
            let newApi = MihomoAPI(
                baseURL: appState.apiConfig.baseURL,
                secret: appState.apiConfig.secret
            )
            do {
                try await newApi.patchConfigs(["tun": ["enable": true]])
            } catch {
                appState.errorMessage = "TUN 启用失败：\(error.localizedDescription)"
                return
            }
        }

        appState.errorMessage = nil
    }

    func parseAPIConfig(at path: String) -> (baseURL: String, secret: String) {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8),
              let yaml = try? Yams.load(yaml: content) as? [String: Any] else {
            return ("http://127.0.0.1:9090", "")
        }
        let secret = yaml["secret"] as? String ?? ""
        var port = 9090
        if let ec = yaml["external-controller"] as? String,
           let colonIdx = ec.lastIndex(of: ":"),
           let p = Int(ec[ec.index(after: colonIdx)...]) {
            port = p
        }
        return ("http://127.0.0.1:\(port)", secret)
    }

    func parseProxyPorts(at path: String) -> (http: Int, socks: Int) {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8),
              let yaml = try? Yams.load(yaml: content) as? [String: Any] else {
            return (7890, 7891)
        }

        if let mixedPort = yamlPortValue(yaml["mixed-port"]) {
            return (mixedPort, mixedPort)
        }

        return (
            yamlPortValue(yaml["port"]) ?? 7890,
            yamlPortValue(yaml["socks-port"]) ?? 7891
        )
    }

    /// 启动 mihomo 前需要保证可用的端口列表，依次为 API、混合端口或 HTTP/SOCKS。
    func parseRequiredPorts(at path: String) -> [(name: String, port: Int)] {
        var ports: [(String, Int)] = []

        let baseURL = parseAPIConfig(at: path).baseURL
        let apiPort = URL(string: baseURL)?.port ?? 9090
        ports.append(("external-controller", apiPort))

        let proxy = parseProxyPorts(at: path)
        if proxy.http == proxy.socks {
            ports.append(("mixed-port", proxy.http))
        } else {
            ports.append(("port", proxy.http))
            ports.append(("socks-port", proxy.socks))
        }
        return ports
    }

    private func yamlPortValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int, (1...65535).contains(intValue) {
            return intValue
        }
        if let stringValue = value as? String,
           let intValue = Int(stringValue),
           (1...65535).contains(intValue) {
            return intValue
        }
        return nil
    }
}
