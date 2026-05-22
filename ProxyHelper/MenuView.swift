import SwiftUI

struct MenuView: View {
    @Environment(AppState.self) var state
    @Environment(\.openWindow) var openWindow

    var body: some View {
        if state.configFolderPath.isEmpty {
            // === 首次使用：未选择配置文件夹 ===
            Section("初始设置") {
                Text("请选择存放 mihomo .yaml 配置文件的目录")
                Button("选择配置文件夹…") { pickConfigFolder() }
                Button("打开设置…") {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        } else {
            // === 正常流程 ===
            Section("状态") {
                Text(state.isStarting ? "启动中..." : state.isStopping ? "停止中..." : state.isRunning ? "运行中" : "已停止")

                if state.isRunning {
                    Button {
                        copyProxyAddress()
                    } label: {
                        Text(proxyPortSummary)
                    }
                    if let version = state.kernelVersion {
                        Button {
                            revealMihomoBinary()
                        } label: {
                            Text("内核：\(version)")
                        }
                    }
                }

                if let reason = state.startBlockReason {
                    Text(reason)
                        .foregroundStyle(.secondary)
                }

                if let err = state.errorMessage {
                    Button(role: .destructive) {
                        openWindow(id: "logs")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Label(err, systemImage: "exclamationmark.triangle")
                    }
                }

                if state.isRunning || state.isStopping {
                    Button("停止") {
                        Task { await stopKernel() }
                    }
                    .disabled(state.isStopping)
                } else {
                    Button("启动") {
                        Task { await startKernel() }
                    }
                    .disabled(
                        state.activeConfigPath.isEmpty
                        || !state.configs.contains(where: { $0.path == state.activeConfigPath })
                        || state.isStarting
                    )
                }
            }

            Section("配置文件") {
                if state.configs.isEmpty {
                    Button("打开配置文件夹") { openConfigFolder() }
                } else {
                    ForEach(state.configs) { config in
                        Button {
                            Task { await switchTo(config) }
                        } label: {
                            if config.path == state.activeConfigPath {
                                Label(config.name, systemImage: "checkmark")
                            } else {
                                Text(config.name)
                            }
                        }
                    }
                }
            }

            Divider()

            Button {
                Task { await toggleTun() }
            } label: {
                if state.tunEnabled {
                    Label("TUN 模式", systemImage: "checkmark")
                } else {
                    Text("TUN 模式")
                }
            }

            Button("复制启用 TUN 命令") {
                copyEnableTunCommand()
            }
        }

        Divider()

        Button("打开配置文件夹") { openConfigFolder() }
            .disabled(state.configFolderPath.isEmpty)

        Button("打开数据文件夹") {
            NSWorkspace.shared.open(KernelManager.mihomoHome)
        }

        Button("Dashboard") {
            NSWorkspace.shared.open(DashboardURL.homepage)
        }
        .disabled(!state.isRunning)

        Button("日志...") {
            openWindow(id: "logs")
            NSApp.activate(ignoringOtherApps: true)
        }

        Button("设置...") {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("关于 ProxyHelper") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        }

        Button("退出") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    // MARK: - Actions

    func openConfigFolder() {
        let path = state.configFolderPath
        guard !path.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func pickConfigFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "选择文件夹"
        panel.begin { response in
            guard response == .OK, let path = panel.url?.path(percentEncoded: false) else { return }
            state.configFolderPath = path
            let configs = ConfigManager.shared.scan(folderPath: path)
            state.configs = configs
            if let first = configs.first {
                state.activeConfigPath = first.path
            }
            ConfigManager.shared.startWatching(folderPath: path) {
                state.configs = ConfigManager.shared.scan(folderPath: path)
            }
        }
    }

    func switchTo(_ config: ConfigFile) async {
        await ConfigManager.shared.switchConfig(to: config, appState: state)
    }

    func startKernel() async {
        state.isStarting = true
        state.errorMessage = nil
        defer { state.isStarting = false }
        let appState = state
        KernelManager.shared.onUnexpectedStop = { error in
            NetworkChangeMonitor.shared.stop()
            SystemProxyManager.shared.disable()
            appState.systemProxyEnabled = false
            appState.isRunning = false
            appState.kernelVersion = nil
            if let error {
                appState.errorMessage = "内核重启失败：\(error.localizedDescription)"
            } else {
                appState.errorMessage = "内核意外停止"
            }
        }
        KernelManager.shared.onLogLine = { line in
            let entry = LogEntry.parse(line)
            appState.logEntries.append(entry)
            if appState.logEntries.count > 2000 {
                appState.logEntries.removeFirst(appState.logEntries.count - 2000)
            }
        }
        do {
            try KernelManager.shared.start(
                mihomoPath: state.effectiveMihomoPath,
                configPath: state.activeConfigPath
            )
            let cfg = state.apiConfig
            let api = MihomoAPI(baseURL: cfg.baseURL, secret: cfg.secret)
            guard let version = await api.waitUntilReady() else {
                state.errorMessage = "内核启动超时"
                KernelManager.shared.stop()
                KernelManager.shared.onUnexpectedStop = nil
                return
            }
            state.kernelVersion = version
            if state.tunEnabled {
                if KernelManager.shared.processIsRoot() {
                    do {
                        try await api.patchConfigs(["tun": ["enable": true]])
                    } catch {
                        state.errorMessage = "TUN 启用失败：\(error.localizedDescription)"
                    }
                } else {
                    state.errorMessage = Self.tunRootHint
                }
            }
            SystemProxyManager.shared.enable(
                httpPort: state.proxyPorts.http,
                socksPort: state.proxyPorts.socks
            )
            NetworkChangeMonitor.shared.onChange = {
                guard appState.isRunning, appState.systemProxyEnabled else { return }
                SystemProxyManager.shared.enable(
                    httpPort: appState.proxyPorts.http,
                    socksPort: appState.proxyPorts.socks
                )
            }
            NetworkChangeMonitor.shared.start()
            state.isRunning = true
            state.systemProxyEnabled = true
            state.errorMessage = nil
        } catch {
            KernelManager.shared.onUnexpectedStop = nil
            state.errorMessage = error.localizedDescription
        }
    }

    func stopKernel() async {
        guard !state.isStopping else { return }
        state.isStopping = true
        defer { state.isStopping = false }
        KernelManager.shared.onUnexpectedStop = nil
        KernelManager.shared.onLogLine = nil
        NetworkChangeMonitor.shared.stop()
        SystemProxyManager.shared.disable()
        state.systemProxyEnabled = false
        await KernelManager.shared.stopAndWait()
        state.isRunning = false
        state.kernelVersion = nil
    }

    func copyProxyAddress() {
        let ports = state.proxyPorts
        let address = "127.0.0.1:\(ports.http)"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(address, forType: .string)
    }

    func revealMihomoBinary() {
        let path = state.effectiveMihomoPath
        guard !path.isEmpty else { return }
        let resolved = (path as NSString).resolvingSymlinksInPath
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: resolved)])
    }

    func copyEnableTunCommand() {
        let cmd = "sudo chown root:wheel $(which mihomo) && sudo chmod u+s $(which mihomo)"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cmd, forType: .string)
    }

    func toggleTun() async {
        let newValue = !state.tunEnabled
        if newValue && state.isRunning && !KernelManager.shared.processIsRoot() {
            state.errorMessage = Self.tunRootHint
            return
        }
        state.tunEnabled = newValue
        guard state.isRunning else { return }
        let cfg = state.apiConfig
        let api = MihomoAPI(baseURL: cfg.baseURL, secret: cfg.secret)
        do {
            try await api.patchConfigs(["tun": ["enable": newValue]])
            state.errorMessage = nil
        } catch {
            state.errorMessage = "TUN 切换失败：\(error.localizedDescription)"
        }
    }

    static let tunRootHint = "TUN 需 root 权限：点下方「复制启用 TUN 命令」执行后，停止再启动 mihomo。"

    func refreshConfigs() {
        state.configs = ConfigManager.shared.scan(folderPath: state.configFolderPath)
        if !state.configs.contains(where: { $0.path == state.activeConfigPath }),
           let first = state.configs.first {
            state.activeConfigPath = first.path
        }
    }

    private var proxyPortSummary: String {
        let ports = state.proxyPorts
        if ports.http == ports.socks {
            return "混合代理：127.0.0.1:\(ports.http)"
        }
        return "HTTP 代理：127.0.0.1:\(ports.http)  SOCKS：\(ports.socks)"
    }

}
