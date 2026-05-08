# 自建 Proxmox VE 常用 Cloud Image 模板：Debian 12/13 与 Ubuntu 22.04/24.04 一键构建

最近我把自己在 PVE 上常用的系统模板整理成了一个 GitHub 仓库：

```text
https://github.com/vbskycn/proxmox-templates
```

这个项目的目标很简单：基于官方 Cloud Image，自动构建适合 Proxmox VE 使用的 Debian / Ubuntu 模板。构建完成后，直接下载 `.qcow2` 文件，在 PVE 里导入成模板，后续创建虚拟机只需要克隆模板即可。

## 支持的系统

当前一次工作流会同时构建 4 个 amd64 镜像：

| 系统 | 镜像文件 |
| --- | --- |
| Debian 12 | `debian-12-genericcloud-amd64-pve-custom.qcow2` |
| Debian 13 | `debian-13-genericcloud-amd64-pve-custom.qcow2` |
| Ubuntu 22.04 LTS | `ubuntu-22.04-server-cloudimg-amd64-pve-custom.qcow2` |
| Ubuntu 24.04 LTS | `ubuntu-24.04-server-cloudimg-amd64-pve-custom.qcow2` |

每个镜像都会附带对应的 SHA256 校验文件：

```text
*.qcow2.sha256
```

## 默认集成了哪些东西

这些模板主要面向开发、运维和轻量服务部署，所以我集成了一些常用工具。

PVE 相关：

```text
cloud-init
qemu-guest-agent
spice-vdagent
```

常用工具：

```text
wget curl git vim nano unzip zip rsync
tmux screen bash-completion less most tree jq
```

网络排障工具：

```text
net-tools iproute2 ping arping tracepath traceroute mtr-tiny dnsutils
telnet nmap iperf3 tcpdump lsof socat whois
```

性能观察工具：

```text
htop atop iotop iftop nload sysstat
```

运行时：

```text
Docker CE 官方 stable 源
Node.js 24.x LTS
系统自带 python3
额外安装 /usr/local/bin/python3.14
```

默认模板偏轻量。构建 Python 3.14 时会临时安装 `gcc`、`g++`、`make`、`cmake`、`build-essential` 等编译工具，构建完成后默认清理。如果想做完整开发模板，可以在 GitHub Actions 里勾选 `keep_build_tools`，这样会保留完整编译环境。

默认登录信息：

```text
用户：root
密码：password
SSH：22
```

公开环境里建议首次启动后立刻修改密码，或者使用 Cloud-init 注入 SSH 公钥。

## 直接下载最新 Release 镜像

项目的 Release 会按日期命名，例如：

```text
pve-cloud-templates-2026.05.08
```

在 PVE 主机上可以自动获取最新 Release 标签，并下载镜像。下面以 Debian 13 为例：

```bash
mkdir -p /root/cloud-image
cd /root/cloud-image

REPO="vbskycn/proxmox-templates"
RELEASE_TAG="$(wget -qO- "https://api.github.com/repos/${REPO}/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
BASE_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}"
IMAGE="debian-13-genericcloud-amd64-pve-custom.qcow2"

wget -O "${IMAGE}" "${BASE_URL}/${IMAGE}"
wget -O "${IMAGE}.sha256" "${BASE_URL}/${IMAGE}.sha256"
awk -v image="${IMAGE}" '{print $1 "  " image}' "${IMAGE}.sha256" | sha256sum -c -
```

如果校验输出类似下面这样，就说明文件没问题：

```text
debian-13-genericcloud-amd64-pve-custom.qcow2: OK
```

## 在 PVE 上创建模板

先自动识别 PVE 存储名。默认安装一般是 `local-lvm`，如果没有，就选择第一个支持 `images` 或 `rootdir` 的存储。

```bash
if pvesm status | awk 'NR>1 {print $1}' | grep -qx "local-lvm"; then
  STORAGE="local-lvm"
else
  STORAGE="$(pvesm status --content images 2>/dev/null | awk 'NR==2 {print $1}')"
  [ -n "${STORAGE}" ] || STORAGE="$(pvesm status --content rootdir 2>/dev/null | awk 'NR==2 {print $1}')"
fi

[ -n "${STORAGE}" ] || { echo "无法自动识别 PVE 存储名"; exit 1; }
echo "使用存储：${STORAGE}"
```

下面继续以 Debian 13 为例创建模板：

```bash
VMID=9013
NAME="debian-13-dev-template"
IMAGE="/root/cloud-image/debian-13-genericcloud-amd64-pve-custom.qcow2"

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

qm importdisk "${VMID}" "${IMAGE}" "${STORAGE}"
qm set "${VMID}" --scsi0 "${STORAGE}:vm-${VMID}-disk-0,discard=on,ssd=1"
qm set "${VMID}" --boot order=scsi0
qm set "${VMID}" --ipconfig0 ip=dhcp
qm set "${VMID}" --ciuser root
qm set "${VMID}" --cipassword "password"
qm template "${VMID}"
```

如果你的 PVE 存储类型不同，导入后的磁盘名可能不是 `vm-${VMID}-disk-0`。可以执行：

```bash
qm config "${VMID}"
```

查看 `unused0` 对应的磁盘名，再替换 `--scsi0` 后面的路径。

如果想使用 SSH 公钥登录，可以在转模板前加：

```bash
qm set "${VMID}" --sshkeys ~/.ssh/authorized_keys
```

## 建议的 VMID 规划

我习惯把模板放在 9000 段：

| 系统 | VMID | 模板名 |
| --- | --- | --- |
| Debian 12 | `9012` | `debian-12-dev-template` |
| Debian 13 | `9013` | `debian-13-dev-template` |
| Ubuntu 22.04 | `9022` | `ubuntu-22.04-dev-template` |
| Ubuntu 24.04 | `9024` | `ubuntu-24.04-dev-template` |

这样后续看到 VMID 就能大概知道模板系统版本。

## 克隆一台测试虚拟机

例如从 Debian 13 模板克隆一台测试机：

```bash
qm clone 9013 101 \
  --name debian13-dev-test \
  --full 1 \
  --storage "${STORAGE}"

qm resize 101 scsi0 +22G
qm start 101
```

查看虚拟机 IP：

```bash
qm guest cmd 101 network-get-interfaces
```

SSH 登录：

```bash
ssh root@虚拟机IP
```

进入系统后可以检查几个关键组件：

```bash
systemctl status qemu-guest-agent --no-pager
docker --version
node --version
python3 --version
python3.14 --version
```

## Fork 后自己构建

如果你想按自己的需求构建，可以直接 fork 仓库：

1. 打开 `https://github.com/vbskycn/proxmox-templates`
2. 点击右上角 `Fork`
3. 进入你自己的 fork 仓库
4. 打开 `Actions`
5. 选择 `Build PVE Cloud Templates`
6. 点击 `Run workflow`

常用选项：

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

确认选择：

```text
Read and write permissions
```

## 本地构建

如果不想用 GitHub Actions，也可以在 Ubuntu 22.04 / 24.04 主机上本地构建：

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
IMAGE_DISK_SIZE=8G \
KEEP_BUILD_TOOLS=false \
./build-pve-cloud-image.sh
```

## 构建时踩过的坑

### 1. GitHub Actions 上的 libguestfs / passt 问题

一开始使用 `ubuntu-latest` runner 时，`virt-customize` 可能会遇到：

```text
libguestfs error: passt exited with status 1
```

所以工作流固定使用 `ubuntu-22.04` runner，并显式设置：

```bash
LIBGUESTFS_BACKEND=direct
```

### 2. Debian 13 的 ext4 新特性

Debian 13 的 ext4 文件系统使用了较新的特性，Ubuntu 22.04 runner 里的 `e2fsck` 版本偏旧，直接用 `virt-resize` 扩容时可能报：

```text
unsupported feature(s): FEATURE_C12
```

现在脚本改为先用 `qemu-img resize` 扩大虚拟磁盘，再进入镜像内部执行：

```bash
growpart /dev/sda 1
resize2fs /dev/sda1
```

这样会使用目标系统自己的工具版本，兼容性更好。

### 3. 镜像空间不足

官方 Cloud Image 默认系统盘比较小。安装 Docker、Node、Python 和一些排障工具时，容易出现：

```text
No space left on device
```

现在默认虚拟磁盘为 `8G`，构建时会扩展根分区。最终 `.qcow2` 是稀疏压缩文件，下载大小主要取决于实际写入的数据，不会因为虚拟磁盘是 8G 就真的下载 8G。

### 4. Release 附件大小限制

GitHub Release 单个附件限制小于 2 GiB。工作流会在发布前检查 `.qcow2` 文件大小，如果超过限制，需要改用对象存储，或者拆分压缩包。

## 总结

这个仓库解决的是一个很实际的小问题：把常用的 Debian / Ubuntu Cloud Image 变成适合 PVE 直接克隆的模板。

它不是最小化镜像，而是偏向“拿来就能干活”的开发运维模板。对我来说，装好 `qemu-guest-agent`、Docker、Node、Python、常用排障工具，再配好 Cloud-init，比每次开新虚拟机后手工安装要舒服很多。

仓库地址：

```text
https://github.com/vbskycn/proxmox-templates
```
