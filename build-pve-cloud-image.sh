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
# - ubuntu2604
#
# 功能：
# 1. 基于官方 Cloud Image
# 2. 安装常用运维、网络排障、性能观察工具
# 3. 可选安装 Docker CE 官方 stable 仓库版本
# 4. 可选安装 Node.js 24.x LTS
# 5. 可选额外编译安装 Python 3.14，不替换系统 python3
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
INSTALL_DOCKER="${INSTALL_DOCKER:-true}"
INSTALL_NODE="${INSTALL_NODE:-true}"
INSTALL_EXTRA_PYTHON="${INSTALL_EXTRA_PYTHON:-true}"
IMAGE_DISK_SIZE="${IMAGE_DISK_SIZE:-8G}"
ROOT_PARTITION="${ROOT_PARTITION:-/dev/sda1}"
REMOVE_SNAPD="${REMOVE_SNAPD:-true}"
KEEP_BUILD_TOOLS="${KEEP_BUILD_TOOLS:-false}"
CLEAN_DOCS="${CLEAN_DOCS:-true}"
APPLY_UPDATES="${APPLY_UPDATES:-true}"

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
  ubuntu2604)
    IMAGE_NAME="ubuntu-26.04-server-cloudimg-amd64-pve-custom"
    IMAGE_URL="https://cloud-images.ubuntu.com/releases/resolute/release/ubuntu-26.04-server-cloudimg-amd64.img"
    DOCKER_OS="ubuntu"
    ;;
  *)
    echo "不支持的 IMAGE_ID：${IMAGE_ID}" >&2
    echo "可选值：debian12 debian13 ubuntu2204 ubuntu2404 ubuntu2604" >&2
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
echo "安装 Docker：${INSTALL_DOCKER}"
echo "安装 Node.js：${INSTALL_NODE}"
echo "Node.js 版本：${NODE_MAJOR}.x LTS"
echo "安装额外 Python：${INSTALL_EXTRA_PYTHON}"
echo "额外 Python 版本：${PYTHON_VERSION}"
echo "镜像虚拟磁盘：${IMAGE_DISK_SIZE}"
echo "扩容根分区：${ROOT_PARTITION}"
echo "移除 snapd：${REMOVE_SNAPD}"
echo "保留编译工具：${KEEP_BUILD_TOOLS}"
echo "清理文档缓存：${CLEAN_DOCS}"
echo "应用系统更新：${APPLY_UPDATES}"
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
  --write "/etc/default/grub.d/99-pve-cloud-init.cfg:# PVE NoCloud v1 会生成 eth0 网络配置；禁用 predictable names，避免 Ubuntu 26.04 将 ens18 改名为 eth0 时失败。
GRUB_CMDLINE_LINUX=\"\${GRUB_CMDLINE_LINUX} net.ifnames=0 biosdevname=0\"
" \
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
  --run-command "if [ '${APPLY_UPDATES}' = 'true' ]; then DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade; fi" \
  \
  --run-command "update-grub || true" \
  \
  --run-command "sed -i 's|Types: deb deb-src|Types: deb|g' /etc/apt/sources.list.d/*.sources 2>/dev/null || true" \
  \
  --run-command "sed -i 's|generate_mirrorlists: true|generate_mirrorlists: false|g' /etc/cloud/cloud.cfg.d/01_debian_cloud.cfg 2>/dev/null || true" \
  \
  --write "/etc/cloud/cloud.cfg.d/99-pve-template-no-package-upgrade.cfg:# 镜像构建阶段已经完成系统更新，克隆机首次启动不再执行 package upgrade，避免 snap refresh 干扰 cloud-init。
package_update: false
package_upgrade: false
package_reboot_if_required: false
" \
  \
  --run-command "if [ '${REMOVE_SNAPD}' = 'true' ]; then DEBIAN_FRONTEND=noninteractive apt-get -y purge snapd packagekit packagekit-tools || true; rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd; fi" \
  \
  --run-command "apt-get -y clean || true" \
  \
  --run-command "install -m 0755 -d /etc/apt/keyrings" \
  \
  --run-command "if [ '${INSTALL_DOCKER}' = 'true' ]; then curl -fsSL https://download.docker.com/linux/${DOCKER_OS}/gpg -o /etc/apt/keyrings/docker.asc; fi" \
  \
  --run-command "if [ '${INSTALL_DOCKER}' = 'true' ]; then chmod a+r /etc/apt/keyrings/docker.asc; fi" \
  \
  --run-command "if [ '${INSTALL_DOCKER}' = 'true' ]; then echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_OS} \$(. /etc/os-release && echo \"\$VERSION_CODENAME\") stable\" > /etc/apt/sources.list.d/docker.list; fi" \
  \
  --run-command "if [ '${INSTALL_NODE}' = 'true' ]; then curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash -; fi" \
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
  --run-command "if [ '${INSTALL_EXTRA_PYTHON}' = 'true' ]; then DEBIAN_FRONTEND=noninteractive apt-get install -y gcc g++ make cmake pkg-config build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev libffi-dev liblzma-dev uuid-dev; fi" \
  \
  --run-command "if [ '${INSTALL_NODE}' = 'true' ]; then DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs; fi" \
  \
  --run-command "if [ '${INSTALL_DOCKER}' = 'true' ]; then DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; fi" \
  \
  --install "zstd,bzip2,xz-utils" \
  \
  --run-command "if [ '${INSTALL_EXTRA_PYTHON}' = 'true' ]; then cd /usr/local/src && curl -fsSLO https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz; fi" \
  \
  --run-command "if [ '${INSTALL_EXTRA_PYTHON}' = 'true' ]; then cd /usr/local/src && tar -xzf Python-${PYTHON_VERSION}.tgz; fi" \
  \
  --run-command "if [ '${INSTALL_EXTRA_PYTHON}' = 'true' ]; then cd /usr/local/src/Python-${PYTHON_VERSION} && ./configure --prefix=/opt/python-${PYTHON_VERSION} --enable-shared --with-ensurepip=install; fi" \
  \
  --run-command "if [ '${INSTALL_EXTRA_PYTHON}' = 'true' ]; then cd /usr/local/src/Python-${PYTHON_VERSION} && make -j\$(nproc); fi" \
  \
  --run-command "if [ '${INSTALL_EXTRA_PYTHON}' = 'true' ]; then cd /usr/local/src/Python-${PYTHON_VERSION} && make altinstall; fi" \
  \
  --run-command "if [ '${INSTALL_EXTRA_PYTHON}' = 'true' ]; then echo '/opt/python-${PYTHON_VERSION}/lib' > /etc/ld.so.conf.d/python-${PYTHON_SHORT_VERSION}.conf && ldconfig; fi" \
  \
  --run-command "if [ '${INSTALL_EXTRA_PYTHON}' = 'true' ]; then ln -sf /opt/python-${PYTHON_VERSION}/bin/python${PYTHON_SHORT_VERSION} /usr/local/bin/python${PYTHON_SHORT_VERSION}; fi" \
  \
  --run-command "if [ '${INSTALL_EXTRA_PYTHON}' = 'true' ]; then ln -sf /opt/python-${PYTHON_VERSION}/bin/pip${PYTHON_SHORT_VERSION} /usr/local/bin/pip${PYTHON_SHORT_VERSION}; fi" \
  \
  --run-command "if [ '${INSTALL_EXTRA_PYTHON}' = 'true' ]; then /usr/local/bin/python${PYTHON_SHORT_VERSION} -m pip install --upgrade pip setuptools wheel; fi" \
  \
  --run-command "echo '===== 软件安装完成后的磁盘峰值用量 ====='; df -hT /; echo '===== inode 用量 ====='; df -ih /; echo '===== 关键目录占用 ====='; du -xh -d1 /usr /var /opt /root 2>/dev/null | sort -h || true" \
  \
  --run-command "rm -rf /usr/local/src/Python-${PYTHON_VERSION} /usr/local/src/Python-${PYTHON_VERSION}.tgz" \
  \
  --run-command "if [ '${INSTALL_EXTRA_PYTHON}' = 'true' ] && [ '${KEEP_BUILD_TOOLS}' != 'true' ]; then DEBIAN_FRONTEND=noninteractive apt-get -y purge gcc g++ make cmake pkg-config build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev libffi-dev liblzma-dev uuid-dev || true; apt-get -y autoremove --purge || true; fi" \
  \
  --run-command "if [ '${INSTALL_NODE}' = 'true' ]; then node --version; fi" \
  \
  --run-command "if [ '${INSTALL_DOCKER}' = 'true' ]; then docker --version; fi" \
  \
  --run-command "if [ '${INSTALL_EXTRA_PYTHON}' = 'true' ]; then /usr/local/bin/python${PYTHON_SHORT_VERSION} --version; fi" \
  \
  --run-command "systemctl enable ssh || true" \
  \
  --run-command "systemctl enable qemu-guest-agent || true" \
  \
  --run-command "if [ '${INSTALL_DOCKER}' = 'true' ]; then systemctl enable docker || true; fi" \
  \
  --run-command "systemctl enable serial-getty@ttyS0.service || true" \
  \
  --run-command "systemctl enable serial-getty@ttyS1.service || true" \
  \
  --run-command "mkdir -p /root/.ssh && chmod 700 /root/.ssh" \
  \
  --run-command "touch /root/.Xauthority && chmod 600 /root/.Xauthority" \
  \
  --run-command "echo 'nameserver 223.5.5.5' > /etc/resolv.conf || true" \
  \
  --run-command "apt-get -y autoremove --purge || true" \
  \
  --run-command "apt-get -y clean || true" \
  \
  --run-command "if [ '${CLEAN_DOCS}' = 'true' ]; then rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* /tmp/* /var/tmp/*; fi" \
  \
  --run-command "cloud-init clean --logs || true; rm -rf /var/lib/cloud/instances/* /var/lib/cloud/instance; rm -f /etc/netplan/50-cloud-init.yaml" \
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
if [ "${INSTALL_DOCKER}" = "true" ]; then
  echo "Docker：已安装"
else
  echo "Docker：未安装"
fi
if [ "${INSTALL_NODE}" = "true" ]; then
  echo "Node.js：${NODE_MAJOR}.x LTS"
else
  echo "Node.js：未安装"
fi
if [ "${INSTALL_EXTRA_PYTHON}" = "true" ]; then
  echo "额外 Python：/usr/local/bin/python${PYTHON_SHORT_VERSION}"
else
  echo "额外 Python：未安装"
fi
echo "SHA256：${FINAL_IMAGE}.sha256"
echo "============================================================"
