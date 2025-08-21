#!/bin/bash

# === CONFIGURABLES ===
REPO_SSH="git@github.com:WilliamLeite02/proway-docker.git"
DEST_DIR="/opt/pizzaria"

# === Install dependencies ===
echo "[+] Installing required packages..."
apt-get update -y
apt-get install -y docker.io docker-compose git cron

# === Enable and start Docker ===
systemctl enable docker
systemctl start docker

# === Clone or update the repository ===
if [ ! -d "$DEST_DIR" ]; then
    echo "[+] Cloning repository..."
    git clone "$REPO_SSH" "$DEST_DIR"
else
    echo "[+] Repository already exists, pulling latest changes..."
    cd "$DEST_DIR" && git pull
fi

# === Navigate to app directory and deploy with Docker Compose ===
cd "$DEST_DIR/pizzaria-app"
echo "[+] Deploying with Docker Compose..."
docker-compose down
docker-compose build --no-cache
docker-compose up -d --force-recreate

# === Add this script to crontab to run every 5 minutes ===
CRON_JOB="*/5 * * * * /root/deploy-pizzaria.sh >> /var/log/deploy-pizzaria.log 2>&1"
CRON_FILE="/var/spool/cron/crontabs/root"

# Avoid duplicate cron entries
if ! crontab -l 2>/dev/null | grep -q "deploy-pizzaria.sh"; then
    echo "[+] Adding script to crontab..."
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
fi

echo "[✓] Deployment finished at $(date)"


