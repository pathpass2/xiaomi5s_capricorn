#!/bin/bash
# 在 chroot 内执行的 rootfs 配置脚本（Ubuntu 22.04 arm64）。
set -euo pipefail

USERNAME="${USERNAME:-pathpass2}"
USER_PASSWORD="${USER_PASSWORD:-1234}"
LOCALE="${LOCALE:-zh_CN.UTF-8}"
EXTRA_LOCALE="${EXTRA_LOCALE:-en_US.UTF-8}"
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
APT_MIRROR="${APT_MIRROR:-mirrors.ustc.edu.cn}"

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

trap 'echo "configure-rootfs.sh: 第 $LINENO 行失败" >&2' ERR

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------
require_file() {
    if [ ! -f "$1" ]; then
        echo "缺少 $1 —— 检查 overlay/ 是否完整以及 workflow 的拷贝顺序" >&2
        exit 1
    fi
}

sed_assert() {
    local pattern="$1" file="$2" expect="$3"
    require_file "$file"
    sed -i -E "$pattern" "$file"
    if ! grep -qF -- "$expect" "$file"; then
        echo "改写 $file 失败：预期出现 '$expect'，实际内容：" >&2
        cat "$file" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
echo "=============== 安装软件包 ==============="
# ---------------------------------------------------------------------------
apt-get update
# Ubuntu 22.04 与 Debian 包名基本一致；这里保留原列表，
# 仅把 Debian 专有的 console-setup 保留（Ubuntu 也有）。
apt-get install -y --no-install-recommends \
    locales \
    console-setup kbd fonts-dejavu \
    sudo vim nano less \
    curl ca-certificates \
    openssh-server openssh-client \
    net-tools ethtool ifupdown iputils-ping \
    network-manager wpasupplicant wireless-regdb rfkill iw \
    libpam-systemd \
    systemd-timesyncd \
    htop kmod usbutils i2c-tools fdisk \
    make zram-tools git \
    libevdev2 libinput10 libxkbcommon0 \
    initramfs-tools busybox \
    ncurses-term \
    libinih1 \
    language-pack-zh-hans

# ---------------------------------------------------------------------------
echo "=============== locale ==============="
# ---------------------------------------------------------------------------
enable_locale() {
    local loc="$1" esc
    esc=$(printf '%s' "$loc" | sed 's/[.[\*^$]/\\&/g')
    sed -i -E "s/^# *(${esc}[[:space:]]+[^[:space:]]+)/\1/" /etc/locale.gen
    grep -qE "^${esc}[[:space:]]" /etc/locale.gen || echo "${loc} UTF-8" >> /etc/locale.gen
}
enable_locale "$LOCALE"
[ -n "$EXTRA_LOCALE" ] && enable_locale "$EXTRA_LOCALE"
locale-gen

# 默认中文。LC_TIME 跟随 LANG，zh_CN.UTF-8 下时间格式本身就是 24 小时制（%H:%M）。
update-locale LANG="$LOCALE" LC_TIME="$LOCALE"

# ---------------------------------------------------------------------------
echo "=============== 控制台字体 ==============="
# ---------------------------------------------------------------------------
require_file /etc/default/console-setup
setupcon --save-only || echo "setupcon 在 chroot 内失败属正常，配置已落盘"

# ---------------------------------------------------------------------------
echo "=============== 用户 ==============="
# ---------------------------------------------------------------------------
if ! id "$USERNAME" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$USERNAME"
fi
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd

# 加入 sudo 组（要求：具有 sudo）。Ubuntu 默认 sudo 组已存在，
# 这里仍做存在性判断，保持与原有逻辑一致。
for g in sudo video input audio dialout plugdev; do
    if getent group "$g" >/dev/null; then
        usermod -aG "$g" "$USERNAME"
    else
        echo "跳过不存在的组：$g"
    fi
done

# 密码 1234 已是明文，无需再强制改密；若希望 sudo 免密可取消下面这行注释
echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"
chmod 440 "/etc/sudoers.d/${USERNAME}"

# ---------------------------------------------------------------------------
echo "=============== 用户名同步到 unit 文件 ==============="
# ---------------------------------------------------------------------------
sed_assert "s/--autologin [^ ]+/--autologin ${USERNAME}/" \
    /etc/systemd/system/getty@tty1.service.d/override.conf \
    "--autologin ${USERNAME}"

sed_assert "s/--autologin [^ ]+/--autologin ${USERNAME}/" \
    "/etc/systemd/system/serial-getty@ttyGS0.service.d/autologin.conf" \
    "--autologin ${USERNAME}"

# ---------------------------------------------------------------------------
echo "=============== SSH ==============="
# ---------------------------------------------------------------------------
install -d -m 700 -o "$USERNAME" -g "$USERNAME" "/home/${USERNAME}/.ssh"
install -m 600 -o "$USERNAME" -g "$USERNAME" /dev/null "/home/${USERNAME}/.ssh/authorized_keys"

install -d /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-local.conf <<'SSHCONF'
PasswordAuthentication yes
PermitRootLogin no
SSHCONF

# ---------------------------------------------------------------------------
echo "=============== 主机名 ==============="
# ---------------------------------------------------------------------------
echo "$USERNAME" > /etc/hostname
grep -q "127.0.1.1" /etc/hosts || echo "127.0.1.1 ${USERNAME}" >> /etc/hosts

# ---------------------------------------------------------------------------
echo "=============== 时区 ==============="
# ---------------------------------------------------------------------------
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
echo "${TIMEZONE}" > /etc/timezone

# ---------------------------------------------------------------------------
echo "=============== 脚本权限 ==============="
# ---------------------------------------------------------------------------
for f in /usr/bin/power.sh /usr/bin/hkdm /usr/bin/buffyboard /usr/local/sbin/grow-rootfs; do
    if [ -e "$f" ]; then
        chmod 755 "$f"
    else
        echo "警告：$f 不存在" >&2
    fi
done
[ -d /etc/hkdm ] && chmod -R a+rX /etc/hkdm

# ---------------------------------------------------------------------------
echo "=============== systemd 服务 ==============="
# ---------------------------------------------------------------------------
systemctl enable ssh
systemctl enable NetworkManager
systemctl enable systemd-timesyncd
systemctl enable getty@tty1.service
systemctl enable serial-getty@ttyGS0.service

require_file /usr/local/sbin/grow-rootfs
systemctl enable grow-rootfs.service

# zram
systemctl enable zramswap

chown root:root /etc/hkdm
chown root:root /etc/hkdm/config.d
chown root:root /etc/hkdm/config.d/power.toml
chmod 755 /etc/hkdm
chmod 755 /etc/hkdm/config.d
chmod 644 /etc/hkdm/config.d/power.toml

chmod 755 /usr/local/bin/*
chmod 755 /usr/local/libexec/*
chmod 755 /usr/local/sbin/*

systemctl enable console-keys.service

if [ -x /usr/bin/hkdm ]; then
    systemctl enable hkdm.service
else
    echo "警告：/usr/bin/hkdm 不存在，跳过 hkdm.service" >&2
fi
# buffyboard 不 enable —— 由 power.sh 按需 start/stop

# ---------------------------------------------------------------------------
echo "=============== initramfs ==============="
# ---------------------------------------------------------------------------
update-initramfs -u || echo "update-initramfs 失败（无内核时属正常）"

# ---------------------------------------------------------------------------
echo "=============== APT 源兜底 ==============="
# ---------------------------------------------------------------------------
# Ubuntu 22.04 的源已在 workflow 中写为 ubuntu-ports（中科大）。
# 这里只做兜底：若 sources.list 仍指向官方域名，统一替换成镜像。
if [ -f /etc/apt/sources.list ]; then
    sed -i "s|archive\.ubuntu\.com|${APT_MIRROR}/ubuntu-ports|g; \
            s|ports\.ubuntu\.com|${APT_MIRROR}/ubuntu-ports|g; \
            s|security\.ubuntu\.com|${APT_MIRROR}/ubuntu-ports|g" \
        /etc/apt/sources.list
fi

# ---------------------------------------------------------------------------
echo "=============== DNS ==============="
# ---------------------------------------------------------------------------
if [ ! -L /etc/resolv.conf ]; then
    cat > /etc/resolv.conf <<'RESOLV'
nameserver 223.5.5.5
nameserver 119.29.29.29
RESOLV
fi

echo 'Ubuntu 22.04 ARM64 base rootfs' > /etc/motd

# ---------------------------------------------------------------------------
echo "=============== 清理 ==============="
# ---------------------------------------------------------------------------
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

echo "=============== 完成 ==============="
