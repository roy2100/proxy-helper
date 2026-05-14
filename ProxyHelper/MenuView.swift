import SwiftUI

struct MenuView: View {
    @Environment(AppState.self) var state
    @Environment(\.openWindow) var openWindow

    var body: some View {
        statusBlock

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
            .disabled(state.activeConfigPath.isEmpty)
        }

        Divider()

        Button("打开配置文件夹") {
            let path = state.configFolderPath
            guard !path.isEmpty else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        .disabled(state.configFolderPath.isEmpty)

        Button("设置...") {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("退出") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    @ViewBuilder
    var statusBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(state.isRunning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(state.isRunning ? "运行中" : "已停止")
                    .font(.headline)
            }

            if state.isRunning {
                HStack {
                    Text(state.uploadSpeed)
                    Spacer()
                    Text(state.downloadSpeed)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 220, alignment: .leading)
    }

    // MARK: - Actions

    func switchTo(_ config: ConfigFile) async {
        await ConfigManager.shared.switchConfig(to: config, appState: state)
    }

    func startKernel() async {
        let appState = state
        KernelManager.shared.onUnexpectedStop = {
            appState.isRunning = false
            appState.errorMessage = "内核意外停止"
            appState.uploadSpeed = "↑ 0 B/s"
            appState.downloadSpeed = "↓ 0 B/s"
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
            startTrafficMonitor()
        } catch {
            KernelManager.shared.onUnexpectedStop = nil
            state.errorMessage = error.localizedDescription
        }
    }

    func stopKernel() async {
        KernelManager.shared.onUnexpectedStop = nil
        SystemProxyManager.shared.disable()
        state.systemProxyEnabled = false
        KernelManager.shared.stop()
        state.isRunning = false
        state.uploadSpeed = "↑ 0 B/s"
        state.downloadSpeed = "↓ 0 B/s"
    }

    func startTrafficMonitor() {
        let appState = state
        Task {
            while appState.isRunning {
                let cfg = appState.apiConfig
                let api = MihomoAPI(baseURL: cfg.baseURL, secret: cfg.secret)
                for await traffic in api.trafficStream() {
                    guard appState.isRunning else { return }
                    appState.uploadSpeed = "↑ \(formatBytes(traffic.upload))/s"
                    appState.downloadSpeed = "↓ \(formatBytes(traffic.download))/s"
                }
                guard appState.isRunning else { return }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func refreshConfigs() {
        state.configs = ConfigManager.shared.scan(folderPath: state.configFolderPath)
        if !state.configs.contains(where: { $0.path == state.activeConfigPath }),
           let first = state.configs.first {
            state.activeConfigPath = first.path
        }
    }

}
