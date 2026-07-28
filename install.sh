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

# ---------- 自动安装运行依赖 ----------
# 脚本运行时依赖：i2cset/i2cget(i2c-tools)、amixer/alsactl(alsa-utils)、
# gpioset(libgpiod/gpiod)、python3（解析 DSDT）、iasl(acpica-tools)。
# wpctl/PipeWire 为可选项：缺失时脚本自动跳过音量保护，不影响核心静音功能。
install_deps() {
    local PM=
    if command -v apt-get >/dev/null 2>&1; then PM=apt
    elif command -v dnf >/dev/null 2>&1; then PM=dnf
    elif command -v pacman >/dev/null 2>&1; then PM=pacman
    elif command -v zypper >/dev/null 2>&1; then PM=zypper
    else
        echo "警告：未能识别包管理器，跳过依赖自动安装。请手动确认以下命令可用：" >&2
        echo "  i2cset i2cget amixer alsactl gpioset python3 iasl" >&2
        return 0
    fi

    pkg_for() {
        case "$1" in
            i2cset|i2cget) echo i2c-tools ;;
            amixer|alsactl) echo alsa-utils ;;
            gpioset) [ "$PM" = "apt" ] && echo gpiod || echo libgpiod ;;
            python3) echo python3 ;;
            iasl) [ "$PM" = "pacman" ] && echo acpica || echo acpica-tools ;;
        esac
    }

    local needed="" cmd pkg
    for cmd in i2cset i2cget amixer alsactl gpioset python3 iasl; do
        command -v "$cmd" >/dev/null 2>&1 && continue
        pkg=$(pkg_for "$cmd")
        case " $needed " in *" $pkg "*) ;; *) needed="$needed $pkg" ;; esac
    done

    if [ -z "$needed" ]; then
        echo "依赖检查：所有必需命令均已存在，无需安装。"
    else
        echo "检测到缺少依赖，正在通过 $PM 安装：$needed"
        case "$PM" in
            apt)    apt-get update && apt-get install -y $needed ;;
            dnf)    dnf install -y $needed ;;
            pacman) pacman -S --needed --noconfirm $needed ;;
            zypper) zypper install -y $needed ;;
        esac
        echo "依赖安装完成。"
    fi

    if ! command -v wpctl >/dev/null 2>&1; then
        echo "提示：未检测到 wpctl（PipeWire）。拔掉耳机时的音量保护将跳过；" \
             "如需该功能，请安装 PipeWire 桌面组件（不会自动安装，以免改动音频栈）。"
    fi
}

install_deps

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
