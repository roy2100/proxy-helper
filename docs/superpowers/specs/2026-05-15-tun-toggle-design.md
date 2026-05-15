# TUN 模式开关设计

日期：2026-05-15
状态：已批准，待实现

## 背景与目标

在 ProxyHelper 菜单栏下拉菜单中新增"TUN 模式"开关。开启后通过 mihomo REST API `PATCH /configs` 向运行中的内核热注入 `tun.enable: true`，使所有应用（包括不遵守系统代理的命令行工具）走代理。

## 范围与非目标

**范围**
- 全局开关，跨配置生效（不与具体 yaml 文件绑定）
- 状态持久化（重启 app 后保留）
- 仅运行时生效，不修改 yaml 文件
- 提供一次性 setuid 脚本帮助 mihomo 获取 TUN 所需权限

**非目标**
- 不在 app 内做提权（osascript / SMAppService / helper tool）
- 不修改用户 yaml 文件
- 不实现 TUN 子选项（stack、mtu、auto-route 等），全部由 yaml 自身决定
- 不自动检测 mihomo 二进制是否已设 setuid 位

## 用户故事

1. 用户点击菜单"TUN 模式"，状态切换并显示勾选；如果内核运行中，TUN 立即生效
2. 用户开启 TUN 后切换配置或重启内核，TUN 状态自动保持
3. mihomo 未以 root 运行导致 TUN 启用失败，菜单顶部显示错误信息，开关 UI 不回滚

## 架构与改动点

### AppState (`ProxyHelper/AppState.swift`)
新增持久化字段：
```swift
var tunEnabled: Bool = UserDefaults.standard.bool(forKey: "tunEnabled") {
    didSet { UserDefaults.standard.set(tunEnabled, forKey: "tunEnabled") }
}
```
默认 `false`。受 `@Observable` 追踪（非 `@ObservationIgnored`），保证菜单视图自动重渲染。

### MihomoAPI (`ProxyHelper/MihomoAPI.swift`)
新增方法：
```swift
func patchConfigs(_ body: [String: Any]) async throws
```
- 构造 `PATCH \(baseURL)/configs`，`Content-Type: application/json`，带 `Authorization: Bearer <secret>` 头
- body 用 `JSONSerialization` 编码
- 非 2xx 抛错，错误信息含 HTTP 状态码 + 响应体片段

### MenuView (`ProxyHelper/MenuView.swift`)
在"启动/停止"按钮所在 `Divider()` 上方新增菜单项：
```swift
Button {
    Task { await toggleTun() }
} label: {
    if state.tunEnabled {
        Label("TUN 模式", systemImage: "checkmark")
    } else {
        Text("TUN 模式")
    }
}
```
新增方法 `toggleTun()`：
1. 翻转 `state.tunEnabled`
2. 若 `state.isRunning`，调用 `MihomoAPI.patchConfigs(["tun": ["enable": state.tunEnabled]])`
3. 失败时设置 `state.errorMessage`，**不回滚** `state.tunEnabled`

### 启动 / 切换配置时的注入

修改 `MenuView.startKernel()` 与 `ConfigManager.switchConfig(...)`：在 `api.waitUntilReady()` 返回 true 之后、`SystemProxyManager.enable(...)` 之前，若 `state.tunEnabled`，调用 `patchConfigs(["tun": ["enable": true]])`。失败仅记录 `errorMessage`，不中止启动流程。

### 一次性脚本 `scripts/enable-tun.sh`
```bash
#!/bin/bash
set -e
MIHOMO=$(command -v mihomo || echo "/opt/homebrew/bin/mihomo")
if [ ! -x "$MIHOMO" ]; then
  echo "mihomo not found" >&2
  exit 1
fi
sudo chown root:wheel "$MIHOMO"
sudo chmod u+s "$MIHOMO"
echo "Done. mihomo at $MIHOMO now runs as root."
```
README 加一段说明：用户开启 TUN 模式前需先跑一次此脚本；`brew upgrade mihomo` 后需重新执行。

## 数据流

```
菜单点击
  → MenuView.toggleTun()
  → state.tunEnabled 翻转（持久化到 UserDefaults）
  → if 运行中: MihomoAPI.patchConfigs({"tun": {"enable": <new>}})
       success → 内核创建/销毁 utun 接口
       failure → state.errorMessage 显示

启动 / 切换配置
  → KernelManager.start()
  → api.waitUntilReady()
  → if state.tunEnabled: patchConfigs({"tun": {"enable": true}})
  → SystemProxyManager.enable(...)
```

## 错误处理

| 场景 | 行为 |
|------|------|
| PATCH 网络失败 | `errorMessage = "TUN 切换失败：<error>"`，开关 UI 不回滚 |
| PATCH 返回非 2xx | 同上，错误信息含状态码 |
| 内核未以 root 运行，TUN 启用 | mihomo 通常返回错误码，走上面分支 |
| 切换配置时注入失败 | 启动流程继续完成（系统代理仍生效），errorMessage 提示 |

## 测试策略

- 不新增单元测试（PATCH 涉及网络，运行时行为）
- 手动验收清单：
  1. 跑过 `scripts/enable-tun.sh` 后启动 mihomo，菜单点 TUN，`ifconfig | grep utun` 出现新接口
  2. 关闭 TUN，接口消失
  3. TUN 开启状态下切换配置，新配置上 TUN 仍生效
  4. 退出 app 再启动，TUN 状态保留
  5. 未跑 setuid 脚本时打开 TUN，菜单显示错误

## 风险

- **mihomo 版本对 PATCH /configs tun 字段支持差异**：旧版 mihomo 可能忽略 tun 段的热更新。验收测试需在用户当前版本上确认。
- **setuid binary 安全性**：给 mihomo 设 setuid 后任何用户都能以 root 跑它。本仓库是单用户开发机场景，可接受。需在 README 明示风险。
- **brew upgrade 失效**：升级 mihomo 后 setuid 位被覆盖。README 说明需重跑脚本。
