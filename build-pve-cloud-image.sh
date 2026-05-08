#!/bin/bash
# ============================================================
# PVE Cloud Image 定制脚本
# 运行环境：Ubuntu 22.04 / 24.04，本仓库 GitHub Actions 固定 ubuntu-22.04
#
# 支持镜像：
# - debian12
# - debian13
# - ubuntu2204
# - ubuntu2404
#
# 功能：
# 1. 基于官方 Cloud Image
# 2. 安装常用运维、网络排障、性能观察工具
# 3. 安装 Docker CE 官方 stable 仓库版本
# 4. 安装 Node.js 24.x LTS
# 5. 额外编译安装 Python 3.14，不替换系统 python3
# 6. 启用 SSH、cloud-init、qemu-guest-agent
# 7. 清理缓存并压缩 qcow2 镜像
# ============================================================

set -euo pipefail

# -----------------------------
# 基础变量
# -----------------------------

IMAGE_ID="${IMAGE_ID:-debian12}"
WORKDIR="${WORKDIR:-$HOME/pve-cloud-build/${IMAGE_ID}}"
ROOT_PASSWORD="${ROOT_PASSWORD:-password}"
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
NODE_MAJOR="${NODE_MAJOR:-24}"
PYTHON_VERSION="${PYTHON_VERSION:-3.14.4}"
PYTHON_SHORT_VERSION="${PYTHON_VERSION%.*}"
IMAGE_DISK_SIZE="${IMAGE_DISK_SIZE:-8G}"
ROOT_PARTITION="${ROOT_PARTITION:-/dev/sda1}"
REMOVE_SNAPD="${REMOVE_SNAPD:-true}"
KEEP_BUILD_TOOLS="${KEEP_BUILD_TOOLS:-false}"
CLEAN_DOCS="${CLEAN_DOCS:-true}"

# GitHub Actions 等受限环境下，libguestfs 默认后端可能触发 passt/libvirt 限制。
# 显式使用 direct 后端，让 virt-customize 直接启动 qemu appliance。
export LIBGUESTFS_BACKEND="${LIBGUESTFS_BACKEND:-direct}"

case "${IMAGE_ID}" in
  debian12)
    IMAGE_NAME="debian-12-genericcloud-amd64-pve-custom"
    IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
    DOCKER_OS="debian"
    ;;
  debian13)
    IMAGE_NAME="debian-13-genericcloud-amd64-pve-custom"
    IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
    DOCKER_OS="debian"
    ;;
  ubuntu2204)
    IMAGE_NAME="ubuntu-22.04-server-cloudimg-amd64-pve-custom"
    IMAGE_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
    DOCKER_OS="ubuntu"
    ;;
  ubuntu2404)
    IMAGE_NAME="ubuntu-24.04-server-cloudimg-amd64-pve-custom"
    IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    DOCKER_OS="ubuntu"
    ;;
  *)
    echo "不支持的 IMAGE_ID：${IMAGE_ID}" >&2
    echo "可选值：debian12 debian13 ubuntu2204 ubuntu2404" >&2
    exit 1
    ;;
esac

SRC_IMAGE="${WORKDIR}/${IMAGE_NAME}-src.qcow2"
WORK_IMAGE="${WORKDIR}/${IMAGE_NAME}-work.qcow2"
FINAL_IMAGE="${FINAL_IMAGE:-${WORKDIR}/${IMAGE_NAME}.qcow2}"

echo "============================================================"
echo "开始定制 PVE Cloud Image"
echo "镜像 ID：${IMAGE_ID}"
echo "镜像地址：${IMAGE_URL}"
echo "工作目录：${WORKDIR}"
echo "最终镜像：${FINAL_IMAGE}"
echo "root 密码：${ROOT_PASSWORD}"
echo "Node.js：${NODE_MAJOR}.x LTS"
echo "额外 Python：${PYTHON_VERSION}"
echo "镜像虚拟磁盘：${IMAGE_DISK_SIZE}"
echo "扩容根分区：${ROOT_PARTITION}"
echo "移除 snapd：${REMOVE_SNAPD}"
echo "保留编译工具：${KEEP_BUILD_TOOLS}"
echo "清理文档缓存：${CLEAN_DOCS}"
echo "libguestfs 后端：${LIBGUESTFS_BACKEND}"
echo "============================================================"

# -----------------------------
# 1. 安装构建工具
# -----------------------------
echo "[1/8] 安装宿主机构建工具..."

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
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
# 3. 下载官方 Cloud Image
# -----------------------------
echo "[3/8] 下载官方 Cloud Image..."

if [ ! -f "${SRC_IMAGE}" ]; then
  wget -O "${SRC_IMAGE}" "${IMAGE_URL}"
else
  echo "原始镜像已存在，跳过下载：${SRC_IMAGE}"
fi

echo "复制并扩大工作镜像虚拟磁盘..."
rm -f "${WORK_IMAGE}"
cp -f "${SRC_IMAGE}" "${WORK_IMAGE}"
qemu-img resize "${WORK_IMAGE}" "${IMAGE_DISK_SIZE}"
echo "源镜像分区信息："
sudo env LIBGUESTFS_BACKEND="${LIBGUESTFS_BACKEND}" virt-filesystems \
  --long \
  --parts \
  --blkdevs \
  -a "${WORK_IMAGE}"

# -----------------------------
# 4. 定制镜像
# -----------------------------
echo "[4/8] 开始定制镜像..."

sudo env LIBGUESTFS_BACKEND="${LIBGUESTFS_BACKEND}" virt-customize -a "${WORK_IMAGE}" \
  --memsize 4096 \
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
  --run-command "apt-get update" \
  \
  --write "/etc/apt/apt.conf.d/99-template-no-recommends:APT::Install-Recommends \"false\";
APT::Install-Suggests \"false\";
" \
  \
  --run-command "DEBIAN_FRONTEND=noninteractive apt-get install -y cloud-guest-utils e2fsprogs ca-certificates curl gnupg" \
  \
  --run-command "growpart /dev/sda 1" \
  \
  --run-command "resize2fs '${ROOT_PARTITION}'" \
  \
  --run-command "df -h /" \
  \
  --run-command "update-grub || true" \
  \
  --run-command "sed -i 's|Types: deb deb-src|Types: deb|g' /etc/apt/sources.list.d/*.sources 2>/dev/null || true" \
  \
  --run-command "sed -i 's|generate_mirrorlists: true|generate_mirrorlists: false|g' /etc/cloud/cloud.cfg.d/01_debian_cloud.cfg 2>/dev/null || true" \
  \
  --run-command "if [ '${REMOVE_SNAPD}' = 'true' ]; then DEBIAN_FRONTEND=noninteractive apt-get -y purge snapd packagekit packagekit-tools || true; rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd; fi" \
  \
  --run-command "apt-get -y clean || true" \
  \
  --run-command "install -m 0755 -d /etc/apt/keyrings" \
  \
  --run-command "curl -fsSL https://download.docker.com/linux/${DOCKER_OS}/gpg -o /etc/apt/keyrings/docker.asc" \
  \
  --run-command "chmod a+r /etc/apt/keyrings/docker.asc" \
  \
  --run-command "echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_OS} \$(. /etc/os-release && echo \"\$VERSION_CODENAME\") stable\" > /etc/apt/sources.list.d/docker.list" \
  \
  --run-command "curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash -" \
  \
  --run-command "echo 'iperf3 iperf3/start_daemon boolean false' | debconf-set-selections || true" \
  \
  --run-command "apt-get update" \
  \
  --install "sudo,openssh-server,qemu-guest-agent,spice-vdagent,cloud-init" \
  \
  --install "wget,curl,git,vim,nano,unzip,zip,rsync" \
  \
  --install "net-tools,iproute2,iputils-ping,iputils-arping,iputils-tracepath" \
  \
  --install "traceroute,mtr-tiny,dnsutils,telnet,nmap,iperf3,tcpdump,lsof,socat,whois" \
  \
  --install "htop,atop,iotop,iftop,nload,sysstat" \
  \
  --install "tmux,screen,bash-completion,less,most,tree,jq" \
  \
  --install "sshpass,ca-certificates,gnupg,lsb-release,apt-transport-https" \
  \
  --install "python3,python3-pip,python3-venv,pipx" \
  \
  --install "gcc,g++,make,cmake,pkg-config,build-essential,libssl-dev,zlib1g-dev,libbz2-dev,libreadline-dev,libsqlite3-dev,libffi-dev,liblzma-dev,uuid-dev" \
  \
  --install "nodejs" \
  \
  --install "docker-ce,docker-ce-cli,containerd.io,docker-buildx-plugin,docker-compose-plugin" \
  \
  --install "zstd,bzip2,xz-utils" \
  \
  --run-command "cd /usr/local/src && curl -fsSLO https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz" \
  \
  --run-command "cd /usr/local/src && tar -xzf Python-${PYTHON_VERSION}.tgz" \
  \
  --run-command "cd /usr/local/src/Python-${PYTHON_VERSION} && ./configure --prefix=/opt/python-${PYTHON_VERSION} --enable-shared --with-ensurepip=install" \
  \
  --run-command "cd /usr/local/src/Python-${PYTHON_VERSION} && make -j\$(nproc)" \
  \
  --run-command "cd /usr/local/src/Python-${PYTHON_VERSION} && make altinstall" \
  \
  --run-command "echo '/opt/python-${PYTHON_VERSION}/lib' > /etc/ld.so.conf.d/python-${PYTHON_SHORT_VERSION}.conf && ldconfig" \
  \
  --run-command "ln -sf /opt/python-${PYTHON_VERSION}/bin/python${PYTHON_SHORT_VERSION} /usr/local/bin/python${PYTHON_SHORT_VERSION}" \
  \
  --run-command "ln -sf /opt/python-${PYTHON_VERSION}/bin/pip${PYTHON_SHORT_VERSION} /usr/local/bin/pip${PYTHON_SHORT_VERSION}" \
  \
  --run-command "/usr/local/bin/python${PYTHON_SHORT_VERSION} -m pip install --upgrade pip setuptools wheel" \
  \
  --run-command "rm -rf /usr/local/src/Python-${PYTHON_VERSION} /usr/local/src/Python-${PYTHON_VERSION}.tgz" \
  \
  --run-command "if [ '${KEEP_BUILD_TOOLS}' != 'true' ]; then DEBIAN_FRONTEND=noninteractive apt-get -y purge gcc g++ make cmake pkg-config build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev libffi-dev liblzma-dev uuid-dev || true; apt-get -y autoremove --purge || true; fi" \
  \
  --run-command "node --version" \
  \
  --run-command "docker --version" \
  \
  --run-command "/usr/local/bin/python${PYTHON_SHORT_VERSION} --version" \
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
  --run-command "mkdir -p /root/.ssh && chmod 700 /root/.ssh" \
  \
  --run-command "echo 'nameserver 223.5.5.5' > /etc/resolv.conf || true" \
  \
  --run-command "apt-get -y autoremove --purge || true" \
  \
  --run-command "apt-get -y clean || true" \
  \
  --run-command "if [ '${CLEAN_DOCS}' = 'true' ]; then rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* /tmp/* /var/tmp/*; fi" \
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
sudo env LIBGUESTFS_BACKEND="${LIBGUESTFS_BACKEND}" virt-sparsify --compress "${WORK_IMAGE}" "${FINAL_IMAGE}"

# 修正文件权限，方便普通用户下载或 scp
sudo chown "$(id -u):$(id -g)" "${FINAL_IMAGE}"

# -----------------------------
# 7. 生成校验文件
# -----------------------------
echo "[7/8] 最终镜像信息..."

qemu-img info "${FINAL_IMAGE}"

echo "[7/8] 生成 SHA256 校验文件..."
(
  cd "$(dirname "${FINAL_IMAGE}")"
  sha256sum "$(basename "${FINAL_IMAGE}")" | tee "$(basename "${FINAL_IMAGE}").sha256"
)

# -----------------------------
# 8. 完成
# -----------------------------
echo "============================================================"
echo "PVE Cloud Image 定制完成"
echo "镜像 ID：${IMAGE_ID}"
echo "最终镜像路径：${FINAL_IMAGE}"
echo "默认登录信息：root / ${ROOT_PASSWORD}"
echo "SSH：22"
echo "Node.js：${NODE_MAJOR}.x LTS"
echo "额外 Python：/usr/local/bin/python${PYTHON_SHORT_VERSION}"
echo "SHA256：${FINAL_IMAGE}.sha256"
echo "============================================================"
