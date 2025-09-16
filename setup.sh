#!/usr/bin/env bash
set -euo pipefail

# Usage:
# curl -s https://raw.githubusercontent.com/shrifzain/infra-setup/master/run.sh | bash -s -- \
#   --aws-cli=1 --aws-access-key=XXXX --aws-secret-key=YYYY \
#   --nano=1 --conda=1 --venv=1 --supervisor=1 --nvtop=1

# Default params
AWS_CLI=0
AWS_ACCESS_KEY=""
AWS_SECRET_KEY=""
NANO=0
CONDA=0
VENV=0
SUPERVISOR=0
NVTOP=0

# Parse arguments
for arg in "$@"; do
  case $arg in
    --aws-cli=*) AWS_CLI="${arg#*=}" ;;
    --aws-access-key=*) AWS_ACCESS_KEY="${arg#*=}" ;;
    --aws-secret-key=*) AWS_SECRET_KEY="${arg#*=}" ;;
    --nano=*) NANO="${arg#*=}" ;;
    --conda=*) CONDA="${arg#*=}" ;;
    --venv=*) VENV="${arg#*=}" ;;
    --supervisor=*) SUPERVISOR="${arg#*=}" ;;
    --nvtop=*) NVTOP="${arg#*=}" ;;
    *) echo "Unknown option $arg"; exit 1 ;;
  esac
done

echo "[INFO] Updating system..."
apt-get update -y
apt-get upgrade -y

### SECTION: Nano Install
if [[ "$NANO" == "1" ]]; then
  echo "[INFO] Installing nano..."
  apt-get install -y nano
fi

### SECTION: AWS CLI Install
if [[ "$AWS_CLI" == "1" ]]; then
  echo "[INFO] Installing AWS CLI..."
  apt-get install -y unzip curl
  curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
  unzip -q awscliv2.zip
  ./aws/install
  rm -rf aws awscliv2.zip

  if [[ -n "$AWS_ACCESS_KEY" && -n "$AWS_SECRET_KEY" ]]; then
    echo "[INFO] Configuring AWS CLI..."
    mkdir -p ~/.aws
    cat > ~/.aws/credentials <<EOF
[default]
aws_access_key_id = $AWS_ACCESS_KEY
aws_secret_access_key = $AWS_SECRET_KEY
EOF
    echo "[default]" > ~/.aws/config
    echo "region = us-east-1" >> ~/.aws/config
  else
    echo "[WARN] AWS keys not provided, skipping configuration."
  fi
fi

### SECTION: Conda Install
if [[ "$CONDA" == "1" ]]; then
  echo "[INFO] Installing Miniconda..."
  curl -sLo miniconda.sh https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh
  bash miniconda.sh -b -p $HOME/miniconda
  rm miniconda.sh
  eval "$($HOME/miniconda/bin/conda shell.bash hook)"
  conda init
fi

### SECTION: venv Install
if [[ "$VENV" == "1" ]]; then
  echo "[INFO] Installing Python venv..."
  apt-get install -y python3-venv
fi

### SECTION: Supervisor Install
if [[ "$SUPERVISOR" == "1" ]]; then
  echo "[INFO] Installing Supervisor..."
  apt-get install -y supervisor
  systemctl enable supervisor
  systemctl start supervisor
fi

### SECTION: nvtop Install
if [[ "$NVTOP" == "1" ]]; then
  echo "[INFO] Installing nvtop..."
  apt-get install -y cmake libncurses5-dev libncursesw5-dev git
  git clone https://github.com/Syllo/nvtop.git
  cd nvtop
  mkdir -p build && cd build
  cmake ..
  make
  make install
  cd ../.. && rm -rf nvtop
fi

echo "[INFO] Setup completed!"
