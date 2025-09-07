#!/bin/bash
set -euo pipefail

LOG_FILE="setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[INFO] Starting setup at $(date)"

# =====================================================
# Parse AWS credentials from args
# =====================================================
if [ $# -ne 3 ]; then
    echo "[USAGE] $0 <AWS_ACCESS_KEY_ID> <AWS_SECRET_ACCESS_KEY> <AWS_REGION>"
    exit 1
fi

AWS_ACCESS_KEY_ID=$1
AWS_SECRET_ACCESS_KEY=$2
AWS_REGION=$3

echo "[STEP] Using AWS Region: $AWS_REGION"

# =====================================================
# Config: Non-interactive apt
# =====================================================
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

APP_DIR="$HOME/tts"
mkdir -p "$APP_DIR"
cd "$APP_DIR"

# =====================================================
# Step 0: Ensure repo helper files exist
# =====================================================
if [ ! -f gen-compose.sh ]; then
    echo "[STEP] Downloading gen-compose.sh..."
    curl -s -o gen-compose.sh https://raw.githubusercontent.com/shrifzain/infra-setup/master/gen-compose.sh
    chmod +x gen-compose.sh
fi

if [ ! -f nginx.conf ]; then
    echo "[STEP] Downloading nginx.conf..."
    curl -s -o nginx.conf https://raw.githubusercontent.com/shrifzain/infra-setup/master/nginx.conf
fi

# =====================================================
# Step 1: Install prerequisites
# =====================================================
echo "[STEP] Installing prerequisites..."
sudo apt-get update -yq
sudo apt-get install -yq --no-install-recommends \
    curl unzip git apt-transport-https ca-certificates gnupg lsb-release

# =====================================================
# Step 2: Install Docker if not installed
# =====================================================
if ! command -v docker &>/dev/null; then
    echo "[STEP] Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
else
    echo "[SKIP] Docker already installed"
fi

# =====================================================
# Step 3: Install Docker Compose if not installed
# =====================================================
if ! command -v docker-compose &>/dev/null; then
    echo "[STEP] Installing Docker Compose..."
    DOCKER_COMPOSE_VERSION="1.29.2"
    sudo curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
        -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
else
    echo "[SKIP] Docker Compose already installed"
fi

# =====================================================
# Step 4: Install AWS CLI if not installed
# =====================================================
if ! command -v aws &>/dev/null; then
    echo "[STEP] Installing AWS CLI..."
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip -o awscliv2.zip
    sudo ./aws/install
    rm -rf aws awscliv2.zip
else
    echo "[SKIP] AWS CLI already installed"
fi

# =====================================================
# Step 5: Install NVIDIA Container Toolkit if not installed
# =====================================================
if ! dpkg -l | grep -q nvidia-container-toolkit; then
    echo "[STEP] Installing NVIDIA Container Toolkit..."
    curl -s -L https://nvidia.github.io/libnvidia-container/gpgkey | \
        sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit.gpg] https://#' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    sudo apt-get update -yq
    sudo apt-get install -yq --no-install-recommends nvidia-container-toolkit
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker
else
    echo "[SKIP] NVIDIA Container Toolkit already installed"
fi

# =====================================================
# Step 6: Configure AWS CLI and ECR login
# =====================================================
echo "[STEP] Configuring AWS CLI..."
aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID"
aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
aws configure set region "$AWS_REGION"

ECR_REGISTRY="074697765782.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "[STEP] Logging in to ECR: $ECR_REGISTRY..."
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"

# =====================================================
# Step 7: Run MIG docker-compose generator
# =====================================================
echo "[STEP] Generating docker-compose.yml via gen-compose.sh..."
./gen-compose.sh

# =====================================================
# Step 8: Start containers
# =====================================================
echo "[STEP] Starting containers..."
docker-compose up -d

echo "[SUCCESS] Setup completed at $(date)"
