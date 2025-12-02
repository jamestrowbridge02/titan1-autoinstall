#!/bin/bash
# Titan-1 Ultimate Installer + Fully Automated Daily Updates

chmod +x ultimate_install_autoupdate.sh

set -e

# ---------------- CONFIGURATION ------------------
TITAN_BUNDLE_URL="https://github.com/jamestrowbridge02/titan1-autoinstall/archive/refs/heads/master.zip"
DOMAIN="<YOUR_DOMAIN_HERE>"
EMAIL="<Jamestrowbridge02@gmail.com>"
INSTALL_DIR="$HOME/titan1-docker"
TELEGRAM_BOT_TOKEN="<8496293161:AAEZphPqg4SCX81PqQ-qisLCX8FDP1n4Dlg>"
TELEGRAM_CHAT_ID="<7903008196>"
SLACK_WEBHOOK_URL="<SLACK_WEBHOOK_URL>"

# ---------------- DEPENDENCIES -------------------
echo "🔧 Installing dependencies..."
sudo apt-get update
sudo apt-get install -y curl gnupg lsb-release apt-transport-https ca-certificates software-properties-common

# Docker
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker $USER
fi

# Docker Compose
if ! command -v docker-compose &>/dev/null; then
  sudo curl -L "https://github.com/docker/compose/releases/download/v2.24.1/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  sudo chmod +x /usr/local/bin/docker-compose
fi

# Node.js 20
if ! command -v node &>/dev/null || [ "$(node -v | cut -d. -f1)" -lt 20 ]; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi

# ---------------- SETUP INSTALL DIR -----------------
mkdir -p "$INSTALL_DIR" && cd "$INSTALL_DIR"

# ---------------- FUNCTION TO DEPLOY TITAN-1 -----------------
deploy_titan() {
  LATEST_FILE="titan1_latest.tar.gz"
  curl -L "$TITAN_BUNDLE_URL" -o "$LATEST_FILE"

  # Backup previous deployment
  [ -f "titan1_current.tar.gz" ] && cp titan1_current.tar.gz titan1_previous.tar.gz
  mv "$LATEST_FILE" "titan1_current.tar.gz"

  # Extract
  TMP_DIR="titan1_new"
  rm -rf "$TMP_DIR"
  mkdir "$TMP_DIR"
  tar -xzvf titan1_current.tar.gz -C "$TMP_DIR" --strip-components=1

  # Pre-deploy verification
  if ! docker run --rm -v "$PWD/$TMP_DIR":/app -w /app node:20-slim node verify_exchange.test.js; then
    echo "❌ Pre-deploy verification failed. Rolling back."
    [ -f "titan1_previous.tar.gz" ] && mv titan1_previous.tar.gz titan1_current.tar.gz
    send_alert "❌ Titan-1 auto-update failed (pre-deploy verification). Rollback executed."
    exit 1
  fi

  # Deploy
  rm -rf titan1_v5.2_bundle
  mv "$TMP_DIR" titan1_v5.2_bundle
  CPU_CORES=$(nproc --ignore=1)
  export MAX_WORKERS=$CPU_CORES

  docker-compose build
  docker-compose up -d --no-deps titan1

  # Post-deploy backup verification
  if ! docker exec titan1 node backup.js verify; then
    echo "❌ Post-deploy backup verification failed. Rolling back."
    [ -f "titan1_previous.tar.gz" ] && {
      mv titan1_previous.tar.gz titan1_current.tar.gz
      rm -rf titan1_v5.2_bundle
      mkdir titan1_v5.2_bundle
      tar -xzvf titan1_current.tar.gz -C titan1_v5.2_bundle --strip-components=1
      docker-compose build
      docker-compose up -d --no-deps titan1
    }
    send_alert "❌ Titan-1 post-deploy backup failed. Rollback executed."
    exit 1
  fi

  send_alert "✅ Titan-1 auto-update succeeded."
}

# ---------------- ALERT FUNCTION -----------------
send_alert() {
  local message="$1"
  [ ! -z "$TELEGRAM_BOT_TOKEN" ] && curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" -d chat_id="$TELEGRAM_CHAT_ID" -d text="$message"
  [ ! -z "$SLACK_WEBHOOK_URL" ] && curl -s -X POST -H 'Content-type: application/json' --data "{\"text\":\"$message\"}" $SLACK_WEBHOOK_URL
}

# ---------------- CREATE CONFIG FILES -----------------
echo "📂 Creating Dockerfile, NGINX, Prometheus, Grafana, docker-compose..."
# [Same embedded Dockerfile, nginx/titan1.conf, prometheus.yml, grafana dashboards, docker-compose.yml as previous ultimate installer]
# Reuse full content from previous ultimate_install.sh (omitted here for brevity)

# ---------------- INITIAL DEPLOY -----------------
deploy_titan

# ---------------- AUTO-UPDATE CRON -----------------
echo "⏰ Setting up daily auto-update cron..."
CRON_JOB="0 3 * * * bash $INSTALL_DIR/auto_update.sh >> $INSTALL_DIR/auto_update.log 2>&1"
echo "$CRON_JOB" | crontab -

# ---------------- CREATE auto_update.sh -----------------
cat > auto_update.sh << 'EOF'
#!/bin/bash
INSTALL_DIR="$HOME/titan1-docker"
cd "$INSTALL_DIR"
source "$INSTALL_DIR/ultimate_install_autoupdate.sh"
deploy_titan
EOF
chmod +x auto_update.sh

echo "✅ Titan-1 fully deployed, auto-updating daily, zero-touch!"
echo "Node: https://$DOMAIN:3000 | Prometheus: https://$DOMAIN:9091 | Grafana: https://$DOMAIN:3001"
