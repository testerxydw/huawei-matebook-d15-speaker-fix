#!/bin/bash
# 华为 MateBook HWSP0001 扬声器功放修复脚本的安装程序。
# 当 /usr/local/bin 可写时安装到该目录，否则回退到 /opt
# （例如在 /usr 为只读叠加层的 ostree/不可变系统上）。
set -e

SRC_DIR="$(dirname "$(readlink -f "$0")")"
SCRIPT_SRC="$SRC_DIR/huawei-speaker-mute.sh"
SERVICE_SRC="$SRC_DIR/huawei-speaker-mute.service"

if [ "$(id -u)" -ne 0 ]; then
    echo "请以 root 身份运行此安装程序：sudo bash install.sh" >&2
    exit 1
fi

if [ -w /usr/local/bin ]; then
    BIN_DIR=/usr/local/bin
else
    BIN_DIR=/opt
fi
INSTALL_BIN="$BIN_DIR/huawei-speaker-mute.sh"
echo "正在将脚本安装到 $INSTALL_BIN ..."
install -m 0755 "$SCRIPT_SRC" "$INSTALL_BIN"

echo "正在安装 systemd 服务（ExecStart=$INSTALL_BIN）..."
sed "s#/usr/local/bin/huawei-speaker-mute.sh#$INSTALL_BIN#" "$SERVICE_SRC" \
    > /etc/systemd/system/huawei-speaker-mute.service

echo "正在重新加载并（重启）启动服务 ..."
systemctl daemon-reload
systemctl enable huawei-speaker-mute.service
if systemctl is-active --quiet huawei-speaker-mute.service; then
    systemctl restart huawei-speaker-mute.service
else
    systemctl start huawei-speaker-mute.service
fi

echo "完成。查看状态请运行：sudo systemctl status huawei-speaker-mute.service"
