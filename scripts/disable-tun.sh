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
    echo "错误：未找到 mihomo。" >&2
    exit 1
fi

echo "撤销 $MIHOMO 的 setuid 位，需要输入管理员密码..."
sudo chmod u-s "$MIHOMO"
sudo chown "$(whoami):admin" "$MIHOMO"
echo "完成。mihomo 将以普通用户身份运行，TUN 模式不再可用。"
