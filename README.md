# Proxmox PVE Cloud Templates

这个仓库用于构建可在 PVE / Proxmox VE 中使用的 Cloud Image 模板。

## 支持镜像

GitHub Actions 会一次性构建 4 个 amd64 镜像：

- Debian 12 genericcloud
- Debian 13 genericcloud
- Ubuntu 22.04 LTS cloudimg
- Ubuntu 24.04 LTS cloudimg

## 集成工具

模板集成以下常用工具：

- 基础工具：`wget`、`curl`、`git`、`vim`、`nano`、`unzip`、`zip`、`rsync`
- 网络工具：`net-tools`、`iproute2`、`iputils-ping`、`iputils-arping`、`iputils-tracepath`
- 排障工具：`traceroute`、`mtr-tiny`、`dnsutils`、`telnet`、`nmap`、`iperf3`、`tcpdump`、`lsof`、`socat`、`whois`
- 性能观察：`htop`、`atop`、`iotop`、`iftop`、`nload`、`sysstat`
- Shell 辅助：`tmux`、`screen`、`bash-completion`、`less`、`most`、`tree`、`jq`
- SSH / APT：`sshpass`、`ca-certificates`、`gnupg`、`lsb-release`、`apt-transport-https`
- Python 基础：`python3`、`python3-pip`、`python3-venv`、`python3-dev`、`pipx`
- 编译工具：`gcc`、`g++`、`make`、`cmake`、`pkg-config`、`build-essential`
- PVE 增强：`qemu-guest-agent`、`spice-vdagent`、`cloud-init`

运行时版本策略：

- Docker：Docker CE 官方 stable APT 仓库版本
- Node.js：NodeSource 24.x LTS
- Python：保留系统 `python3`，额外编译安装 Python 3.14.4 到 `/opt/python-3.14.4`

其中 `qemu-guest-agent` 会在镜像内安装并启用，方便 PVE 读取虚拟机 IP、执行 guest 命令和做更友好的关机操作。`spice-vdagent` 也会安装，使用 SPICE 控制台时可改善剪贴板、分辨率等桌面交互体验。

脚本会默认设置 `LIBGUESTFS_BACKEND=direct`。这样在 GitHub Actions 这类受限环境里，`virt-customize` 会直接启动 qemu appliance，避免默认后端触发 `passt` / libvirt 相关限制。

## 本地构建

在 Ubuntu 22.04 / 24.04 上运行：

```bash
chmod +x ./build-pve-cloud-image.sh

IMAGE_ID=debian12 ./build-pve-cloud-image.sh
IMAGE_ID=debian13 ./build-pve-cloud-image.sh
IMAGE_ID=ubuntu2204 ./build-pve-cloud-image.sh
IMAGE_ID=ubuntu2404 ./build-pve-cloud-image.sh
```

可通过环境变量覆盖输出路径和版本：

```bash
IMAGE_ID=ubuntu2404 \
WORKDIR=/tmp/pve-cloud-build/ubuntu2404 \
ROOT_PASSWORD='请改成自己的密码' \
NODE_MAJOR=24 \
PYTHON_VERSION=3.14.4 \
./build-pve-cloud-image.sh
```

支持的 `IMAGE_ID`：

- `debian12`
- `debian13`
- `ubuntu2204`
- `ubuntu2404`

## GitHub Actions 一次性构建并发布

进入 GitHub 仓库页面：

1. 打开 `Actions`
2. 选择 `Build PVE Cloud Templates`
3. 点击 `Run workflow`
4. 直接点击运行即可；默认 root 密码是 `password`
5. 保持 `publish_release=true`

构建完成后，4 个镜像会同时上传到：

- 当前 workflow run 的 Artifacts
- GitHub Releases 的附件

Release 名称会自动按当天日期生成，例如：

- Tag：`pve-cloud-templates-2026.05.08`
- Name：`PVE Cloud Templates 2026.05.08`

Release 附件包含每个镜像的：

- `.qcow2`
- `.qcow2.sha256`

## 导入到 PVE

### 1. 准备镜像文件

如果是本地构建，默认输出在：

```bash
~/pve-cloud-build/<IMAGE_ID>/<镜像文件名>.qcow2
```

如果是 GitHub Actions 构建，请从 Release 下载对应的 `.qcow2` 和 `.sha256`。

镜像文件名示例：

- Debian 12：`debian-12-genericcloud-amd64-pve-custom.qcow2`
- Debian 13：`debian-13-genericcloud-amd64-pve-custom.qcow2`
- Ubuntu 22.04：`ubuntu-22.04-server-cloudimg-amd64-pve-custom.qcow2`
- Ubuntu 24.04：`ubuntu-24.04-server-cloudimg-amd64-pve-custom.qcow2`

上传镜像到 PVE：

```bash
ssh root@你的PVE_IP "mkdir -p /root/cloud-image"
scp debian-12-genericcloud-amd64-pve-custom.qcow2 root@你的PVE_IP:/root/cloud-image/
```

例如：

```bash
ssh root@192.168.1.10 "mkdir -p /root/cloud-image"
scp debian-12-genericcloud-amd64-pve-custom.qcow2 root@192.168.1.10:/root/cloud-image/
```

### 2. 确认 PVE 存储名

在 PVE 主机上执行：

```bash
pvesm status
```

默认安装通常是 `local-lvm`。如果你的存储名不同，请把下面命令里的 `local-lvm` 替换成实际存储名。

### 3. 创建模板 VM

下面以 Debian 12 为例，VMID 使用 `9000`：

```bash
qm create 9000 \
  --machine q35 \
  --cpu cputype=host \
  --name "debian-12-dev-template" \
  --scsi2 "local-lvm:cloudinit" \
  --serial0 socket \
  --vga serial0 \
  --scsihw virtio-scsi-single \
  --net0 virtio,bridge=vmbr0 \
  --agent 1 \
  --ostype l26 \
  --memory 2048 \
  --cores 2
```

### 4. 导入并挂载磁盘

```bash
qm importdisk 9000 /root/cloud-image/debian-12-genericcloud-amd64-pve-custom.qcow2 local-lvm
qm set 9000 --scsi0 "local-lvm:vm-9000-disk-0,discard=on,ssd=1"
qm set 9000 --boot order=scsi0
```

### 5. 设置 Cloud-init 默认配置

```bash
qm set 9000 --ipconfig0 ip=dhcp
qm set 9000 --ciuser root
qm set 9000 --cipassword "passwd"
```

如果你在构建镜像时设置了其他 `ROOT_PASSWORD`，这里的 `--cipassword` 也建议同步改成自己的密码。公开环境更建议使用 SSH 公钥：

```bash
qm set 9000 --sshkeys ~/.ssh/authorized_keys
```

### 6. 转成模板

```bash
qm template 9000
```

Ubuntu 和 Debian 13 的导入方式相同，只需要替换镜像文件名、VMID 和模板名称。

## 克隆测试 VM

比如从模板 `9000` 克隆一台测试 VM，VMID 为 `101`：

```bash
qm clone 9000 101 \
  --name debian12-dev-test \
  --full 1 \
  --storage local-lvm
```

扩容到 30G。当前模板默认磁盘大约 3G 左右，示例增加 27G：

```bash
qm resize 101 scsi0 +27G
```

启动：

```bash
qm start 101
```

查看 IP：

```bash
qm guest cmd 101 network-get-interfaces
```

然后 SSH 登录：

```bash
ssh root@虚拟机IP
```

如果使用上面的示例 Cloud-init 密码，密码是：

```text
passwd
```

进入虚拟机后建议检查：

```bash
systemctl status qemu-guest-agent --no-pager
docker --version
node --version
python3 --version
python3.14 --version
```

## 安全提醒

公开发布的模板不建议长期使用固定 root 密码。首次启动后请立即修改密码，或者通过 cloud-init 注入自己的用户、密码和 SSH 公钥。
