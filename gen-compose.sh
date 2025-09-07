#!/bin/bash
set -euo pipefail

# =====================================================
# Step 0: Detect MIG UUIDs
# =====================================================
echo "[STEP] Detecting MIG devices..."
# Extract only MIG UUIDs
MIG_UUIDS=($(nvidia-smi -L | grep "MIG " | sed -n 's/.*UUID: \(MIG-[^)]*\)).*/\1/p'))

if [ ${#MIG_UUIDS[@]} -lt 7 ]; then
    echo "[ERROR] Found only ${#MIG_UUIDS[@]} MIG devices, need at least 7"
    exit 1
fi

echo "[OK] Found ${#MIG_UUIDS[@]} MIG devices"

# =====================================================
# Step 1: Write .env file (limit to 7 MIGs)
# =====================================================
echo "[STEP] Writing .env file..."
> .env
for i in $(seq 1 7); do
    echo "MIG_DEVICE_${i}=${MIG_UUIDS[$((i-1))]}" >> .env
done
echo "[OK] .env file created with 7 MIG devices"

# =====================================================
# Step 2: Generate docker-compose.yml
# =====================================================
echo "[STEP] Generating docker-compose.yml..."
cat > docker-compose.yml <<EOF
version: "3.9"

services:
EOF

for i in $(seq 1 7); do
cat >> docker-compose.yml <<EOF
  tts-${i}:
    image: 074697765782.dkr.ecr.us-east-1.amazonaws.com/tts:latest
    runtime: nvidia
    env_file: .env
    environment:
      - NVIDIA_VISIBLE_DEVICES=\${MIG_DEVICE_${i}}
    networks:
      - ttsnet
    restart: unless-stopped

EOF
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

for j in $(seq 1 7); do
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

echo "[OK] docker-compose.yml generated with 7 TTS containers + nginx"

# =====================================================
# Step 3: Launch containers
# =====================================================
echo "[STEP] Starting containers..."
docker-compose up -d
