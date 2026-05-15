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
