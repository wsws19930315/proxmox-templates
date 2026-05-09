# Proxmox PVE Cloud Templates

这个仓库用于构建可在 PVE / Proxmox VE 中直接使用的 Debian / Ubuntu Cloud Image 模板。

## 支持镜像

每次 GitHub Actions 会构建 4 个 amd64 镜像：

| 系统 | 文件名 |
| --- | --- |
| Debian 12 | `debian-12-genericcloud-amd64-pve-custom.qcow2` |
| Debian 13 | `debian-13-genericcloud-amd64-pve-custom.qcow2` |
| Ubuntu 22.04 LTS | `ubuntu-22.04-server-cloudimg-amd64-pve-custom.qcow2` |
| Ubuntu 24.04 LTS | `ubuntu-24.04-server-cloudimg-amd64-pve-custom.qcow2` |

## 默认集成

- PVE：`cloud-init`、`qemu-guest-agent`、`spice-vdagent`
- 基础工具：`wget`、`curl`、`git`、`vim`、`nano`、`unzip`、`zip`、`rsync`
- 网络排障：`net-tools`、`iproute2`、`ping`、`arping`、`tracepath`、`traceroute`、`mtr-tiny`、`dnsutils`、`telnet`、`nmap`、`iperf3`、`tcpdump`、`lsof`、`socat`、`whois`
- 性能观察：`htop`、`atop`、`iotop`、`iftop`、`nload`、`sysstat`
- Shell 辅助：`tmux`、`screen`、`bash-completion`、`less`、`most`、`tree`、`jq`
- Docker：Docker CE 官方 stable APT 源
- Node.js：NodeSource 24.x LTS
- Python：保留系统 `python3`，默认额外安装 `/usr/local/bin/python3.14`

默认模板偏轻量：额外 Python 是可选项。启用额外 Python 时，编译 Python 3.14 所需的 `gcc`、`g++`、`make`、`cmake`、`build-essential` 等工具会临时安装，构建结束后清理。运行工作流时勾选 `keep_build_tools` 可保留这批编译环境；如果关闭 `install_extra_python`，则不会额外安装这批编译工具。

默认构建时会执行系统更新，尽量减少首次登录后提示大量可升级安全更新。如果某次上游更新导致构建失败，可以在工作流里取消勾选 `apply_updates` 后重新构建。

默认 root 登录：

```text
用户：root
密码：password
SSH：22
```

公开环境请首次启动后立即改密码，或使用 Cloud-init 注入 SSH 公钥。

## 在 PVE 上直接使用 Release 镜像

下面的脚本会自动做两件事：

- 自动读取本仓库最新 GitHub Release 标签，不需要手动改日期。
- 自动识别 PVE 存储名，优先使用 `local-lvm`，没有时选择第一个支持 `images` 或 `rootdir` 的存储。

如果你的 PVE 是默认安装，通常直接复制脚本到 PVE 的 SSH 里运行即可。创建完成后，新建虚拟机只需要克隆对应模板。

如需先查看 PVE 存储列表：

```bash
pvesm status
```

### Debian 12 模板

下面示例会创建 VMID `9012`，模板名 `debian-12-dev-template`。

```bash
# -----------------------------
# 1. 基础变量
# -----------------------------

# GitHub 仓库。
REPO="vbskycn/proxmox-templates"

# 自动获取本仓库最新 Release 标签。
RELEASE_TAG="$(wget -qO- "https://api.github.com/repos/${REPO}/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
if [ -z "${RELEASE_TAG}" ]; then
  echo "无法获取最新 Release 标签，请检查网络或 GitHub API 访问。"
  exit 1
fi

# Release 下载基础地址。
BASE_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}"

# PVE 模板 VMID，建议 9000 段专门留给模板。
VMID=9012

# 自动识别 PVE 存储名：优先 local-lvm，否则选择第一个支持 images/rootdir 的存储。
if pvesm status | awk 'NR>1 {print $1}' | grep -qx "local-lvm"; then
  STORAGE="local-lvm"
else
  STORAGE="$(pvesm status --content images 2>/dev/null | awk 'NR==2 {print $1}')"
  if [ -z "${STORAGE}" ]; then
    STORAGE="$(pvesm status --content rootdir 2>/dev/null | awk 'NR==2 {print $1}')"
  fi
fi

if [ -z "${STORAGE}" ]; then
  echo "无法自动识别 PVE 存储名，请先执行 pvesm status 查看，并手动设置 STORAGE。"
  exit 1
fi

echo "使用 Release：${RELEASE_TAG}"
echo "使用存储：${STORAGE}"

# 模板名称。
NAME="debian-12-dev-template"

# 镜像文件名。
IMAGE="debian-12-genericcloud-amd64-pve-custom.qcow2"

# 镜像保存目录。
IMAGE_DIR="/root/cloud-image"

# -----------------------------
# 2. 下载镜像和校验文件
# -----------------------------

mkdir -p "${IMAGE_DIR}"
cd "${IMAGE_DIR}"

wget -O "${IMAGE}" "${BASE_URL}/${IMAGE}"
wget -O "${IMAGE}.sha256" "${BASE_URL}/${IMAGE}.sha256"

# 校验 SHA256。这里兼容旧版本 sha256 文件里带绝对路径的情况。
awk -v image="${IMAGE}" '{print $1 "  " image}' "${IMAGE}.sha256" | sha256sum -c -

# -----------------------------
# 3. 创建 PVE 模板虚拟机
# -----------------------------

# 创建一个空 VM，后面把 cloud image 导入为系统盘。
qm create "${VMID}" \
  --machine q35 \
  --cpu cputype=host \
  --name "${NAME}" \
  --scsi2 "${STORAGE}:cloudinit" \
  --serial0 socket \
  --vga serial0 \
  --scsihw virtio-scsi-single \
  --net0 virtio,bridge=vmbr0 \
  --agent 1 \
  --ostype l26 \
  --memory 2048 \
  --cores 2

# 导入 qcow2 镜像到 PVE 存储。
qm importdisk "${VMID}" "${IMAGE_DIR}/${IMAGE}" "${STORAGE}"

# 把导入后的磁盘挂到 scsi0，并开启 discard/ssd 标记。
qm set "${VMID}" --scsi0 "${STORAGE}:vm-${VMID}-disk-0,discard=on,ssd=1"

# 设置从 scsi0 启动。
qm set "${VMID}" --boot order=scsi0

# Cloud-init 默认使用 DHCP 获取 IP。
qm set "${VMID}" --ipconfig0 ip=dhcp

# Cloud-init 默认 root 用户和密码。
qm set "${VMID}" --ciuser root
qm set "${VMID}" --cipassword "password"

# 如果需要 SSH 公钥登录，可以取消下一行注释，并确认文件存在。
# qm set "${VMID}" --sshkeys ~/.ssh/authorized_keys

# 转换成模板。
qm template "${VMID}"
```

如果你的 PVE 存储类型不同，导入后的磁盘名可能和 `vm-${VMID}-disk-0` 不一致。可以先执行 `qm config "${VMID}"` 查看 `unused0` 对应的磁盘名，再替换 `--scsi0` 后面的磁盘路径。

### Debian 13 模板

```bash
REPO="vbskycn/proxmox-templates"
RELEASE_TAG="$(wget -qO- "https://api.github.com/repos/${REPO}/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
[ -n "${RELEASE_TAG}" ] || { echo "无法获取最新 Release 标签"; exit 1; }
BASE_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}"
VMID=9013
if pvesm status | awk 'NR>1 {print $1}' | grep -qx "local-lvm"; then
  STORAGE="local-lvm"
else
  STORAGE="$(pvesm status --content images 2>/dev/null | awk 'NR==2 {print $1}')"
  [ -n "${STORAGE}" ] || STORAGE="$(pvesm status --content rootdir 2>/dev/null | awk 'NR==2 {print $1}')"
fi
[ -n "${STORAGE}" ] || { echo "无法自动识别 PVE 存储名"; exit 1; }
NAME="debian-13-dev-template"
IMAGE="debian-13-genericcloud-amd64-pve-custom.qcow2"
IMAGE_DIR="/root/cloud-image"

mkdir -p "${IMAGE_DIR}"
cd "${IMAGE_DIR}"
wget -O "${IMAGE}" "${BASE_URL}/${IMAGE}"
wget -O "${IMAGE}.sha256" "${BASE_URL}/${IMAGE}.sha256"
awk -v image="${IMAGE}" '{print $1 "  " image}' "${IMAGE}.sha256" | sha256sum -c -

qm create "${VMID}" \
  --machine q35 \
  --cpu cputype=host \
  --name "${NAME}" \
  --scsi2 "${STORAGE}:cloudinit" \
  --serial0 socket \
  --vga serial0 \
  --scsihw virtio-scsi-single \
  --net0 virtio,bridge=vmbr0 \
  --agent 1 \
  --ostype l26 \
  --memory 2048 \
  --cores 2

qm importdisk "${VMID}" "${IMAGE_DIR}/${IMAGE}" "${STORAGE}"
qm set "${VMID}" --scsi0 "${STORAGE}:vm-${VMID}-disk-0,discard=on,ssd=1"
qm set "${VMID}" --boot order=scsi0
qm set "${VMID}" --ipconfig0 ip=dhcp
qm set "${VMID}" --ciuser root
qm set "${VMID}" --cipassword "password"
qm template "${VMID}"
```

### Ubuntu 22.04 模板

```bash
REPO="vbskycn/proxmox-templates"
RELEASE_TAG="$(wget -qO- "https://api.github.com/repos/${REPO}/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
[ -n "${RELEASE_TAG}" ] || { echo "无法获取最新 Release 标签"; exit 1; }
BASE_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}"
VMID=9022
if pvesm status | awk 'NR>1 {print $1}' | grep -qx "local-lvm"; then
  STORAGE="local-lvm"
else
  STORAGE="$(pvesm status --content images 2>/dev/null | awk 'NR==2 {print $1}')"
  [ -n "${STORAGE}" ] || STORAGE="$(pvesm status --content rootdir 2>/dev/null | awk 'NR==2 {print $1}')"
fi
[ -n "${STORAGE}" ] || { echo "无法自动识别 PVE 存储名"; exit 1; }
NAME="ubuntu-22.04-dev-template"
IMAGE="ubuntu-22.04-server-cloudimg-amd64-pve-custom.qcow2"
IMAGE_DIR="/root/cloud-image"

mkdir -p "${IMAGE_DIR}"
cd "${IMAGE_DIR}"
wget -O "${IMAGE}" "${BASE_URL}/${IMAGE}"
wget -O "${IMAGE}.sha256" "${BASE_URL}/${IMAGE}.sha256"
awk -v image="${IMAGE}" '{print $1 "  " image}' "${IMAGE}.sha256" | sha256sum -c -

qm create "${VMID}" \
  --machine q35 \
  --cpu cputype=host \
  --name "${NAME}" \
  --scsi2 "${STORAGE}:cloudinit" \
  --serial0 socket \
  --vga serial0 \
  --scsihw virtio-scsi-single \
  --net0 virtio,bridge=vmbr0 \
  --agent 1 \
  --ostype l26 \
  --memory 2048 \
  --cores 2

qm importdisk "${VMID}" "${IMAGE_DIR}/${IMAGE}" "${STORAGE}"
qm set "${VMID}" --scsi0 "${STORAGE}:vm-${VMID}-disk-0,discard=on,ssd=1"
qm set "${VMID}" --boot order=scsi0
qm set "${VMID}" --ipconfig0 ip=dhcp
qm set "${VMID}" --ciuser root
qm set "${VMID}" --cipassword "password"
qm template "${VMID}"
```

### Ubuntu 24.04 模板

```bash
REPO="vbskycn/proxmox-templates"
RELEASE_TAG="$(wget -qO- "https://api.github.com/repos/${REPO}/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
[ -n "${RELEASE_TAG}" ] || { echo "无法获取最新 Release 标签"; exit 1; }
BASE_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}"
VMID=9024
if pvesm status | awk 'NR>1 {print $1}' | grep -qx "local-lvm"; then
  STORAGE="local-lvm"
else
  STORAGE="$(pvesm status --content images 2>/dev/null | awk 'NR==2 {print $1}')"
  [ -n "${STORAGE}" ] || STORAGE="$(pvesm status --content rootdir 2>/dev/null | awk 'NR==2 {print $1}')"
fi
[ -n "${STORAGE}" ] || { echo "无法自动识别 PVE 存储名"; exit 1; }
NAME="ubuntu-24.04-dev-template"
IMAGE="ubuntu-24.04-server-cloudimg-amd64-pve-custom.qcow2"
IMAGE_DIR="/root/cloud-image"

mkdir -p "${IMAGE_DIR}"
cd "${IMAGE_DIR}"
wget -O "${IMAGE}" "${BASE_URL}/${IMAGE}"
wget -O "${IMAGE}.sha256" "${BASE_URL}/${IMAGE}.sha256"
awk -v image="${IMAGE}" '{print $1 "  " image}' "${IMAGE}.sha256" | sha256sum -c -

qm create "${VMID}" \
  --machine q35 \
  --cpu cputype=host \
  --name "${NAME}" \
  --scsi2 "${STORAGE}:cloudinit" \
  --serial0 socket \
  --vga serial0 \
  --scsihw virtio-scsi-single \
  --net0 virtio,bridge=vmbr0 \
  --agent 1 \
  --ostype l26 \
  --memory 2048 \
  --cores 2

qm importdisk "${VMID}" "${IMAGE_DIR}/${IMAGE}" "${STORAGE}"
qm set "${VMID}" --scsi0 "${STORAGE}:vm-${VMID}-disk-0,discard=on,ssd=1"
qm set "${VMID}" --boot order=scsi0
qm set "${VMID}" --ipconfig0 ip=dhcp
qm set "${VMID}" --ciuser root
qm set "${VMID}" --cipassword "password"
qm template "${VMID}"
```

建议 VMID 规划：

| 系统 | 建议 VMID | 模板名 |
| --- | --- | --- |
| Debian 12 | `9012` | `debian-12-dev-template` |
| Debian 13 | `9013` | `debian-13-dev-template` |
| Ubuntu 22.04 | `9022` | `ubuntu-22.04-dev-template` |
| Ubuntu 24.04 | `9024` | `ubuntu-24.04-dev-template` |

## 克隆测试 VM

比如从模板 `9013` 克隆一台测试 VM，VMID 为 `101`：

```bash
if pvesm status | awk 'NR>1 {print $1}' | grep -qx "local-lvm"; then
  STORAGE="local-lvm"
else
  STORAGE="$(pvesm status --content images 2>/dev/null | awk 'NR==2 {print $1}')"
  [ -n "${STORAGE}" ] || STORAGE="$(pvesm status --content rootdir 2>/dev/null | awk 'NR==2 {print $1}')"
fi

qm clone 9013 101 \
  --name debian13-dev-test \
  --full 1 \
  --storage "${STORAGE}"

qm resize 101 scsi0 +22G
qm start 101
```

查看 IP：

```bash
qm guest cmd 101 network-get-interfaces
```

SSH 登录：

```bash
ssh root@虚拟机IP
```

进入系统后建议检查：

```bash
systemctl status qemu-guest-agent --no-pager
docker --version
node --version
python3 --version
command -v python3.14 >/dev/null && python3.14 --version || true
```

## Fork 后自己构建

如果你想用自己的 GitHub 仓库自动构建：

1. 点击 GitHub 页面右上角 `Fork`
2. 进入你自己的 fork 仓库
3. 打开 `Actions`
4. 如果 GitHub 提示需要启用 Actions，点击启用
5. 选择 `Build PVE Cloud Templates`
6. 点击 `Run workflow`
7. 保持默认即可开始构建

可选项：

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| `root_password` | `password` | 镜像默认 root 密码 |
| `node_major` | `24` | Node.js LTS 主版本 |
| `python_version` | `3.14.4` | 额外编译安装的 Python 版本 |
| `install_extra_python` | `true` | 是否额外编译安装 Python |
| `publish_release` | `true` | 是否发布到 GitHub Releases |
| `keep_build_tools` | `false` | 是否保留完整编译环境 |
| `apply_updates` | `true` | 是否在构建时执行系统更新 |

如果 Release 发布时报权限错误，到 fork 仓库检查：

```text
Settings -> Actions -> General -> Workflow permissions
```

确认选择 `Read and write permissions`。

## 本地构建

在 Ubuntu 22.04 / 24.04 上运行：

```bash
chmod +x ./build-pve-cloud-image.sh

IMAGE_ID=debian12 ./build-pve-cloud-image.sh
IMAGE_ID=debian13 ./build-pve-cloud-image.sh
IMAGE_ID=ubuntu2204 ./build-pve-cloud-image.sh
IMAGE_ID=ubuntu2404 ./build-pve-cloud-image.sh
```

常用环境变量：

```bash
IMAGE_ID=ubuntu2404 \
WORKDIR=/tmp/pve-cloud-build/ubuntu2404 \
ROOT_PASSWORD='password' \
NODE_MAJOR=24 \
PYTHON_VERSION=3.14.4 \
INSTALL_EXTRA_PYTHON=true \
IMAGE_DISK_SIZE=8G \
KEEP_BUILD_TOOLS=false \
APPLY_UPDATES=true \
./build-pve-cloud-image.sh
```

说明：

- 默认虚拟磁盘为 `8G`
- 默认根分区为 `/dev/sda1`
- 默认清理 `snapd`、PackageKit、文档缓存和构建临时文件
- 默认执行系统更新，降低首次登录后的可升级安全更新提示
- GitHub Actions 固定使用 `ubuntu-22.04` runner，避免 `ubuntu-latest` 上 libguestfs / passt 网络栈差异
- 工作流只上传最终 `.qcow2` 和 `.qcow2.sha256`，不会上传 `*-src.qcow2`、`*-work.qcow2`
- GitHub Release 单个附件必须小于 2 GiB，工作流会在发布前检查
