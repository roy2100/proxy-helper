# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目简介

ProxyHelper 是一个 macOS 菜单栏应用，控制本地 mihomo 内核的启动与停止，并自动设置/清除系统 HTTP/SOCKS 代理。纯菜单栏，无 Dock 图标，不打包内核，依赖用户通过 Homebrew 安装 mihomo。

- **语言**：Swift 6（strict concurrency，全程 `@MainActor`）
- **UI**：SwiftUI + `MenuBarExtra(.menu)`
- **最低系统**：macOS 26 Tahoe
- **沙盒**：关闭（`com.apple.security.app-sandbox = false`）

## 构建与测试

```bash
# 构建（命令行）
xcodebuild -project ProxyHelper.xcodeproj -scheme ProxyHelper -configuration Debug build

# 运行全部测试
xcodebuild -project ProxyHelper.xcodeproj -scheme ProxyHelper -destination 'platform=macOS' test

# 运行单个测试 Suite
xcodebuild -project ProxyHelper.xcodeproj -scheme ProxyHelper -destination 'platform=macOS' test -only-testing:ProxyHelperTests/FormatBytesTests
```

日常开发直接在 Xcode 中 `⌘R` 运行，`⌘U` 跑测试。

## 架构

### 数据流

```
AppState（@Observable, @MainActor）
  ├── KernelManager.shared  — 管理 mihomo 子进程生命周期
  ├── ConfigManager.shared  — 扫描/监听配置文件夹，解析配置字段
  ├── MihomoAPI             — REST 客户端（健康检查、配置热更新）
  └── SystemProxyManager    — 通过 networksetup 设置/清除系统代理
```

所有单例和 `AppState` 均标注 `@MainActor`，UI 层通过 `.environment(appState)` 获取状态。

### @Observable + @Environment 使用规则

**读取状态**：在视图 `body` 里直接访问 `state.someProperty`，SwiftUI 会自动追踪依赖并在属性变更时重新渲染。

**双向绑定**：需要写入时，在 `body` 顶部声明 `@Bindable var state = state`，再用 `$state.someProperty`。

**UserDefaults 持久化属性必须用存储属性 + `didSet`**，不能用 `@ObservationIgnored` 计算属性。计算属性绕过了 `@Observable` 的追踪机制，SwiftUI 永远不知道它变了，UI 不会刷新。正确范式（参考 `activeConfigPath`、`configFolderPath`）：

```swift
// ✅ 正确：存储属性 + didSet，@Observable 自动追踪，UI 随时响应
var configFolderPath: String = UserDefaults.standard.string(forKey: "configFolderPath") ?? "" {
    didSet { UserDefaults.standard.set(configFolderPath, forKey: "configFolderPath") }
}

// ❌ 错误：@ObservationIgnored 计算属性，SwiftUI 不追踪，UI 不刷新
@ObservationIgnored
var configFolderPath: String {
    get { UserDefaults.standard.string(forKey: "configFolderPath") ?? "" }
    set { UserDefaults.standard.set(newValue, forKey: "configFolderPath") }
}
```

新增需要持久化到 UserDefaults 的属性时，一律使用存储属性 + `didSet` 写法。

### 启动/停止流程

**启动**：`KernelManager.start()` → `MihomoAPI.waitUntilReady()` 轮询 `/version` → `SystemProxyManager.enable()` → 更新 `appState.isRunning = true`

**停止**：必须先 `SystemProxyManager.disable()` 再 `KernelManager.stop()`，顺序不能颠倒，否则代理指向已关闭端口导致断网。

**孤儿进程处理**：`KernelManager` 在 `UserDefaults` 里持久化最后一个 mihomo 的 PID（key: `lastMihomoProxyPID`），init 时 SIGKILL 掉它，防止 app crash 后遗留进程占端口。

### mihomo API 连接参数

`AppState.apiConfig` 计算属性从当前激活配置文件里解析 `external-controller`（取端口，主机固定用 `127.0.0.1`）和 `secret` 字段，返回 `(baseURL: String, secret: String)`。所有 `MihomoAPI` 实例都从这里取参数，不硬编码。解析逻辑在 `ConfigManager.parseAPIConfig(at:)`，缺失时回退到端口 9090。

`AppState.proxyPorts` 从当前激活配置文件里解析系统代理端口：`mixed-port` 存在时 HTTP/SOCKS 都使用它；否则 HTTP 使用 `port`（默认 7890），SOCKS 使用 `socks-port`（默认 7891）。设置页不再提供手动代理端口配置。

### 配置文件

`config.yaml`（仓库根目录）是 **mihomo 的示例配置文件**，不是 ProxyHelper 自身的配置，供用户参考。

### `.menu` 样式限制

`MenuBarExtra` 使用 `.menu` 样式时，`Button` 渲染为原生菜单项，普通 `Text`/`VStack` 渲染为不可点击的自定义视图区域。速率显示等复杂布局放在顶部的 `statusBlock` 自定义视图块里，配置列表和控制按钮用原生 `Button`。

### 系统代理

通过 `/usr/sbin/networksetup` 命令行工具操作，优先选 Wi-Fi 网络服务。只影响遵守系统代理的应用（Safari、curl 等），不支持 TUN 模式（列为后续扩展点）。

## mihomo REST API 参考

认证：若配置了 `secret`，所有请求需带 `Authorization: Bearer <secret>` 头。  
WebSocket 端点用 `ws://` 替换 `http://`，路径相同。

### 当前已用端点

| 端点 | 方法 | 用途 |
|------|------|------|
| `GET /version` | HTTP | 健康检查，内核就绪探针 |
| `PATCH /configs` | HTTP | 运行时热更新（当前用于 TUN 启停） |

### 可扩展端点

**配置**
- `GET /configs` — 获取当前配置
- `PATCH /configs` — 热更新部分配置，如 `{"mixed-port": 7890}`
- `PUT /configs?force=true` — 强制重载配置文件
- `POST /restart` — 重启内核

**代理/策略组**
- `GET /proxies` — 获取所有代理节点
- `GET /proxies/{name}` — 获取单个节点信息
- `PUT /proxies/{name}` — 切换策略组选中节点，body `{"name": "节点名"}`
- `GET /proxies/{name}/delay?url=<url>&timeout=5000` — 测速
- `GET /group` / `GET /group/{name}` — 策略组列表/详情
- `DELETE /group/{name}` — 清除策略组选择
- `GET /group/{name}/delay?url=<url>&timeout=5000` — 策略组批量测速

**连接**
- `GET /connections` 或 `WS /connections?interval=<ms>` — 实时连接列表
- `DELETE /connections` — 关闭所有连接
- `DELETE /connections/:id` — 关闭单个连接

**日志**
- `WS /logs?level=info|warning|error|debug` — 实时日志流

**内存**
- `WS /memory` — 实时内存用量（kb）

**DNS**
- `GET /dns/query?name=<domain>&type=<record>` — DNS 查询
- `POST /cache/dns/flush` — 清除 DNS 缓存
- `POST /cache/fakeip/flush` — 清除 Fake IP 缓存

**Providers（订阅/规则集）**
- `GET /providers/proxies` — 代理 provider 列表
- `PUT /providers/proxies/{name}` — 更新指定 provider
- `GET /providers/rules` — 规则集列表
- `PUT /providers/rules/{name}` — 更新规则集

**更新**
- `POST /upgrade` — 更新内核
- `POST /upgrade/ui` — 更新 UI
- `POST /upgrade/geo` — 更新 GEO 数据库
- `POST /configs/geo` — 指定路径更新 GEO，body `{"path": "", "payload": ""}`

**调试**
- `PUT /debug/gc` — 触发 GC
- `/debug/pprof` — 性能分析（需 debug 日志级别）

## [Zashboard](http://board.zash.run.place/) URL params format

#### basic example

http://host:port/#/setup?hostname=ipordomain&port=9090&secret=123456

1. **`http` / `https`**
   - Determines the protocol (`http` or `https`).
   - Default: current page protocol

2. **`hostname`**
   - The Clash API's IP or domain.

3. **`port`**
   - The Clash API port.

4. **`secondaryPath`**
   - Optional path appended to the base URL.
   - Default: An empty string.

5. **`secret`**
   - Password for authentication.

6. **`disableUpgradeCore`**
   - Set '1' to hide upgrade core button

7. **`disableTunMode`**
   - Set '1' to hide tun switch

## 开发原则

**不要修改用户的配置文件。** ProxyHelper 将配置文件目录直接透传给 mihomo（`-d <config_dir>`），由 mihomo 原生加载，不做任何预处理或注入。对配置文件的唯一操作是只读（扫描文件列表、解析 `external-controller`/`secret` 用于 API 连接），不得写入、覆盖或修改用户的 `.yaml`/`.yml` 文件。

## 关键设计决策

- 切换配置时采用 **`PUT /configs?force=true` 热重载**而非重启内核，因为所有配置都在同一文件夹下，热重载可靠且没有端口释放的竞争。仅当用户在设置里改变配置文件夹（跨目录）时才走重启路径。
- 崩溃自动重启最多 3 次（`maxRestarts`），仅在非正常退出（`terminationStatus != 0`）时触发。
- 系统代理端口直接从当前 mihomo 配置读取，避免手动设置与配置文件不一致。
- **所有阻止启动的信息集中在菜单"状态"区块展示**，不分散到其他区块。pre-flight 原因（未找到配置文件、未选择配置）通过 `AppState.startBlockReason` 计算属性返回，运行时错误写入 `AppState.errorMessage`，两者都渲染在状态区。"配置文件"区块只负责操作（选择文件），不承担提示职责。新增报错场景应遵循同一规则，写入这两个字段之一，而非在其他区块添加 `Text`。
