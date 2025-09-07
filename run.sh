#!/bin/bash
set -euo pipefail

LOG_FILE="setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[INFO] Starting setup at $(date)"

# =====================================================
# Config: Non-interactive apt
# =====================================================
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

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
# Step 6: Configure MIG mode and slices
# =====================================================
#echo "[STEP] Configuring MIG mode..."
#sudo nvidia-smi -i 0 -mig 1 || true
#sudo nvidia-smi mig -i 0 -cgi 19,19,19,19,19,19,19,20 || true
#sudo nvidia-smi mig -i 0 -cci || true

# =====================================================
# Step 7: Get MIG UUIDs (filter only MIG- lines)
# =====================================================
echo "[STEP] Detecting MIG UUIDs..."
MIG_UUIDS=($(nvidia-smi -L | grep "MIG-" | awk -F '[()]' '{print $2}'))

if [ ${#MIG_UUIDS[@]} -eq 0 ]; then
    echo "[ERROR] No MIG devices found. Exiting."
    exit 1
fi

echo "[OK] Found ${#MIG_UUIDS[@]} MIG devices"

# =====================================================
# Step 8: Prepare app directory
# =====================================================
APP_DIR="$HOME/tts"
mkdir -p "$APP_DIR"
cd "$APP_DIR"

# =====================================================
# Step 9: Generate docker-compose.yml
# =====================================================
echo "[STEP] Generating docker-compose.yml..."
cat > docker-compose.yml <<EOF
version: "3.9"

services:
EOF

i=1
for UUID in "${MIG_UUIDS[@]}"; do
cat >> docker-compose.yml <<EOF
  tts-${i}:
    image: 074697765782.dkr.ecr.us-east-1.amazonaws.com/tts:latest
    runtime: nvidia
    environment:
      - NVIDIA_VISIBLE_DEVICES=${UUID}
    networks:
      - ttsnet
    restart: unless-stopped

EOF
((i++))
done

cat >> docker-compose.yml <<EOF
  nginx:
    image: nginx:stable
    container_name: nginx_lb
    volumes:
      - $APP_DIR/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    ports:
      - "8080:8080"
      - "5001:5001"
    depends_on:
EOF

for ((j=1; j<=$((i-1)); j++)); do
    echo "      - tts-${j}" >> docker-compose.yml
done

cat >> docker-compose.yml <<EOF
    networks:
      - ttsnet
    restart: unless-stopped

networks:
  ttsnet:
    driver: bridge
EOF

echo "[OK] docker-compose.yml generated with ${#MIG_UUIDS[@]} TTS containers + nginx"

# =====================================================
# Step 10: Copy nginx.conf if in repo
# =====================================================
if [ -f "$(dirname "$0")/nginx.conf" ]; then
    cp "$(dirname "$0")/nginx.conf" "$APP_DIR/nginx.conf"
    echo "[OK] nginx.conf copied"
else
    echo "[WARN] nginx.conf not found in repo"
fi

# =====================================================
# Step 11: Run docker-compose
# =====================================================
echo "[STEP] Starting containers..."
docker-compose up -d

echo "[SUCCESS] Setup completed at $(date)"
