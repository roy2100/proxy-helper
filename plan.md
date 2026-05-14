# ProxyHelper — Claude Code 实现规范

## 项目概述

一个极简的 macOS 菜单栏应用，负责控制本地已安装的 mihomo 内核的启动与停止，使用 HTTP 代理模式（非 TUN），启动/停止时自动设置/清除 macOS 系统代理，无主窗口，所有交互在菜单栏完成。TUN 模式留待后续版本实现。

---

## 技术约束

- **语言**：Swift 6（strict concurrency）
- **UI**：SwiftUI + MenuBarExtra
- **最低系统**：macOS 26 Tahoe
- **沙盒**：关闭（entitlements 中 `com.apple.security.app-sandbox` = false）
- **不打包内核**：mihomo 由用户自行通过 Homebrew 安装
- **不上 App Store**

---

## 项目结构

```
ProxyHelper/
├── ProxyHelper.xcodeproj
├── ProxyHelper/
│   ├── ProxyHelperApp.swift          # App 入口，MenuBarExtra
│   ├── MenuView.swift              # 菜单栏展开的 SwiftUI 视图
│   ├── KernelManager.swift         # 内核进程管理（核心）
│   ├── MihomoAPI.swift             # REST API 客户端
│   ├── ConfigManager.swift         # 配置文件夹扫描与切换
│   ├── SystemProxyManager.swift    # 系统代理设置/清除（HTTP/SOCKS）
│   ├── AppState.swift              # 全局状态 @Observable
│   └── SettingsView.swift          # 设置页（mihomo 路径、配置文件夹路径）
├── ProxyHelper.entitlements
└── CLAUDE.md                       # 本文件
```

---

## 入口：ProxyHelperApp.swift

```swift
import SwiftUI

@main
struct ProxyHelperApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(appState)
        } label: {
            Image(systemName: appState.isRunning ? "circle.fill" : "circle")
        }
        // .menu 样式：原生菜单外观，macOS 26 自动获得 Liquid Glass，无需额外代码
        .menuBarExtraStyle(.menu)

        Window("设置", id: "settings") {
            SettingsView()
                .environment(appState)
        }
        .windowResizability(.contentSize)
    }
}
```

---

## 全局状态：AppState.swift

```swift
import SwiftUI
import Observation

@Observable
final class AppState {
    var isRunning: Bool = false
    var systemProxyEnabled: Bool = false   // 系统代理当前是否已设置
    var uploadSpeed: String = "↑ 0 B/s"
    var downloadSpeed: String = "↓ 0 B/s"
    var errorMessage: String? = nil

    // 当前扫描到的配置文件列表（由 ConfigManager 维护）
    var configs: [ConfigFile] = []

    // 当前激活的配置文件路径（持久化）
    var activeConfigPath: String {
        get { UserDefaults.standard.string(forKey: "activeConfigPath") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "activeConfigPath") }
    }

    // mihomo 二进制路径（持久化，留空则自动检测）
    @ObservationIgnored
    var mihomoPath: String {
        get { UserDefaults.standard.string(forKey: "mihomoPath") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "mihomoPath") }
    }

    // 配置文件夹路径（扫描该目录下所有 .yaml/.yml 文件）
    @ObservationIgnored
    var configFolderPath: String {
        get { UserDefaults.standard.string(forKey: "configFolderPath") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "configFolderPath") }
    }

    // HTTP 代理端口（默认 7890，与 mihomo 默认一致）
    // 用户可在设置中覆盖，需与 config.yaml 中的 port 字段保持一致
    @ObservationIgnored
    var httpPort: Int {
        get { UserDefaults.standard.integer(forKey: "httpPort").nonZero ?? 7890 }
        set { UserDefaults.standard.set(newValue, forKey: "httpPort") }
    }

    // SOCKS 代理端口（默认 7891）
    @ObservationIgnored
    var socksPort: Int {
        get { UserDefaults.standard.integer(forKey: "socksPort").nonZero ?? 7891 }
        set { UserDefaults.standard.set(newValue, forKey: "socksPort") }
    }

    // 有效的 mihomo 路径
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
}

// Int 扩展：0 视为未设置
private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

// 代表一个配置文件
struct ConfigFile: Identifiable, Hashable {
    let id = UUID()
    let path: String
    let name: String
    let modifiedAt: Date

    static func == (lhs: ConfigFile, rhs: ConfigFile) -> Bool { lhs.path == rhs.path }
    func hash(into hasher: inout Hasher) { hasher.combine(path) }
}
```

---

## 内核管理：KernelManager.swift

### 职责
- 启动 mihomo 子进程
- 监控进程存活，崩溃后自动重启（最多 3 次）
- 停止进程（SIGTERM → 等待 2s → SIGKILL）
- 通过 Pipe 捕获日志

### 实现要点

```swift
import Foundation

@MainActor
final class KernelManager {
    static let shared = KernelManager()
    private var process: Process?
    private var logPipe: Pipe?
    private var restartCount = 0
    private let maxRestarts = 3

    func start(mihomoPath: String, configPath: String) throws {
        guard !mihomoPath.isEmpty else {
            throw KernelError.binaryNotFound
        }
        guard FileManager.default.isExecutableFile(atPath: mihomoPath) else {
            throw KernelError.binaryNotExecutable(path: mihomoPath)
        }
        guard FileManager.default.fileExists(atPath: configPath) else {
            throw KernelError.configNotFound(path: configPath)
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: mihomoPath)
        // mihomo 用 -d 指定工作目录（config.yaml 所在目录）
        p.arguments = ["-d", URL(fileURLWithPath: configPath)
                                .deletingLastPathComponent().path]

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        self.logPipe = pipe

        p.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                self?.handleTermination(proc, mihomoPath: mihomoPath, configPath: configPath)
            }
        }

        try p.run()
        self.process = p
        restartCount = 0
    }

    func stop() {
        guard let p = process, p.isRunning else { return }
        p.terminate()
        // 2 秒后若还在，强杀
        Task {
            try? await Task.sleep(for: .seconds(2))
            if p.isRunning { p.interrupt() }
        }
        process = nil
    }

    private func handleTermination(_ proc: Process, mihomoPath: String, configPath: String) {
        // 非正常退出且未超过重启次数
        if proc.terminationReason == .exit && proc.terminationStatus != 0 {
            if restartCount < maxRestarts {
                restartCount += 1
                try? start(mihomoPath: mihomoPath, configPath: configPath)
            }
        }
    }
}

enum KernelError: LocalizedError {
    case binaryNotFound
    case binaryNotExecutable(path: String)
    case configNotFound(path: String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "未找到 mihomo，请先执行 brew install mihomo"
        case .binaryNotExecutable(let path):
            return "文件不可执行：\(path)"
        case .configNotFound(let path):
            return "配置文件不存在：\(path)"
        }
    }
}
```

---

## 配置管理：ConfigManager.swift

### 职责
- 扫描指定文件夹，枚举所有 `.yaml` / `.yml` 文件
- 用 `DispatchSource`（FSEvents）监听文件夹变化，自动刷新列表
- 提供切换配置的方法：运行中时通过 mihomo API 热重载，未运行时仅更新 activeConfigPath

```swift
import Foundation

@MainActor
final class ConfigManager {
    static let shared = ConfigManager()
    private var folderMonitor: DispatchSourceFileSystemObject?
    private var monitoredFolderFD: Int32 = -1

    // 扫描文件夹，返回按修改时间倒序排列的配置文件列表
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

    // 开始监听文件夹变化（新增/删除/重命名 yaml 文件时自动刷新）
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

    // 切换配置：
    // - 内核未运行 → 仅更新 activeConfigPath
    // - 内核运行中 → 先停止，更新路径，再重新启动
    //   （mihomo 的 PATCH /configs 热重载要求新旧 config 在同一目录，
    //    跨目录切换最稳妥的做法是重启内核）
    func switchConfig(
        to config: ConfigFile,
        appState: AppState,
        restart: Bool = true
    ) async {
        appState.activeConfigPath = config.path

        guard appState.isRunning && restart else { return }

        // 先清系统代理再停内核
        SystemProxyManager.shared.disable()
        appState.systemProxyEnabled = false
        KernelManager.shared.stop()
        appState.isRunning = false

        try? await Task.sleep(for: .milliseconds(500))

        do {
            try KernelManager.shared.start(
                mihomoPath: appState.effectiveMihomoPath,
                configPath: config.path
            )
            let api = MihomoAPI(baseURL: "http://127.0.0.1:9090", secret: "")
            let ready = await api.waitUntilReady()
            guard ready else {
                appState.errorMessage = "切换配置后内核启动超时"
                return
            }
            SystemProxyManager.shared.enable(
                httpPort: appState.httpPort,
                socksPort: appState.socksPort
            )
            appState.isRunning = true
            appState.systemProxyEnabled = true
            appState.errorMessage = nil
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }
}
```

---

## API 客户端：MihomoAPI.swift

### 职责
- 健康检查（GET /version）：确认内核已就绪
- 实时流量（WebSocket /traffic）：更新速率显示

```swift
import Foundation

struct MihomoAPI {
    let baseURL: String
    let secret: String

    // 内核启动后 API 不是立即可用的，需要轮询等待
    func waitUntilReady(timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await checkHealth() { return true }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return false
    }

    func checkHealth() async -> Bool {
        guard let url = URL(string: "\(baseURL)/version") else { return false }
        var req = URLRequest(url: url, timeoutInterval: 2)
        if !secret.isEmpty {
            req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        return (try? await URLSession.shared.data(for: req)) != nil
    }

    // 返回 AsyncStream<(upload: Int64, download: Int64)>
    func trafficStream() -> AsyncStream<(upload: Int64, download: Int64)> {
        AsyncStream { continuation in
            guard let url = URL(string: baseURL.replacingOccurrences(of: "http", with: "ws") + "/traffic") else {
                continuation.finish()
                return
            }
            var req = URLRequest(url: url)
            if !secret.isEmpty {
                req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            }
            let task = URLSession.shared.webSocketTask(with: req)
            task.resume()

            Task {
                while true {
                    guard let msg = try? await task.receive() else { break }
                    if case .string(let text) = msg,
                       let data = text.data(using: .utf8),
                       let json = try? JSONDecoder().decode(TrafficData.self, from: data) {
                        continuation.yield((json.up, json.down))
                    }
                }
                continuation.finish()
            }
        }
    }
}

struct TrafficData: Decodable {
    let up: Int64
    let down: Int64
}
```

---

## 菜单视图：MenuView.swift

### 渲染方式

`.menu` 样式下，`MenuBarExtra` 的内容被渲染为原生 `NSMenu`。SwiftUI 的规则：

- `Button` → 标准菜单项（可点击，高亮，macOS 26 自动 Liquid Glass）
- `Divider` → 分割线
- `Menu("label") { ... }` → 带箭头的子菜单
- 普通 `Text`、`VStack` 等非交互视图 → 渲染为不可点击的自定义视图区域（内嵌 `NSMenuItem` 的 `view` 属性）

顶部状态区用自定义视图块，下方配置列表和控制按钮用原生 `Button`，天然获得 Liquid Glass 外观。

### 布局结构

```
┌─────────────────────────────┐  ← 自定义视图区（不可点击）
│  ● 运行中                   │
│  ↑ 1.2 MB/s   ↓ 3.4 MB/s   │
│  HTTP 代理：127.0.0.1:7890  │
│  ⚠️ 错误信息（有错时显示）    │
├─────────────────────────────┤
│  ✓ home                     │  ← Button（可点击，Liquid Glass）
│    office                   │
│    test                     │
├─────────────────────────────┤
│  启动 / 停止                 │
├─────────────────────────────┤
│  设置...                    │
│  退出                       │
└─────────────────────────────┘
```

### 实现

```swift
import SwiftUI

struct MenuView: View {
    @Environment(AppState.self) var state
    @Environment(\.openWindow) var openWindow

    var body: some View {
        // ── 顶部状态区（自定义视图，不可点击）──
        statusBlock

        Divider()

        // ── 配置列表（原生 Button，Liquid Glass）──
        if state.configs.isEmpty {
            // 用 Text 包一个提示，不可点击
            Text("未找到配置文件")
                .foregroundStyle(.secondary)
        } else {
            ForEach(state.configs) { config in
                Button {
                    Task { await switchTo(config) }
                } label: {
                    // checkmark 表示当前激活配置
                    Label(
                        config.name,
                        systemImage: config.path == state.activeConfigPath ? "checkmark" : ""
                    )
                }
            }
        }

        Divider()

        // ── 控制 ──
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

    // 顶部自定义视图块：不可点击，仅展示状态
    @ViewBuilder
    var statusBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(state.isRunning ? .green : .secondary)
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

                Text("HTTP 代理：127.0.0.1:\(state.httpPort)")
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
        // 固定宽度让菜单不因内容变化而跳动
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
```

### `.menu` 样式的限制

- `Button` 的 label 只能是文字或 `Label`，复杂自定义布局（如双列速率）放在顶部自定义视图块里
- 不支持 `keyboardShortcut` 以外的交互修饰符
- 列表项过多时系统自动加滚动，不需要手动处理

---

## 设置页：SettingsView.swift

```swift
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) var state
    @State private var httpPortText: String = ""
    @State private var socksPortText: String = ""

    var body: some View {
        @Bindable var state = state
        Form {
            Section("mihomo 路径") {
                HStack {
                    TextField("留空则自动检测 Homebrew 路径", text: $state.mihomoPath)
                    Button("选择...") { pickFile(binding: $state.mihomoPath) }
                }
                Text("当前：\(state.effectiveMihomoPath.isEmpty ? "未找到，请先 brew install mihomo" : state.effectiveMihomoPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("配置文件夹") {
                HStack {
                    TextField("存放 .yaml 配置文件的目录", text: $state.configFolderPath)
                    Button("选择...") { pickFolder(binding: $state.configFolderPath) }
                }
                Text("应用会自动扫描该目录下所有 .yaml / .yml 文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !state.configFolderPath.isEmpty {
                    let configs = ConfigManager.shared.scan(folderPath: state.configFolderPath)
                    if configs.isEmpty {
                        Text("未找到配置文件").font(.caption).foregroundStyle(.red)
                    } else {
                        ForEach(configs) { c in
                            HStack {
                                Image(systemName: "doc.text").foregroundStyle(.secondary)
                                Text(c.name).font(.caption)
                                Spacer()
                                Text(c.modifiedAt, style: .relative)
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }

            Section("代理端口") {
                HStack {
                    Text("HTTP 端口")
                    Spacer()
                    TextField("7890", text: $httpPortText)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { savePort() }
                }
                HStack {
                    Text("SOCKS 端口")
                    Spacer()
                    TextField("7891", text: $socksPortText)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { savePort() }
                }
                Text("需与 config.yaml 中的 port / socks-port 字段保持一致")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 500)
        .onAppear {
            httpPortText = "\(state.httpPort)"
            socksPortText = "\(state.socksPort)"
            if !state.configFolderPath.isEmpty {
                ConfigManager.shared.startWatching(folderPath: state.configFolderPath) {
                    state.configs = ConfigManager.shared.scan(folderPath: state.configFolderPath)
                }
            }
        }
        .onChange(of: state.configFolderPath) {
            state.configs = ConfigManager.shared.scan(folderPath: state.configFolderPath)
            ConfigManager.shared.startWatching(folderPath: state.configFolderPath) {
                state.configs = ConfigManager.shared.scan(folderPath: state.configFolderPath)
            }
        }
    }

    func savePort() {
        if let p = Int(httpPortText), (1...65535).contains(p) { state.httpPort = p }
        if let p = Int(socksPortText), (1...65535).contains(p) { state.socksPort = p }
    }

    func pickFile(binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { binding.wrappedValue = panel.url?.path ?? "" }
    }

    func pickFolder(binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "选择文件夹"
        if panel.runModal() == .OK { binding.wrappedValue = panel.url?.path ?? "" }
    }
}
```

---

## Entitlements：ProxyHelper.entitlements

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- 关闭沙盒，允许启动任意子进程 -->
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <!-- 允许出站网络连接（访问 mihomo API） -->
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
```

---

## Info.plist 补充

```xml
<!-- 不在 Dock 显示，纯菜单栏 app -->
<key>LSUIElement</key>
<true/>
```

---

## 依赖

**零外部依赖**，全部使用系统框架：
- `Foundation`（Process、URLSession、WebSocket）
- `SwiftUI`（MenuBarExtra、Window、Form）

---

## 系统代理管理：SystemProxyManager.swift

### 职责
- 内核启动成功后，调用 `networksetup` 命令行工具设置系统 HTTP/SOCKS 代理
- 内核停止时清除系统代理
- 读取当前系统代理状态用于 UI 显示

macOS 提供两种方式设置系统代理：`SystemConfiguration` framework（需要授权）和 `networksetup` 命令行工具（无需 root，但需要当前用户对网络服务有写权限）。这里选用 `networksetup`，更简单且对普通用户透明。

```swift
import Foundation

@MainActor
final class SystemProxyManager {
    static let shared = SystemProxyManager()

    // 获取当前活跃的网络服务名（通常是 "Wi-Fi" 或 "Ethernet"）
    // networksetup -listallnetworkservices 输出第一行是提示，从第二行起是服务名
    private func activeNetworkService() -> String? {
        let output = shell("networksetup", "-listallnetworkservices")
        let lines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("An asterisk") && !$0.hasPrefix("*") }
        // 优先返回 Wi-Fi，其次第一个
        return lines.first { $0 == "Wi-Fi" } ?? lines.first
    }

    /// 设置系统 HTTP + SOCKS 代理
    func enable(httpPort: Int, socksPort: Int) {
        guard let service = activeNetworkService() else { return }
        shell("networksetup", "-setwebproxy", service, "127.0.0.1", "\(httpPort)")
        shell("networksetup", "-setsecurewebproxy", service, "127.0.0.1", "\(httpPort)")
        shell("networksetup", "-setsocksfirewallproxy", service, "127.0.0.1", "\(socksPort)")
        shell("networksetup", "-setwebproxystate", service, "on")
        shell("networksetup", "-setsecurewebproxystate", service, "on")
        shell("networksetup", "-setsocksfirewallproxystate", service, "on")
    }

    /// 清除系统 HTTP + SOCKS 代理
    func disable() {
        guard let service = activeNetworkService() else { return }
        shell("networksetup", "-setwebproxystate", service, "off")
        shell("networksetup", "-setsecurewebproxystate", service, "off")
        shell("networksetup", "-setsocksfirewallproxystate", service, "off")
    }

    /// 检查当前系统代理是否指向 127.0.0.1
    func isEnabled(httpPort: Int) -> Bool {
        guard let service = activeNetworkService() else { return false }
        let output = shell("networksetup", "-getwebproxy", service)
        return output.contains("127.0.0.1") && output.contains("\(httpPort)")
            && output.contains("Enabled: Yes")
    }

    @discardableResult
    private func shell(_ args: String...) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = Array(args.dropFirst())  // 第一个参数是命令名
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
```

**注意**：`networksetup` 只影响"系统代理"设置（影响 Safari、curl 等遵守系统代理的应用）。不遵守系统代理的应用（如部分 Electron app、游戏）不受影响，这是 HTTP 代理模式的固有限制，TUN 模式才能解决。

---

## 启动/停止完整流程

```
启动：
  KernelManager.start()
    → 等待 API 就绪（MihomoAPI.waitUntilReady）
    → SystemProxyManager.enable(httpPort, socksPort)
    → 开始流量监控（trafficStream WebSocket）
    → appState.isRunning = true
    → appState.systemProxyEnabled = true

停止：
  SystemProxyManager.disable()
    → KernelManager.stop()
    → appState.isRunning = false
    → appState.systemProxyEnabled = false
```

系统代理必须在内核停止**之前**清除，否则代理还指向一个已关闭的端口，用户会发现网络断掉。

---

## 实现顺序建议

1. `AppState` + `ConfigFile` 模型 + `ProxyHelperApp`（MenuBarExtra 跑起来）
2. `ConfigManager`（scan + FSEvents 监听）
3. `KernelManager`（启动/停止进程）
4. `SystemProxyManager`（networksetup 封装，先单独测试 enable/disable 是否生效）
5. `MenuView`（配置列表 + 启动/停止按钮）
6. `SettingsView`（文件夹选择、端口配置）
7. `MihomoAPI`（健康检查 + 流量 WebSocket）
8. 启动/停止完整流程串联（内核就绪 → 设置代理 → 更新状态）
9. 配置切换（切换时先清代理再重启）
10. 崩溃重启时自动重设系统代理

---

## 不做的事（MVP 范围外）

- 不做 TUN 模式（后续版本）
- 不做订阅管理
- 不做节点切换
- 不做规则编辑
- 不做 Web Dashboard 嵌入
- 不做自动更新
- 不做开机自启（可后续用 `SMAppService.mainApp.register()` 实现）
- 不做配置文件内容编辑

## 后续 TUN 模式扩展点

当需要加 TUN 支持时，改动集中在：
- `AppState` 新增 `proxyMode: ProxyMode` 枚举（`.http` / `.tun`）
- `SystemProxyManager.enable/disable` 在 TUN 模式下跳过（TUN 不需要设系统代理）
- `KernelManager.start` 在 TUN 模式下需要 root 权限，通过 `SMJobBless` privileged helper 处理
- `MenuView` 新增模式切换控件