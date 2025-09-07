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
# Non-interactive apt mode
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a   # auto-restart services silently

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
sudo apt-mark hold linux-image-generic linux-headers-generic
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
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit.gpg] https://#' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
curl -s -L https://nvidia.github.io/libnvidia-container/gpgkey | \
  sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit.gpg
sudo apt-mark hold linux-image-generic linux-headers-generic
sudo apt-get update -yq
sudo apt-get install -yq --no-install-recommends nvidia-container-toolkit
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
echo "[STEP] Configuring NVIDIA MIG slices..."
sudo nvidia-smi -i 0 -mig 1 || true
sudo nvidia-smi mig -i 0 -cgi 19,19,19,19,19,19,19,20
sudo nvidia-smi mig -i 0 -cci
sleep 5
echo "[OK] MIG configured"

# ------------------------------
echo "[STEP] Preparing project directory (tts)..."
mkdir -p tts
cd tts

echo "[STEP] Downloading nginx.conf from repo..."
curl -s -o nginx.conf "$REPO_RAW_BASE/nginx.conf"

# ------------------------------
echo "[STEP] Generating docker-compose.yml with MIG UUIDs..."

MIG_UUIDS=($(nvidia-smi -L | grep "MIG" | awk -F '[()]' '{print $2}'))

cat > docker-compose.yml <<EOF
version: "3.9"

services:
EOF

i=1
for UUID in "${MIG_UUIDS[@]}"; do
cat >> docker-compose.yml <<EOF
  tts-$i:
    image: 074697765782.dkr.ecr.us-east-1.amazonaws.com/tts:latest
    runtime: nvidia
    environment:
      - NVIDIA_VISIBLE_DEVICES=$UUID
    networks:
      - ttsnet
    restart: unless-stopped

EOF
i=$((i+1))
done

cat >> docker-compose.yml <<EOF
  nginx:
    image: nginx:stable
    container_name: nginx_lb
    volumes:
      - $(pwd)/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    ports:
      - "8080:8080"
      - "5001:5001"
    depends_on:
EOF

for j in $(seq 1 ${#MIG_UUIDS[@]}); do
  echo "      - tts-$j" >> docker-compose.yml
done

cat >> docker-compose.yml <<EOF
    networks:
      - ttsnet
    restart: unless-stopped

networks:
  ttsnet:
    driver: bridge
EOF

echo "[OK] docker-compose.yml generated with ${#MIG_UUIDS[@]} MIG devices"

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
