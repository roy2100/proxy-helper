# TUN 模式开关 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在菜单栏新增 TUN 模式开关，通过 mihomo `PATCH /configs` 运行时热注入 `tun.enable`，不修改用户 yaml 文件。

**Architecture:** 新增 `AppState.tunEnabled` 持久化字段；`MihomoAPI` 增加 `patchConfigs` 方法；`MenuView` 增加菜单项，并在 `startKernel` / `switchConfig` 内核就绪后注入。配套提供一次性 `chmod u+s` 脚本帮 mihomo 获取 TUN 权限。

**Tech Stack:** Swift 6（`@MainActor` strict concurrency）、SwiftUI `MenuBarExtra(.menu)`、`URLSession`、`JSONSerialization`、mihomo REST API。

**Spec:** `docs/superpowers/specs/2026-05-15-tun-toggle-design.md`

**测试约束（来自 spec）:** 不新增单元测试。验证靠手动验收清单 + `xcodebuild build` 确保编译通过。

---

### Task 1: MihomoAPI.patchConfigs 方法

**Files:**
- Modify: `ProxyHelper/MihomoAPI.swift`

- [ ] **Step 1: 在 `MihomoAPI` struct 末尾添加 `patchConfigs` 方法**

打开 `ProxyHelper/MihomoAPI.swift`，在 `trafficStream()` 方法之后、struct 闭合括号之前插入：

```swift
    func patchConfigs(_ body: [String: Any]) async throws {
        guard let url = URL(string: "\(baseURL)/configs") else {
            throw MihomoAPIError.invalidURL
        }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !secret.isEmpty {
            req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw MihomoAPIError.badResponse(status: -1, body: "")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw MihomoAPIError.badResponse(status: http.statusCode, body: bodyText)
        }
    }
```

- [ ] **Step 2: 在文件末尾（`TrafficData` 之后）添加错误类型**

在 `private struct TrafficData` 之后追加：

```swift
enum MihomoAPIError: LocalizedError {
    case invalidURL
    case badResponse(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的 API 地址"
        case .badResponse(let status, let body):
            let snippet = body.prefix(200)
            return "API 返回 \(status)：\(snippet)"
        }
    }
}
```

- [ ] **Step 3: 编译验证**

Run: `xcodebuild -project ProxyHelper.xcodeproj -scheme ProxyHelper -configuration Debug build -quiet`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: 提交**

```bash
git add ProxyHelper/MihomoAPI.swift
git commit -m "Add MihomoAPI.patchConfigs for runtime config updates"
```

---

### Task 2: AppState.tunEnabled 持久化字段

**Files:**
- Modify: `ProxyHelper/AppState.swift`

- [ ] **Step 1: 添加 `tunEnabled` 字段**

在 `AppState` 类中、`activeConfigPath` 字段定义之后插入：

```swift
    var tunEnabled: Bool = UserDefaults.standard.bool(forKey: "tunEnabled") {
        didSet { UserDefaults.standard.set(tunEnabled, forKey: "tunEnabled") }
    }
```

注意：**不要**加 `@ObservationIgnored`，必须受 `@Observable` 追踪以触发菜单重渲染（参见 CLAUDE.md 中"@Observable + @Environment 使用规则"）。

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project ProxyHelper.xcodeproj -scheme ProxyHelper -configuration Debug build -quiet`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: 提交**

```bash
git add ProxyHelper/AppState.swift
git commit -m "Add tunEnabled persisted state to AppState"
```

---

### Task 3: 菜单项 + toggleTun 动作

**Files:**
- Modify: `ProxyHelper/MenuView.swift`

- [ ] **Step 1: 在"启动/停止"按钮之前添加 TUN 菜单项**

定位到 `MenuView.body` 中第一个 `if state.isRunning { Button("停止")... }` 之前的 `Divider()`，在该 `Divider()` 之前插入：

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

        Divider()
```

结果：现有 `Divider()`（"启动/停止"上方）保留，TUN 按钮和它自己的 `Divider()` 插在配置列表的 `Divider()` 之后、启动/停止之前。完整顺序：
```
配置列表
Divider()
TUN 模式 Button   <-- 新增
Divider()         <-- 新增
启动/停止 Button
Divider()
打开配置文件夹 ...
```

- [ ] **Step 2: 在 `MARK: - Actions` 段中添加 `toggleTun` 方法**

在 `stopKernel()` 方法之后追加：

```swift
    func toggleTun() async {
        state.tunEnabled.toggle()
        guard state.isRunning else { return }
        let cfg = state.apiConfig
        let api = MihomoAPI(baseURL: cfg.baseURL, secret: cfg.secret)
        do {
            try await api.patchConfigs(["tun": ["enable": state.tunEnabled]])
            state.errorMessage = nil
        } catch {
            state.errorMessage = "TUN 切换失败：\(error.localizedDescription)"
        }
    }
```

- [ ] **Step 3: 编译验证**

Run: `xcodebuild -project ProxyHelper.xcodeproj -scheme ProxyHelper -configuration Debug build -quiet`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: 提交**

```bash
git add ProxyHelper/MenuView.swift
git commit -m "Add TUN mode menu toggle"
```

---

### Task 4: 启动内核时自动应用 TUN 状态

**Files:**
- Modify: `ProxyHelper/MenuView.swift`

- [ ] **Step 1: 修改 `startKernel()`，在 `waitUntilReady` 后、`SystemProxyManager.enable` 前注入**

定位 `startKernel()` 方法中的：
```swift
            guard ready else {
                state.errorMessage = "内核启动超时"
                KernelManager.shared.stop()
                KernelManager.shared.onUnexpectedStop = nil
                return
            }
            SystemProxyManager.shared.enable(
```

在 `guard ready else { ... }` 块结束之后、`SystemProxyManager.shared.enable(` 之前插入：

```swift
            if state.tunEnabled {
                do {
                    try await api.patchConfigs(["tun": ["enable": true]])
                } catch {
                    state.errorMessage = "TUN 启用失败：\(error.localizedDescription)"
                }
            }
```

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project ProxyHelper.xcodeproj -scheme ProxyHelper -configuration Debug build -quiet`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: 提交**

```bash
git add ProxyHelper/MenuView.swift
git commit -m "Re-apply TUN state on kernel start"
```

---

### Task 5: 切换配置时自动应用 TUN 状态

**Files:**
- Modify: `ProxyHelper/ConfigManager.swift`

- [ ] **Step 1: 修改 `switchConfig`，在 `waitUntilReady` 后、`SystemProxyManager.enable` 前注入**

定位 `switchConfig` 方法中的：
```swift
            guard ready else {
                appState.errorMessage = "切换配置后内核启动超时"
                return
            }
            SystemProxyManager.shared.enable(
```

在 `guard ready else { ... }` 块之后、`SystemProxyManager.shared.enable(` 之前插入：

```swift
            if appState.tunEnabled {
                do {
                    try await api.patchConfigs(["tun": ["enable": true]])
                } catch {
                    appState.errorMessage = "TUN 启用失败：\(error.localizedDescription)"
                }
            }
```

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project ProxyHelper.xcodeproj -scheme ProxyHelper -configuration Debug build -quiet`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: 提交**

```bash
git add ProxyHelper/ConfigManager.swift
git commit -m "Re-apply TUN state on config switch"
```

---

### Task 6: 一次性 setuid 脚本

**Files:**
- Create: `scripts/enable-tun.sh`

- [ ] **Step 1: 创建脚本**

写入 `scripts/enable-tun.sh`：

```bash
#!/bin/bash
set -e

MIHOMO=$(command -v mihomo || true)
if [ -z "$MIHOMO" ]; then
    for candidate in /opt/homebrew/bin/mihomo /usr/local/bin/mihomo; do
        if [ -x "$candidate" ]; then
            MIHOMO="$candidate"
            break
        fi
    done
fi

if [ -z "$MIHOMO" ] || [ ! -x "$MIHOMO" ]; then
    echo "错误：未找到 mihomo，请先用 brew install mihomo 安装。" >&2
    exit 1
fi

echo "对 $MIHOMO 设置 setuid 位，需要输入管理员密码..."
sudo chown root:wheel "$MIHOMO"
sudo chmod u+s "$MIHOMO"
echo "完成。之后 mihomo 启动时会以 root 身份运行，可启用 TUN 模式。"
echo "注意：brew upgrade mihomo 后需要重新执行本脚本。"
```

- [ ] **Step 2: 添加可执行权限**

Run: `chmod +x scripts/enable-tun.sh`

- [ ] **Step 3: 提交**

```bash
git add scripts/enable-tun.sh
git commit -m "Add setuid script to grant mihomo TUN permissions"
```

---

### Task 7: README 说明

**Files:**
- Modify: `README.md`

- [ ] **Step 1: 查看现有 README 结构**

Run: `cat README.md`

确认是否已有"功能"或"使用"小节，决定在哪里追加 TUN 段落。

- [ ] **Step 2: 在合适位置追加 TUN 模式说明**

追加以下 markdown 片段（位置：靠近"使用"或"高级功能"小节末尾；若无明确小节则追加到文件末尾）：

```markdown
## TUN 模式

菜单栏勾选「TUN 模式」可启用全局 TUN，使所有应用（包括不遵守系统代理设置的 CLI 工具）走代理。

由于 macOS 上创建 utun 接口需要 root 权限，首次使用前请执行一次：

\`\`\`bash
./scripts/enable-tun.sh
\`\`\`

该脚本会给 mihomo 二进制设 setuid 位，之后启动 mihomo 自动以 root 运行。

注意事项：
- `brew upgrade mihomo` 后 setuid 位会被覆盖，需重新执行脚本。
- 设了 setuid 位意味着本机任何用户都能以 root 身份执行 mihomo，单用户开发机场景下可接受；多人共享机器请勿这么做。
- TUN 模式具体行为（stack、auto-route 等）由 yaml 配置中的 `tun:` 段决定，开关只切换 `tun.enable`。
```

注意：上面 markdown 内的 `\`\`\`bash` 是为了在本计划里转义；实际写入 README 时去掉反斜杠，写成正常的 三反引号代码块。

- [ ] **Step 3: 提交**

```bash
git add README.md
git commit -m "Document TUN mode toggle and setuid script"
```

---

### Task 8: 手动验收

**Files:** 无

- [ ] **Step 1: 在 Xcode 中 `⌘R` 运行 app**

- [ ] **Step 2: 未跑 setuid 脚本场景：**
  1. 启动 mihomo（菜单点"启动"）
  2. 点"TUN 模式"
  3. 预期：菜单出现勾选；菜单顶部出现红色错误"TUN 切换失败：..."（因为 mihomo 不是 root）
  4. 再次点击关闭 TUN，错误清除

- [ ] **Step 3: 跑 setuid 脚本后场景：**
  1. `./scripts/enable-tun.sh`（输入密码）
  2. 重启 mihomo（菜单"停止"→"启动"）
  3. 终端跑 `ps -eo pid,uid,comm | grep mihomo`，确认 UID = 0
  4. 点"TUN 模式"
  5. 预期：菜单勾选；终端跑 `ifconfig | grep -A 2 utun` 看到新 utun 接口
  6. 再次点关闭，接口消失

- [ ] **Step 4: 持久化 + 切换配置：**
  1. 开启 TUN
  2. 退出 app，重新打开
  3. 预期：菜单上 TUN 仍勾选
  4. 启动内核，切换到另一个配置
  5. 预期：切换后 utun 接口仍存在

- [ ] **Step 5: 若任何步骤失败，回到对应 Task 修复后重新走验收**

---

## 完成后

所有任务完成、手动验收通过后：

```bash
git log --oneline -10  # 检查提交历史
```

考虑是否要：
- 调用 `superpowers:finishing-a-development-branch` 决定怎么合入
- 调用 `superpowers:requesting-code-review` 找 reviewer 把关
