#!/bin/bash
set -euo pipefail

# ------------------------------
# Logging setup
LOG_FILE="/var/log/setup.log"
sudo mkdir -p /var/log
sudo touch "$LOG_FILE"
sudo chmod 666 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "==========================================="
echo "[START] Setup script started at $(date)"
echo "Logs will be saved to: $LOG_FILE"
echo "==========================================="

# ------------------------------
# Non-interactive apt mode (no prompts, no reboots)
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a   # auto-restart services silently

# ------------------------------
# PREVENT kernel upgrades (must come before apt-get upgrade/install)
sudo apt-mark hold linux-image-generic linux-headers-generic linux-image-$(uname -r)

# ------------------------------
# Arguments
AWS_ACCESS_KEY_ID=${1:-}
AWS_SECRET_ACCESS_KEY=${2:-}
AWS_REGION=${3:-}

if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ] || [ -z "$AWS_REGION" ]; then
  echo "[ERROR] Usage: $0 <AWS_ACCESS_KEY_ID> <AWS_SECRET_ACCESS_KEY> <AWS_REGION>"
  exit 1
fi

# GitHub raw base URL (same repo as run.sh)
REPO_RAW_BASE="https://raw.githubusercontent.com/shrifzain/infra-setup/master"

# ------------------------------
echo "[STEP] Installing system dependencies..."
sudo apt-get update -yq
sudo apt-get install -yq ca-certificates curl gnupg lsb-release unzip git
echo "[OK] Base dependencies installed"

# ------------------------------
echo "[STEP] Installing Docker..."
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update -yq
sudo apt-get install -yq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable docker
sudo systemctl restart docker
echo "[OK] Docker installed successfully"

# ------------------------------
echo "[STEP] Installing AWS CLI v2..."
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -o awscliv2.zip
sudo ./aws/install --update
rm -rf aws awscliv2.zip
echo "[OK] AWS CLI installed successfully"

# ------------------------------
echo "[STEP] Installing NVIDIA Container Toolkit..."
# Add repo with signed-by option
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit.gpg] https://#' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
# Add GPG key
curl -s -L https://nvidia.github.io/libnvidia-container/gpgkey | \
  sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit.gpg
# Install toolkit silently without recommends
sudo apt-get update -yq
sudo apt-get install -yq --no-install-recommends nvidia-container-toolkit
# Configure Docker runtime
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
echo "[OK] NVIDIA Container Toolkit installed successfully"

# ------------------------------
echo "[STEP] Configuring AWS CLI..."
aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID"
aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
aws configure set default.region "$AWS_REGION"
echo "[OK] AWS CLI configured"

# ------------------------------
echo "[STEP] Logging into AWS ECR (if permitted)..."
if aws sts get-caller-identity >/dev/null 2>&1; then
  aws ecr get-login-password --region "$AWS_REGION" | \
    sudo docker login --username AWS --password-stdin \
    "$(aws sts get-caller-identity --query Account --output text).dkr.ecr.$AWS_REGION.amazonaws.com" || true
  echo "[OK] ECR login attempted"
else
  echo "[WARN] Skipping ECR login (invalid credentials?)"
fi

# ------------------------------
echo "[STEP] Preparing project directory (tts)..."
mkdir -p tts
cd tts

echo "[STEP] Downloading docker-compose.yml and nginx.conf from repo..."
curl -s -o docker-compose.yml "$REPO_RAW_BASE/docker-compose.yml"
#curl -s -o nginx.conf "$REPO_RAW_BASE/nginx.conf"
echo "[OK] Files downloaded to $(pwd)"

# ------------------------------
echo "[STEP] Running Docker Compose..."
sudo docker compose up -d 
echo "[OK] Docker Compose started"

# ------------------------------
echo "[STEP] Health-check: listing running containers"
sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"

# ------------------------------
echo "==========================================="
echo "[DONE] Setup finished successfully at $(date)"
echo "Logs saved to: $LOG_FILE"
echo "==========================================="
