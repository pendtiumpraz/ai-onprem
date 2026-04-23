#!/usr/bin/env bash
#
# Privasimu Nexus — GPU Server Prerequisites Installer
# Target: Ubuntu 22.04 / 24.04 LTS
#
# Install:
#   - NVIDIA Data Center driver (R550+)
#   - Docker Engine + Compose v2
#   - NVIDIA Container Toolkit (untuk Docker GPU passthrough)
#
# REBOOT WAJIB setelah script ini selesai.
#

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "❌ Script ini harus dijalankan sebagai root: sudo bash scripts/install-prereqs.sh"
    exit 1
fi

UBUNTU_VERSION=$(lsb_release -rs 2>/dev/null || echo "unknown")
echo "🔧 Detected Ubuntu: $UBUNTU_VERSION"

if [[ "$UBUNTU_VERSION" != "22.04" && "$UBUNTU_VERSION" != "24.04" ]]; then
    echo "⚠️  Script di-test untuk Ubuntu 22.04 / 24.04. Versi anda: $UBUNTU_VERSION"
    read -p "Lanjut anyway? [y/N] " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

echo ""
echo "===================================================="
echo " Step 1: Update system packages"
echo "===================================================="
apt-get update
apt-get upgrade -y
apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common \
    build-essential \
    wget \
    git \
    htop \
    nvtop

echo ""
echo "===================================================="
echo " Step 2: Install NVIDIA Data Center driver (R550)"
echo "===================================================="
if ! command -v nvidia-smi &> /dev/null || ! nvidia-smi &>/dev/null; then
    echo "🔽 Installing NVIDIA driver..."
    add-apt-repository -y ppa:graphics-drivers/ppa
    apt-get update
    apt-get install -y nvidia-driver-550-server nvidia-utils-550-server
    echo "✅ NVIDIA driver installed — REBOOT diperlukan setelah script selesai"
else
    echo "✅ NVIDIA driver sudah terinstall:"
    nvidia-smi | head -5
fi

echo ""
echo "===================================================="
echo " Step 3: Install Docker Engine + Compose v2"
echo "===================================================="
if ! command -v docker &> /dev/null; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    systemctl enable docker
    systemctl start docker
    echo "✅ Docker installed"
else
    echo "✅ Docker sudah terinstall: $(docker --version)"
fi

echo ""
echo "===================================================="
echo " Step 4: Install NVIDIA Container Toolkit"
echo "===================================================="
if ! command -v nvidia-ctk &> /dev/null; then
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
        gpg --dearmor -o /etc/apt/keyrings/nvidia-container-toolkit.gpg

    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/etc/apt/keyrings/nvidia-container-toolkit.gpg] https://#g' \
        > /etc/apt/sources.list.d/nvidia-container-toolkit.list

    apt-get update
    apt-get install -y nvidia-container-toolkit

    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
    echo "✅ NVIDIA Container Toolkit installed + Docker configured"
else
    echo "✅ NVIDIA Container Toolkit sudah terinstall"
fi

echo ""
echo "===================================================="
echo " Step 5: Create Privasimu service user + directories"
echo "===================================================="
id privasimu &>/dev/null || useradd -r -s /bin/bash -m -d /home/privasimu privasimu
usermod -aG docker privasimu

mkdir -p /opt/privasimu/{models,tls,logs}
chown -R privasimu:privasimu /opt/privasimu
chmod 700 /opt/privasimu
chmod 755 /opt/privasimu/models

echo "✅ User 'privasimu' + directory /opt/privasimu/ ready"

echo ""
echo "===================================================="
echo " Step 6: Firewall basic hardening (optional — review!)"
echo "===================================================="
if command -v ufw &> /dev/null; then
    echo "ℹ️  UFW detected. Skipping auto-configure — klien biasanya punya firewall policy sendiri."
    echo "   Recommended rules:"
    echo "     ufw default deny incoming"
    echo "     ufw allow from <backend-ip-range> to any port 443 comment 'Privasimu AI'"
    echo "     ufw allow from <admin-ip> to any port 22 comment 'SSH'"
    echo "     ufw enable"
fi

echo ""
echo "===================================================="
echo " ✅ INSTALL COMPLETE"
echo "===================================================="
echo ""
echo "📋 Post-install checklist:"
echo "   1. REBOOT: sudo reboot"
echo "   2. Setelah reboot, verify NVIDIA driver:    nvidia-smi"
echo "   3. Verify Docker GPU passthrough:"
echo "        docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi"
echo "   4. Download model:                           bash scripts/download-models.sh"
echo "   5. Start stack:                              bash scripts/start.sh"
echo ""
