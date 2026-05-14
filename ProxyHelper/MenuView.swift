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

        Button("设置...") { openWindow(id: "settings") }
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
        do {
            try KernelManager.shared.start(
                mihomoPath: state.effectiveMihomoPath,
                configPath: state.activeConfigPath
            )
            let api = MihomoAPI(baseURL: "http://127.0.0.1:9090", secret: "")
            let ready = await api.waitUntilReady()
            guard ready else {
                state.errorMessage = "内核启动超时"
                KernelManager.shared.stop()
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
            state.errorMessage = error.localizedDescription
        }
    }

    func stopKernel() async {
        SystemProxyManager.shared.disable()
        state.systemProxyEnabled = false
        KernelManager.shared.stop()
        state.isRunning = false
        state.uploadSpeed = "↑ 0 B/s"
        state.downloadSpeed = "↓ 0 B/s"
    }

    func startTrafficMonitor() {
        let api = MihomoAPI(baseURL: "http://127.0.0.1:9090", secret: "")
        Task {
            for await traffic in api.trafficStream() {
                guard state.isRunning else { break }
                state.uploadSpeed = "↑ \(formatBytes(traffic.upload))/s"
                state.downloadSpeed = "↓ \(formatBytes(traffic.download))/s"
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

    func formatBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        let mb = kb / 1024
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        if kb >= 1 { return String(format: "%.0f KB", kb) }
        return "\(bytes) B"
    }
}
