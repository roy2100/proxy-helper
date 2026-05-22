#!/bin/bash
# 模拟初次安装：清除 UserDefaults，可选重启 app
set -euo pipefail

BUNDLE_ID="com.lielienan.ProxyHelper"

# 终止正在运行的实例
if pgrep -x ProxyHelper &>/dev/null; then
    echo "终止 ProxyHelper..."
    pkill -x ProxyHelper
    sleep 1
fi

defaults delete "$BUNDLE_ID" 2>/dev/null && echo "已清除 UserDefaults" || echo "UserDefaults 本就为空，跳过"

# 可选：重新启动 app（传 --launch 参数）
if [[ "${1:-}" == "--launch" ]]; then
    APP=$(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null | head -1)
    if [[ -n "$APP" ]]; then
        echo "启动 $APP ..."
        open "$APP"
    else
        echo "未找到已安装的 ProxyHelper.app，请在 Xcode 中手动 ⌘R 启动"
    fi
fi
