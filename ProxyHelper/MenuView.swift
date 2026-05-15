import SwiftUI

struct MenuView: View {
    @Environment(AppState.self) var state
    @Environment(\.openWindow) var openWindow

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    var body: some View {
        // 状态行
        Label {
            HStack(spacing: 6) {
                Text(state.isStarting ? "启动中..." : state.isRunning ? "运行中" : "已停止")
                if !appVersion.isEmpty {
                    Text("v\(appVersion)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } icon: {
            if state.isStarting {
                ProgressView().controlSize(.mini)
            } else {
                Circle()
                    .fill(state.isRunning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
            }
        }
        .font(.headline)

        if state.isRunning {
            Text("HTTP 代理：127.0.0.1:\(String(state.httpPort))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }

        if let err = state.errorMessage {
            Label(err, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }

        Divider()

        if state.configs.isEmpty {
            Text("未找到配置文件")
                .foregroundStyle(.secondary)
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

        Divider()

        if state.isRunning {
            Button("停止") {
                Task { await stopKernel() }
            }
        } else {
            Button("启动") {
                Task { await startKernel() }
            }
            .disabled(state.activeConfigPath.isEmpty || state.isStarting)
        }

        Divider()

        Button("打开配置文件夹") {
            let path = state.configFolderPath
            guard !path.isEmpty else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        .disabled(state.configFolderPath.isEmpty)

        Button("打开数据目录") {
            NSWorkspace.shared.open(KernelManager.mihomoHome)
        }

        Button("Dashboard...") {
            let cfg = state.apiConfig
            state.dashboardURL = DashboardURL.make(apiBaseURL: cfg.baseURL, secret: cfg.secret)
            openWindow(id: "dashboard")
            NSApp.activate(ignoringOtherApps: true)
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

        Button("退出") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    // MARK: - Actions

    func switchTo(_ config: ConfigFile) async {
        await ConfigManager.shared.switchConfig(to: config, appState: state)
    }

    func startKernel() async {
        state.isStarting = true
        state.errorMessage = nil
        defer { state.isStarting = false }
        let appState = state
        KernelManager.shared.onUnexpectedStop = {
            appState.isRunning = false
            appState.errorMessage = "内核意外停止"
        }
        KernelManager.shared.onLogLine = { line in
            appState.logLines.append(line)
            if appState.logLines.count > 2000 {
                appState.logLines.removeFirst(appState.logLines.count - 2000)
            }
        }
        do {
            try KernelManager.shared.start(
                mihomoPath: state.effectiveMihomoPath,
                configPath: state.activeConfigPath
            )
            let cfg = state.apiConfig
            let api = MihomoAPI(baseURL: cfg.baseURL, secret: cfg.secret)
            let ready = await api.waitUntilReady()
            guard ready else {
                state.errorMessage = "内核启动超时"
                KernelManager.shared.stop()
                KernelManager.shared.onUnexpectedStop = nil
                return
            }
            SystemProxyManager.shared.enable(
                httpPort: state.httpPort,
                socksPort: state.socksPort
            )
            state.isRunning = true
            state.systemProxyEnabled = true
            state.errorMessage = nil
        } catch {
            KernelManager.shared.onUnexpectedStop = nil
            state.errorMessage = error.localizedDescription
        }
    }

    func stopKernel() async {
        KernelManager.shared.onUnexpectedStop = nil
        KernelManager.shared.onLogLine = nil
        SystemProxyManager.shared.disable()
        state.systemProxyEnabled = false
        KernelManager.shared.stop()
        state.isRunning = false
    }

    func refreshConfigs() {
        state.configs = ConfigManager.shared.scan(folderPath: state.configFolderPath)
        if !state.configs.contains(where: { $0.path == state.activeConfigPath }),
           let first = state.configs.first {
            state.activeConfigPath = first.path
        }
    }

}
