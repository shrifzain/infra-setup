#!/bin/bash
set -euo pipefail

echo "[STEP] Detecting MIG UUIDs..."
MIG_UUIDS=($(nvidia-smi -L | grep "MIG-" | awk -F '[()]' '{print $2}' | grep -v '^$'))

if [ ${#MIG_UUIDS[@]} -eq 0 ]; then
    echo "[ERROR] No MIG devices found. Exiting."
    exit 1
fi

echo "[OK] Found ${#MIG_UUIDS[@]} MIG devices"

# =====================================================
# Step 1: Write .env file with MIG UUIDs
# =====================================================
echo "[STEP] Writing .env file..."
> .env
i=1
for UUID in "${MIG_UUIDS[@]}"; do
    echo "MIG_DEVICE_${i}=${UUID}" >> .env
    ((i++))
done
echo "[OK] .env file created with $((i-1)) MIG devices"

# =====================================================
# Step 2: Generate docker-compose.yml
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
    env_file: .env
    environment:
      - NVIDIA_VISIBLE_DEVICES=\${MIG_DEVICE_${i}}
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
      - $(pwd)/nginx.conf:/etc/nginx/conf.d/default.conf:ro
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
# Step 3: Launch containers
# =====================================================
echo "[STEP] Starting containers..."
docker-compose up -d
