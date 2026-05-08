#!/bin/bash
# ============================================================
# Debian 12 Cloud Image 定制脚本
# 运行环境：Ubuntu 22.04
# 输出镜像：debian-12-genericcloud-amd64-custom.qcow2
#
# 功能：
# 1. 基于 Debian 官方 Cloud Image
# 2. 安装常用运维、开发、Docker、Node、Python 工具
# 3. 启用 SSH 22 端口
# 4. 允许 root 密码登录
# 5. 设置 root 密码为 passwd
# 6. 清理缓存并压缩 qcow2 镜像
# ============================================================

set -e

# -----------------------------
# 基础变量
# -----------------------------

# 工作目录
WORKDIR="$HOME/debian-cloud-build"

# Debian 12 官方 Cloud Image 下载地址
IMAGE_URL="https://cdimage.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"

# 原始镜像
SRC_IMAGE="${WORKDIR}/debian-12-genericcloud-amd64-src.qcow2"

# 定制中间镜像
WORK_IMAGE="${WORKDIR}/debian-12-genericcloud-amd64-work.qcow2"

# 最终输出镜像
FINAL_IMAGE="${WORKDIR}/debian-12-genericcloud-amd64-custom.qcow2"

# root 默认密码
ROOT_PASSWORD="password"

# 镜像内时区
TIMEZONE="Asia/Shanghai"

echo "============================================================"
echo "开始定制 Debian 12 Cloud Image"
echo "工作目录：${WORKDIR}"
echo "最终镜像：${FINAL_IMAGE}"
echo "root 密码：${ROOT_PASSWORD}"
echo "============================================================"

# -----------------------------
# 1. 安装 Ubuntu 构建工具
# -----------------------------
echo "[1/8] 安装 Ubuntu 构建工具..."

sudo apt update

sudo apt install -y \
  libguestfs-tools \
  qemu-utils \
  wget \
  curl \
  ca-certificates

# -----------------------------
# 2. 创建工作目录
# -----------------------------
echo "[2/8] 创建工作目录..."

mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

# -----------------------------
# 3. 下载 Debian 官方 Cloud Image
# -----------------------------
echo "[3/8] 下载 Debian 12 官方 genericcloud 镜像..."

if [ ! -f "${SRC_IMAGE}" ]; then
    wget -O "${SRC_IMAGE}" "${IMAGE_URL}"
else
    echo "原始镜像已存在，跳过下载：${SRC_IMAGE}"
fi

# 复制一份工作镜像，避免破坏原始镜像
echo "复制工作镜像..."
cp -f "${SRC_IMAGE}" "${WORK_IMAGE}"

# -----------------------------
# 4. 定制镜像
# -----------------------------
echo "[4/8] 开始定制镜像..."

sudo virt-customize -a "${WORK_IMAGE}" \
  --memsize 2048 \
  --smp 2 \
  \
  --timezone "${TIMEZONE}" \
  \
  --root-password password:"${ROOT_PASSWORD}" \
  \
  --run-command "echo 'root:${ROOT_PASSWORD}' | chpasswd" \
  \
  --run-command "mkdir -p /etc/ssh/sshd_config.d" \
  \
  --write "/etc/ssh/sshd_config.d/99-enable-root-login.conf:Port 22
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
UsePAM yes
" \
  \
  --write "/etc/cloud/cloud.cfg.d/99-enable-root-login.cfg:disable_root: false
ssh_pwauth: true
chpasswd:
  expire: false
" \
  \
  --append-line "/etc/default/grub:GRUB_DISABLE_OS_PROBER=true" \
  \
  --run-command "update-grub || true" \
  \
  --run-command "sed -i 's|Types: deb deb-src|Types: deb|g' /etc/apt/sources.list.d/debian.sources || true" \
  \
  --run-command "sed -i 's|generate_mirrorlists: true|generate_mirrorlists: false|g' /etc/cloud/cloud.cfg.d/01_debian_cloud.cfg || true" \
  \
  --update \
  \
  --install "sudo,openssh-server,qemu-guest-agent,spice-vdagent,cloud-init" \
  \
  --install "curl,wget,axel,ca-certificates,gnupg,lsb-release,apt-transport-https" \
  \
  --install "vim,nano,less,most,bash-completion,screen,tmux,unzip,zip,rsync" \
  \
  --install "net-tools,iproute2,iputils-ping,iputils-arping,iputils-tracepath,dnsutils,mtr-tiny,traceroute,tcpdump,lsof,socat,nmap,whois" \
  \
  --install "htop,atop,iotop,iftop,nload,sysstat,lldpd,tree,jq" \
  \
  --install "build-essential,make,gcc,g++,pkg-config,cmake,git,subversion" \
  \
  --install "python3,python3-pip,python3-venv,python3-dev,pipx" \
  \
  --install "nodejs,npm" \
  \
  --install "docker.io,docker-compose,containerd,runc" \
  \
  --install "zstd,bzip2,xz-utils" \
  \
  --run-command "systemctl enable ssh || true" \
  \
  --run-command "systemctl enable qemu-guest-agent || true" \
  \
  --run-command "systemctl enable docker || true" \
  \
  --run-command "systemctl enable serial-getty@ttyS0.service || true" \
  \
  --run-command "systemctl enable serial-getty@ttyS1.service || true" \
  \
  --run-command "mkdir -p /root/.ssh" \
  \
  --run-command "chmod 700 /root/.ssh" \
  \
  --run-command "echo 'nameserver 223.5.5.5' > /etc/resolv.conf || true" \
  \
  --run-command "apt-get -y autoremove --purge || true" \
  \
  --run-command "apt-get -y clean || true" \
  \
  --delete "/var/log/*.log" \
  \
  --delete "/var/lib/apt/lists/*" \
  \
  --delete "/var/cache/apt/*" \
  \
  --truncate "/etc/machine-id"

# -----------------------------
# 5. 检查镜像信息
# -----------------------------
echo "[5/8] 检查镜像信息..."

qemu-img info "${WORK_IMAGE}"

# -----------------------------
# 6. 压缩镜像
# -----------------------------
echo "[6/8] 压缩镜像..."

rm -f "${FINAL_IMAGE}"

sudo virt-sparsify --compress "${WORK_IMAGE}" "${FINAL_IMAGE}"

# 修正文件权限，方便普通用户 scp
sudo chown "$(id -u):$(id -g)" "${FINAL_IMAGE}"

# -----------------------------
# 7. 再次检查最终镜像
# -----------------------------
echo "[7/8] 最终镜像信息..."

qemu-img info "${FINAL_IMAGE}"

# -----------------------------
# 8. 完成
# -----------------------------
echo "============================================================"
echo "Debian 12 Cloud Image 定制完成"
echo "最终镜像路径："
echo "${FINAL_IMAGE}"
echo ""
echo "默认登录信息："
echo "用户：root"
echo "密码：${ROOT_PASSWORD}"
echo "SSH：22"
echo ""
echo "建议上传到 PVE："
echo "scp ${FINAL_IMAGE} root@你的PVE_IP:/root/cloud-image/"
echo "============================================================"
