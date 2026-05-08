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
- Python：保留系统 `python3`，额外安装 `/usr/local/bin/python3.14`

默认模板偏轻量：编译 Python 3.14 所需的 `gcc`、`g++`、`make`、`cmake`、`build-essential` 等工具会临时安装，构建结束后清理。运行工作流时勾选 `keep_build_tools` 可保留完整编译环境。

默认 root 登录：

```text
用户：root
密码：password
SSH：22
```

公开环境请首次启动后立即改密码，或使用 Cloud-init 注入 SSH 公钥。

## 在 PVE 上直接使用 Release 镜像

先确认存储名：

```bash
pvesm status
```

默认安装通常是 `local-lvm`。如果你的存储名不同，把下面命令里的 `local-lvm` 替换成实际存储名。

后续如果发布了新版本，只需要把示例里的 `RELEASE_TAG` 改成 Releases 页面里的新标签。

### Debian 12 模板

下面示例会创建 VMID `9012`，模板名 `debian-12-dev-template`。

```bash
# -----------------------------
# 1. 基础变量
# -----------------------------

# GitHub Release 标签。后续有新版本时，只需要改这里。
RELEASE_TAG="pve-cloud-templates-2026.05.08"

# Release 下载基础地址。
BASE_URL="https://github.com/vbskycn/proxmox-templates/releases/download/${RELEASE_TAG}"

# PVE 模板 VMID，建议 9000 段专门留给模板。
VMID=9012

# PVE 存储名。默认安装通常是 local-lvm，如不同请改成 pvesm status 看到的存储名。
STORAGE="local-lvm"

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
RELEASE_TAG="pve-cloud-templates-2026.05.08"
BASE_URL="https://github.com/vbskycn/proxmox-templates/releases/download/${RELEASE_TAG}"
VMID=9013
STORAGE="local-lvm"
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
RELEASE_TAG="pve-cloud-templates-2026.05.08"
BASE_URL="https://github.com/vbskycn/proxmox-templates/releases/download/${RELEASE_TAG}"
VMID=9022
STORAGE="local-lvm"
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
RELEASE_TAG="pve-cloud-templates-2026.05.08"
BASE_URL="https://github.com/vbskycn/proxmox-templates/releases/download/${RELEASE_TAG}"
VMID=9024
STORAGE="local-lvm"
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
qm clone 9013 101 \
  --name debian13-dev-test \
  --full 1 \
  --storage local-lvm

qm resize 101 scsi0 +18G
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
python3.14 --version
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
| `publish_release` | `true` | 是否发布到 GitHub Releases |
| `keep_build_tools` | `false` | 是否保留完整编译环境 |

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
IMAGE_DISK_SIZE=12G \
KEEP_BUILD_TOOLS=false \
./build-pve-cloud-image.sh
```

说明：

- 默认虚拟磁盘为 `12G`
- 默认根分区为 `/dev/sda1`
- 默认清理 `snapd`、PackageKit、文档缓存和构建临时文件
- GitHub Actions 固定使用 `ubuntu-22.04` runner，避免 `ubuntu-latest` 上 libguestfs / passt 网络栈差异
- 工作流只上传最终 `.qcow2` 和 `.qcow2.sha256`，不会上传 `*-src.qcow2`、`*-work.qcow2`
- GitHub Release 单个附件必须小于 2 GiB，工作流会在发布前检查
