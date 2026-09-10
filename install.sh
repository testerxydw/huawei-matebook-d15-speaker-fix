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

# ---------- 音频加固：开机静态配置（拓扑 + UCM） ----------
# 拓扑参数仅模块加载时读一次，必须由安装期写一次；运行期服务无法安全更改（重载=丢设备）。
# ⚠️ 实测（2026-09-10）：强制无 DMIC 拓扑在本机会破坏 UCM——NHLT 仍广播 cfg-dmics:2，
#    UCM 的 HiFi verb 会引用不存在的 hw:0,1，导致 HiFi profile 丢失、PipeWire 只剩 null-sink
#    （表现为"没有音频设备"）。因此该改动**默认关闭**，仅在显式 FORCE_NODMIC_TOPO=1 时才应用。
# SKIP_UCM=1 跳过 UCM 差分路由修正。
apply_boot_hardening() {
    if [ "${FORCE_NODMIC_TOPO:-0}" = "1" ] && \
       [ -f /lib/firmware/intel/sof-tplg/sof-adl-es8336-ssp0.tplg.zst ]; then
        echo 'options snd_sof tplg_filename=sof-adl-es8336-ssp0.tplg' > \
            /etc/modprobe.d/sof-es8336-nodmic.conf
        echo "已写入 /etc/modprobe.d/sof-es8336-nodmic.conf（强制无 DMIC 拓扑，需重启生效；注意可能破坏 UCM）"
    fi

    local UCM=/usr/share/alsa/ucm2/Intel/sof-essx8336/sof-essx8336.conf
    if [ "${SKIP_UCM:-0}" != "1" ] && [ -f "$UCM" ] && ! grep -q "Differential Mux" "$UCM"; then
        if [ -w "$UCM" ]; then
            cp "$UCM" "$UCM.bak"
            sed -i -E "s/^([[:space:]]*)cset \"name='Headphone Playback Volume' 100%\"/&\n\1cset \"name='Differential Mux' 1\"/" "$UCM"
            echo "已修正 UCM：$UCM（BootSequence 加 Differential Mux=1）"
        else
            echo "警告：UCM 文件只读（$UCM），跳过 UCM 修正；耳机麦路由由 huawei-speaker-mute.sh 运行时设置兜底。" >&2
        fi
    fi
}

# ---------- WirePlumber：禁止 ES8336 空闲挂起（配置固化于本项目 config/wireplumber/） ----------
# 目的：避免 ES8336(pcm0，扬声器+耳机共用) 空闲后被 WirePlumber 挂起(关 PCM)，减少偶发失声。
# 恢复方式（详见配置文件的头注释）：删除安装位置的 51-sof-essx8336-nosuspend.conf 并重启 wireplumber。
# SKIP_WP_NOSUSPEND=1 可跳过；DESKTOP_USER=<用户> 可指定目标桌面用户。
detect_desktop_user() {
    if [ -n "${DESKTOP_USER:-}" ]; then echo "$DESKTOP_USER"; return 0; fi
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then echo "$SUDO_USER"; return 0; fi
    local d
    for d in /run/user/*; do
        [ -S "$d/bus" ] || [ -S "$d/dbus-1" ] || continue
        { stat -c '%U' "$d/bus" 2>/dev/null || stat -c '%U' "$d/dbus-1" 2>/dev/null; } && return 0
    done
}
apply_wireplumber_nosuspend() {
    [ "${SKIP_WP_NOSUSPEND:-0}" = "1" ] && { echo "已跳过 WirePlumber 空闲挂起配置 (SKIP_WP_NOSUSPEND=1)"; return 0; }
    local CONF_SRC="$SRC_DIR/config/wireplumber/51-sof-essx8336-nosuspend.conf"
    [ -f "$CONF_SRC" ] || { echo "警告：未找到 $CONF_SRC，跳过 WirePlumber 配置" >&2; return 0; }
    local u home dst_dir
    u=$(detect_desktop_user)
    if [ -z "$u" ]; then echo "警告：未探测到桌面用户，跳过 WirePlumber 配置（可设 DESKTOP_USER=<用户> 重试）" >&2; return 0; fi
    home=$(getent passwd "$u" | cut -d: -f6)
    [ -n "$home" ] || { echo "警告：无法获取用户 $u 的家目录，跳过" >&2; return 0; }
    dst_dir="$home/.config/wireplumber/wireplumber.conf.d"
    mkdir -p "$dst_dir"
    install -m 0644 -o "$u" -g "$u" "$CONF_SRC" "$dst_dir/51-sof-essx8336-nosuspend.conf" 2>/dev/null \
        || install -m 0644 "$CONF_SRC" "$dst_dir/51-sof-essx8336-nosuspend.conf"
    echo "已固化 WirePlumber 配置：$dst_dir/51-sof-essx8336-nosuspend.conf"
    local uid; uid=$(id -u "$u" 2>/dev/null)
    if command -v runuser >/dev/null 2>&1 && [ -n "$uid" ]; then
        runuser -u "$u" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
            systemctl --user restart wireplumber 2>/dev/null \
            && echo "已重启 WirePlumber（用户 $u）" \
            || echo "提示：WirePlumber 重启失败，请在该用户会话内手动执行：systemctl --user restart wireplumber"
    fi
    echo "恢复方式：rm -f $dst_dir/51-sof-essx8336-nosuspend.conf && systemctl --user restart wireplumber"
}

install_deps
apply_boot_hardening

if [ -w /usr/local/bin ]; then
    BIN_DIR=/usr/local/bin
else
    BIN_DIR=/opt
fi
INSTALL_BIN="$BIN_DIR/huawei-speaker-mute.sh"
echo "正在将脚本安装到 $INSTALL_BIN ..."
install -m 0755 "$SCRIPT_SRC" "$INSTALL_BIN"

echo "正在安装 systemd 服务（ExecStart=$INSTALL_BIN）..."
# 注意：服务模板 ExecStart 写死为 /opt，需用整行替换以匹配实际安装路径，
# 不能用固定子串替换（否则 /usr/local/bin 可写时服务仍指向旧 /opt 脚本）。
sed "s#^ExecStart=.*#ExecStart=$INSTALL_BIN#" "$SERVICE_SRC" \
    > /etc/systemd/system/huawei-speaker-mute.service

echo "正在重新加载并（重启）启动服务 ..."
systemctl daemon-reload
systemctl enable huawei-speaker-mute.service
if systemctl is-active --quiet huawei-speaker-mute.service; then
    systemctl restart huawei-speaker-mute.service
else
    systemctl start huawei-speaker-mute.service
fi

apply_wireplumber_nosuspend

echo "完成。查看状态请运行：sudo systemctl status huawei-speaker-mute.service"
