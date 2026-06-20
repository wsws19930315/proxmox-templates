#!/bin/bash
# ============================================================
# PVE 模板导入脚本
#
# 在 PVE 主机上运行，用于从 GitHub Release 下载镜像、
# 自动校验 SHA256、导入磁盘并创建 Cloud-init 模板。
#
# 最短用法：
#   bash <(wget -qO- https://raw.githubusercontent.com/vbskycn/proxmox-templates/main/import-pve-template.sh)
#
# 常用非交互用法：
#   IMAGE_ID=ubuntu2604desktop VMID=9126 bash import-pve-template.sh
# ============================================================

set -euo pipefail

REPO="${REPO:-vbskycn/proxmox-templates}"
RELEASE_TAG="${RELEASE_TAG:-}"
IMAGE_DIR="${IMAGE_DIR:-/root/cloud-image}"
ROOT_PASSWORD="${ROOT_PASSWORD:-password}"
BRIDGE="${BRIDGE:-vmbr0}"
MEMORY="${MEMORY:-}"
CORES="${CORES:-2}"
CIUSER="${CIUSER:-root}"
IPCONFIG0="${IPCONFIG0:-ip=dhcp}"
NAMESERVER="${NAMESERVER:-}"
SSHKEYS="${SSHKEYS:-}"
STORAGE="${STORAGE:-}"
VMID="${VMID:-}"
IMAGE_ID="${IMAGE_ID:-}"
ASSUME_YES="${ASSUME_YES:-false}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "缺少命令：$1"
    exit 1
  fi
}

need_cmd qm
need_cmd pvesm
need_cmd awk
need_cmd sha256sum

if command -v wget >/dev/null 2>&1; then
  DOWNLOAD_CMD="wget"
elif command -v curl >/dev/null 2>&1; then
  DOWNLOAD_CMD="curl"
else
  echo "缺少 wget 或 curl，无法下载镜像。"
  exit 1
fi

download_to() {
  local url="$1"
  local output="$2"
  if [ "${DOWNLOAD_CMD}" = "wget" ]; then
    wget -O "${output}" "${url}"
  else
    curl -fL "${url}" -o "${output}"
  fi
}

fetch_text() {
  local url="$1"
  if [ "${DOWNLOAD_CMD}" = "wget" ]; then
    wget -qO- "${url}"
  else
    curl -fsL "${url}"
  fi
}

select_storage() {
  if [ -n "${STORAGE}" ]; then
    return
  fi

  if pvesm status | awk 'NR>1 {print $1}' | grep -qx "local-lvm"; then
    STORAGE="local-lvm"
  else
    STORAGE="$(pvesm status --content images 2>/dev/null | awk 'NR==2 {print $1}')"
    if [ -z "${STORAGE}" ]; then
      STORAGE="$(pvesm status --content rootdir 2>/dev/null | awk 'NR==2 {print $1}')"
    fi
  fi

  if [ -z "${STORAGE}" ]; then
    echo "无法自动识别 PVE 存储名，请设置 STORAGE 后重试。"
    pvesm status || true
    exit 1
  fi
}

set_image_profile() {
  case "${IMAGE_ID}" in
    debian12)
      IMAGE="debian-12-genericcloud-amd64-pve-custom.qcow2"
      NAME="${NAME:-debian-12-dev-template}"
      VMID="${VMID:-9012}"
      MEMORY="${MEMORY:-2048}"
      VGA="${VGA:-serial0}"
      SERIAL="${SERIAL:-true}"
      TABLET="${TABLET:-false}"
      ;;
    debian13)
      IMAGE="debian-13-genericcloud-amd64-pve-custom.qcow2"
      NAME="${NAME:-debian-13-dev-template}"
      VMID="${VMID:-9013}"
      MEMORY="${MEMORY:-2048}"
      VGA="${VGA:-serial0}"
      SERIAL="${SERIAL:-true}"
      TABLET="${TABLET:-false}"
      ;;
    ubuntu2204)
      IMAGE="ubuntu-22.04-server-cloudimg-amd64-pve-custom.qcow2"
      NAME="${NAME:-ubuntu-22.04-dev-template}"
      VMID="${VMID:-9022}"
      MEMORY="${MEMORY:-2048}"
      VGA="${VGA:-serial0}"
      SERIAL="${SERIAL:-true}"
      TABLET="${TABLET:-false}"
      ;;
    ubuntu2404)
      IMAGE="ubuntu-24.04-server-cloudimg-amd64-pve-custom.qcow2"
      NAME="${NAME:-ubuntu-24.04-dev-template}"
      VMID="${VMID:-9024}"
      MEMORY="${MEMORY:-2048}"
      VGA="${VGA:-serial0}"
      SERIAL="${SERIAL:-true}"
      TABLET="${TABLET:-false}"
      ;;
    ubuntu2604)
      IMAGE="ubuntu-26.04-server-cloudimg-amd64-pve-custom.qcow2"
      NAME="${NAME:-ubuntu-26.04-dev-template}"
      VMID="${VMID:-9026}"
      MEMORY="${MEMORY:-2048}"
      VGA="${VGA:-serial0}"
      SERIAL="${SERIAL:-true}"
      TABLET="${TABLET:-false}"
      ;;
    ubuntu2604desktop)
      IMAGE="ubuntu-26.04-desktop-cloudimg-amd64-pve-custom.qcow2"
      NAME="${NAME:-ubuntu-26.04-desktop-template}"
      VMID="${VMID:-9126}"
      MEMORY="${MEMORY:-4096}"
      VGA="${VGA:-virtio}"
      SERIAL="${SERIAL:-false}"
      TABLET="${TABLET:-true}"
      ;;
    *)
      echo "不支持的 IMAGE_ID：${IMAGE_ID}"
      echo "可选值：debian12 debian13 ubuntu2204 ubuntu2404 ubuntu2604 ubuntu2604desktop"
      exit 1
      ;;
  esac
}

choose_image_interactive() {
  if [ -n "${IMAGE_ID}" ]; then
    return
  fi

  cat <<'EOF'
请选择要创建的模板：
  1) Debian 12 服务器版
  2) Debian 13 服务器版
  3) Ubuntu 22.04 服务器版
  4) Ubuntu 24.04 服务器版
  5) Ubuntu 26.04 服务器版
  6) Ubuntu 26.04 桌面版
EOF
  read -r -p "请输入序号 [2]: " choice
  choice="${choice:-2}"
  case "${choice}" in
    1) IMAGE_ID="debian12" ;;
    2) IMAGE_ID="debian13" ;;
    3) IMAGE_ID="ubuntu2204" ;;
    4) IMAGE_ID="ubuntu2404" ;;
    5) IMAGE_ID="ubuntu2604" ;;
    6) IMAGE_ID="ubuntu2604desktop" ;;
    *) echo "无效选择：${choice}"; exit 1 ;;
  esac
}

prompt_defaults() {
  if [ "${ASSUME_YES}" = "true" ]; then
    return
  fi

  if [ ! -t 0 ]; then
    return
  fi

  read -r -p "VMID [${VMID}]: " input
  VMID="${input:-${VMID}}"

  read -r -p "模板名称 [${NAME}]: " input
  NAME="${input:-${NAME}}"

  read -r -p "PVE 存储名，留空自动识别 [${STORAGE:-auto}]: " input
  STORAGE="${input:-${STORAGE}}"

  read -r -p "网络桥接 [${BRIDGE}]: " input
  BRIDGE="${input:-${BRIDGE}}"

  read -r -p "Cloud-init IP 配置 [${IPCONFIG0}]: " input
  IPCONFIG0="${input:-${IPCONFIG0}}"

  read -r -p "DNS 服务器，留空不单独设置 [${NAMESERVER:-empty}]: " input
  NAMESERVER="${input:-${NAMESERVER}}"
}

get_latest_release() {
  if [ -n "${RELEASE_TAG}" ]; then
    return
  fi

  RELEASE_TAG="$(fetch_text "https://api.github.com/repos/${REPO}/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
  if [ -z "${RELEASE_TAG}" ]; then
    echo "无法获取最新 Release 标签，请检查网络或 GitHub API 访问。"
    exit 1
  fi
}

download_image() {
  local base_url="https://github.com/${REPO}/releases/download/${RELEASE_TAG}"

  mkdir -p "${IMAGE_DIR}"
  cd "${IMAGE_DIR}"

  echo "下载 SHA256：${IMAGE}.sha256"
  download_to "${base_url}/${IMAGE}.sha256" "${IMAGE}.sha256"

  echo "下载镜像：${IMAGE}"
  if download_to "${base_url}/${IMAGE}" "${IMAGE}"; then
    :
  else
    echo "完整镜像不存在或下载失败，尝试下载分卷..."
    rm -f "${IMAGE}" "${IMAGE}.part-"*
    local part=0
    while true; do
      local part_name
      part_name="$(printf '%s.part-%03d' "${IMAGE}" "${part}")"
      if ! download_to "${base_url}/${part_name}" "${part_name}"; then
        rm -f "${part_name}"
        break
      fi
      part=$((part + 1))
    done
    if [ "${part}" -eq 0 ]; then
      echo "无法下载镜像或分卷：${IMAGE}"
      exit 1
    fi
    cat "${IMAGE}.part-"* > "${IMAGE}"
  fi

  awk -v image="${IMAGE}" '{print $1 "  " image}' "${IMAGE}.sha256" | sha256sum -c -
}

create_template() {
  if qm status "${VMID}" >/dev/null 2>&1; then
    echo "VMID ${VMID} 已存在，请换一个 VMID 或先删除旧 VM。"
    exit 1
  fi

  local qm_args=(
    create "${VMID}"
    --machine q35
    --cpu cputype=host
    --name "${NAME}"
    --scsi2 "${STORAGE}:cloudinit"
    --scsihw virtio-scsi-single
    --net0 "virtio,bridge=${BRIDGE}"
    --agent 1
    --ostype l26
    --memory "${MEMORY}"
    --cores "${CORES}"
  )

  if [ "${SERIAL}" = "true" ]; then
    qm_args+=(--serial0 socket --vga serial0)
  else
    qm_args+=(--vga "${VGA}")
  fi

  if [ "${TABLET}" = "true" ]; then
    qm_args+=(--tablet 1)
  fi

  qm "${qm_args[@]}"
  qm importdisk "${VMID}" "${IMAGE_DIR}/${IMAGE}" "${STORAGE}"
  qm set "${VMID}" --scsi0 "${STORAGE}:vm-${VMID}-disk-0,discard=on,ssd=1"
  qm set "${VMID}" --boot order=scsi0
  qm set "${VMID}" --ipconfig0 "${IPCONFIG0}"
  qm set "${VMID}" --ciuser "${CIUSER}"
  qm set "${VMID}" --cipassword "${ROOT_PASSWORD}"

  if [ -n "${NAMESERVER}" ]; then
    qm set "${VMID}" --nameserver "${NAMESERVER}"
  fi

  if [ -n "${SSHKEYS}" ]; then
    qm set "${VMID}" --sshkeys "${SSHKEYS}"
  fi

  qm template "${VMID}"
}

choose_image_interactive
set_image_profile
prompt_defaults
select_storage
get_latest_release

cat <<EOF
============================================================
PVE 模板导入配置
Release：${RELEASE_TAG}
镜像 ID：${IMAGE_ID}
镜像文件：${IMAGE}
VMID：${VMID}
模板名：${NAME}
存储：${STORAGE}
内存：${MEMORY} MB
CPU：${CORES}
网络：${BRIDGE}
IP 配置：${IPCONFIG0}
DNS：${NAMESERVER:-未单独设置}
============================================================
EOF

if [ "${ASSUME_YES}" != "true" ] && [ -t 0 ]; then
  read -r -p "确认创建模板？[Y/n]: " confirm
  confirm="${confirm:-Y}"
  case "${confirm}" in
    Y|y|YES|yes) ;;
    *) echo "已取消。"; exit 0 ;;
  esac
fi

download_image
create_template

echo "============================================================"
echo "模板创建完成：${VMID} / ${NAME}"
echo "默认登录：${CIUSER} / ${ROOT_PASSWORD}"
if [[ "${IMAGE_ID}" == *desktop ]]; then
  echo "桌面版提示：首次进入图形界面时建议按发行版设置向导创建普通桌面用户。"
  echo "桌面网络和固定 IP 也可在首次进入桌面后通过系统设置调整。"
fi
echo "克隆测试示例：qm clone ${VMID} 101 --name test-${IMAGE_ID} --full 1 --storage ${STORAGE}"
echo "============================================================"
