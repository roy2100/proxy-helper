import SwiftUI

struct MenuView: View {
    @Environment(AppState.self) var state
    @Environment(\.openWindow) var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── 状态 ──────────────────────────────────────────
            MenuSectionHeader("状态")
            MenuLabel(state.isStarting ? "启动中..." : state.isStopping ? "停止中..." : state.isRunning ? "运行中" : "已停止")

            if state.isRunning {
                MenuRow(proxyPortSummary) { copyProxyAddress() }
                if let version = state.kernelVersion {
                    MenuRow("内核：\(version)") { revealMihomoBinary() }
                }
            }
            if let err = state.errorMessage {
                MenuRow(err, destructive: true) {
                    openWindow(id: "logs")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            if state.isRunning || state.isStopping {
                MenuRow("停止", disabled: state.isStopping) { Task { await stopKernel() } }
            } else {
                MenuRow("启动", disabled: state.activeConfigPath.isEmpty || state.isStarting) { Task { await startKernel() } }
            }

            MenuDivider()

            // ── 配置文件 ───────────────────────────────────────
            if state.configs.isEmpty {
                MenuLabel("未找到配置文件")
            } else {
                ForEach(state.configs) { config in
                    MenuRow(config.name, checkmark: config.path == state.activeConfigPath) {
                        Task { await switchTo(config) }
                    }
                }
            }

            MenuDivider()

            // ── TUN ────────────────────────────────────────────
            MenuRow("TUN 模式", checkmark: state.tunEnabled) { Task { await toggleTun() } }
            MenuRow("复制启用 TUN 命令") { copyEnableTunCommand() }

            MenuDivider()

            // ── 工具 ───────────────────────────────────────────
            MenuRow("打开配置文件夹", disabled: state.configFolderPath.isEmpty) {
                guard !state.configFolderPath.isEmpty else { return }
                NSWorkspace.shared.open(URL(fileURLWithPath: state.configFolderPath))
            }
            MenuRow("打开数据文件夹") { NSWorkspace.shared.open(KernelManager.mihomoHome) }
            MenuRow("Dashboard", disabled: !state.isRunning) { NSWorkspace.shared.open(DashboardURL.homepage) }
            MenuRow("日志...") {
                openWindow(id: "logs")
                NSApp.activate(ignoringOtherApps: true)
            }
            MenuRow("设置...") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",", modifiers: .command)

            MenuDivider()

            MenuRow("退出") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(4)
        .frame(width: 280)
        .containerBackground(.ultraThinMaterial, for: .window)
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
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("127.0.0.1:\(ports.http)", forType: .string)
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

    private var proxyPortSummary: String {
        let ports = state.proxyPorts
        if ports.http == ports.socks {
            return "混合代理：127.0.0.1:\(ports.http)"
        }
        return "HTTP 代理：127.0.0.1:\(ports.http)  SOCKS：\(ports.socks)"
    }
}

// MARK: - Helper Views

private struct MenuSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MenuLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MenuRow: View {
    let title: String
    var checkmark: Bool = false
    var disabled: Bool = false
    var destructive: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    init(_ title: String, checkmark: Bool = false, disabled: Bool = false, destructive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.checkmark = checkmark
        self.disabled = disabled
        self.destructive = destructive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(checkmark ? 1 : 0)
                    .frame(width: 14)
                Text(title)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            (isHovered && !disabled) ? Color.white :
            destructive ? Color.red :
            Color.primary
        )
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovered && !disabled ? Color.accentColor : Color.clear)
        )
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .onHover { h in
            withAnimation(.easeInOut(duration: 0.08)) { isHovered = h }
        }
    }
}

private struct MenuDivider: View {
    var body: some View {
        Divider().padding(.vertical, 4)
    }
}
