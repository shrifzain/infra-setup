#!/bin/bash
set -euo pipefail

# ==============================
# Setup logging
# ==============================
LOG_FILE="/var/log/setup.log"
sudo mkdir -p /var/log
sudo touch "$LOG_FILE"
sudo chmod 666 "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "==========================================="
echo "[START] Setup script started at $(date)"
echo "Logs will be saved to: $LOG_FILE"
echo "==========================================="

# ==============================
# Variables from arguments
# ==============================
AWS_ACCESS_KEY_ID=${1:-}
AWS_SECRET_ACCESS_KEY=${2:-}
AWS_REGION=${3:-}

if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ] || [ -z "$AWS_REGION" ]; then
  echo "[ERROR] Usage: $0 <AWS_ACCESS_KEY_ID> <AWS_SECRET_ACCESS_KEY> <AWS_REGION>"
  exit 1
fi

# ==============================
# Install dependencies
# ==============================
echo "[STEP] Installing system dependencies..."
sudo apt-get update -y
sudo apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    unzip \
    git

# ==============================
# Install Docker
# ==============================
echo "[STEP] Installing Docker..."
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo systemctl enable docker
sudo systemctl restart docker

echo "[OK] Docker installed successfully"

# ==============================
# Install AWS CLI v2
# ==============================
echo "[STEP] Installing AWS CLI..."
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -o awscliv2.zip
sudo ./aws/install --update
rm -rf aws awscliv2.zip

echo "[OK] AWS CLI installed successfully"

# ==============================
# Install NVIDIA Container Toolkit
# ==============================
echo "[STEP] Installing NVIDIA Container Toolkit..."
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
curl -s -L https://nvidia.github.io/libnvidia-container/gpgkey | \
  sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit.gpg

sudo apt-get update -y
sudo apt-get install -y nvidia-container-toolkit

sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

echo "[OK] NVIDIA Container Toolkit installed successfully"

# ==============================
# Configure AWS CLI
# ==============================
echo "[STEP] Configuring AWS CLI..."
aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID"
aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
aws configure set default.region "$AWS_REGION"

echo "[OK] AWS CLI configured"

# ==============================
# Login to ECR (optional)
# ==============================
echo "[STEP] Logging into AWS ECR (if access granted)..."
if aws sts get-caller-identity >/dev/null 2>&1; then
  aws ecr get-login-password --region $AWS_REGION | \
      sudo docker login --username AWS --password-stdin \
      $(aws sts get-caller-identity --query "Account" --output text).dkr.ecr.$AWS_REGION.amazonaws.com || true
  echo "[OK] ECR login attempted"
else
  echo "[WARN] Skipping ECR login (invalid AWS credentials?)"
fi

# ==============================
# Run Docker Compose
# ==============================
SCRIPT_DIR=$(dirname "$(realpath "$0")")
cd "$SCRIPT_DIR"

echo "[STEP] Starting Docker Compose..."
sudo docker compose up -d

echo "[OK] Docker Compose started"

# ==============================
# Finish
# ==============================
echo "==========================================="
echo "[DONE] Setup finished successfully at $(date)"
echo "Logs saved to: $LOG_FILE"
echo "==========================================="
