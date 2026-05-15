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
        appState.activeConfigPath = config.path

        guard appState.isRunning && restart else { return }

        SystemProxyManager.shared.disable()
        appState.systemProxyEnabled = false
        KernelManager.shared.stop()
        appState.isRunning = false

        try? await Task.sleep(for: .milliseconds(500))

        appState.isStarting = true
        defer { appState.isStarting = false }

        do {
            try KernelManager.shared.start(
                mihomoPath: appState.effectiveMihomoPath,
                configPath: config.path
            )
            let apiCfg = appState.apiConfig
            let api = MihomoAPI(baseURL: apiCfg.baseURL, secret: apiCfg.secret)
            let ready = await api.waitUntilReady()
            guard ready else {
                appState.errorMessage = "切换配置后内核启动超时"
                return
            }
            if appState.tunEnabled {
                if KernelManager.shared.processIsRoot() {
                    do {
                        try await api.patchConfigs(["tun": ["enable": true]])
                    } catch {
                        appState.errorMessage = "TUN 启用失败：\(error.localizedDescription)"
                    }
                } else {
                    appState.errorMessage = MenuView.tunRootHint
                }
            }
            SystemProxyManager.shared.enable(
                httpPort: appState.proxyPorts.http,
                socksPort: appState.proxyPorts.socks
            )
            appState.isRunning = true
            appState.systemProxyEnabled = true
            appState.errorMessage = nil
        } catch {
            appState.errorMessage = error.localizedDescription
        }
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
