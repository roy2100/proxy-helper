# ProxyHelper

macOS 菜单栏应用，控制本地 mihomo 内核的启动与停止，自动设置/清除系统 HTTP/SOCKS 代理。

## 功能

- 一键启动/停止 mihomo 内核
- 自动设置/清除 macOS 系统代理（HTTP + SOCKS）
- 扫描指定文件夹下所有 `.yaml` / `.yml` 配置文件，支持快速切换
- 实时显示上传/下载速率（需要 mihomo 配置 `external-controller`）
- 内核崩溃后自动重启（最多 3 次）
- 纯菜单栏 app，不占 Dock

## 依赖

- macOS 26 Tahoe 或更高
- [mihomo](https://github.com/MetaCubeX/mihomo)：`brew install mihomo`

## 安装

从 [Releases](../../releases) 下载最新的 `ProxyHelper-vX.X.X.zip`，解压后将 `ProxyHelper.app` 拖入 `/Applications`。

### Gatekeeper 拦截处理

由于安装包未经 Apple 公证，首次打开时 macOS 会提示"无法打开，因为 Apple 无法检查其是否包含恶意软件"。

**方法一：在 Finder 中右键打开（推荐）**

1. 在 Finder 中找到 `ProxyHelper.app`
2. 按住 `Control` 键单击（或右键）→ **打开**
3. 弹窗中点击 **打开** 确认

此后即可正常双击启动，无需重复操作。

**方法二：命令行移除隔离标记**

```bash
xattr -dr com.apple.quarantine /Applications/ProxyHelper.app
```

**从源码构建**

1. 克隆仓库，用 Xcode 打开 `ProxyHelper.xcodeproj`
2. Signing & Capabilities → 设置你的 Development Team
3. `⌘R` 运行

## 使用

1. 点击菜单栏图标 → **设置...**
2. 选择 mihomo 配置文件夹（存放 `.yaml` 文件的目录）
3. 确认 HTTP/SOCKS 端口与配置文件一致（默认 7890 / 7891）
4. 回到菜单，选择配置文件 → **启动**

## 速率显示

需要在 mihomo 配置文件中添加：

```yaml
external-controller: 127.0.0.1:9090
```

## 说明

- 使用 HTTP 代理模式，不支持 TUN 模式
- 不打包 mihomo 内核，需用户自行安装
- 不上 App Store，关闭沙盒
