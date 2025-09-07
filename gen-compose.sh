#!/bin/bash
set -euo pipefail

echo "[STEP] Detecting MIG devices..."
MIG_UUIDS=($(nvidia-smi -L | grep "MIG " | sed -n 's/.*UUID: \(MIG-[^)]*\)).*/\1/p'))

COUNT=${#MIG_UUIDS[@]}
if [ "$COUNT" -eq 0 ]; then
    echo "[ERROR] No MIG devices found. Did you enable MIG mode with 'nvidia-smi -i 0 -mig 1'?"
    exit 1
fi

echo "[OK] Found $COUNT MIG devices"

# Write .env file
echo "[STEP] Writing .env file..."
> .env
for i in $(seq 1 $COUNT); do
    echo "MIG_DEVICE_${i}=${MIG_UUIDS[$((i-1))]}" >> .env
done
echo "[OK] .env file created with $COUNT devices"

# Write docker-compose.yml
echo "[STEP] Generating docker-compose.yml..."
cat > docker-compose.yml <<EOF
version: "3.9"

services:
EOF

# Generate TTS services
for i in $(seq 1 $COUNT); do
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

# Add nginx service
cat >> docker-compose.yml <<EOF
  nginx:
    image: nginx:stable
    container_name: nginx_lb
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    ports:
      - "8080:8080"   # REST
      - "5001:5001"   # gRPC
    depends_on:
EOF

for i in $(seq 1 $COUNT); do
    echo "      - tts-${i}" >> docker-compose.yml
done

cat >> docker-compose.yml <<EOF
    networks:
      - ttsnet
    restart: unless-stopped

networks:
  ttsnet:
    driver: bridge
EOF

echo "[OK] docker-compose.yml generated with $COUNT TTS containers + nginx"
