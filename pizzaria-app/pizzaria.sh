#!/bin/bash

# === CONFIGURÁVEIS ===
REPO_SSH="https://github.com/WilliamLeite02/proway-docker.git"
DEST_DIR="/opt/pizzaria"

# === Instala dependências ===
echo "[+] Instalando pacotes necessários..."
apt-get update -y
apt-get install -y docker.io docker-compose git cron

# === Habilita e inicia Docker ===
systemctl enable docker
systemctl start docker

# === Clona ou atualiza o repositório ===
if [ ! -d "$DEST_DIR" ]; then
    echo "[+] Clonando repositório..."
    git clone "$REPO_SSH" "$DEST_DIR"
else
    echo "[+] Repositório já existe, fazendo git pull..."
    cd "$DEST_DIR" && git pull
fi

# === Sobe com Docker Compose, forçando rebuild ===
cd "$DEST_DIR/pizzaria-app"
echo "[+] Subindo com Docker Compose..."
docker-compose down
docker-compose build --no-cache
docker-compose up -d --force-recreate

# === Adiciona à crontab ===
CRON_JOB="*/5 * * * * /root/deploy-pizzaria.sh >> /var/log/deploy-pizzaria.log 2>&1"
CRON_FILE="/var/spool/cron/crontabs/root"

# Evita duplicatas no cron
if ! crontab -l 2>/dev/null | grep -q "deploy-pizzaria.sh"; then
    echo "[+] Adicionando à crontab..."
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
fi

echo "[✓] Deploy finalizado em $(date)"
