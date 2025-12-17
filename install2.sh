#!/bin/bash
set -e

echo "🚀 شروع نصب و کانفیگ Marzban Emergency Service"

# ----------------- Update & Install -----------------
echo "🔄 آپدیت سیستم..."
apt update -y && apt upgrade -y

echo "📦 نصب پیش‌نیازها..."
apt install -y \
  curl wget git unzip \
  python3 python3-pip python3-venv \
  nginx docker.io docker-compose

systemctl enable docker
systemctl start docker

# ----------------- User Inputs -----------------
read -p "🔹 آدرس پنل (example.com): " PANEL_ADDRESS
read -p "🔹 پورت پنل: " PANEL_PORT
read -p "🔹 یوزرنیم ادمین مرزبان: " ADMIN_USER
read -sp "🔹 پسورد ادمین مرزبان: " ADMIN_PASS
echo
read -p "🔹 مسیر فایل Certificate (مثلا /etc/ssl/cert.pem): " CERT_FILE
read -p "🔹 مسیر فایل Private Key (مثلا /etc/ssl/key.pem): " PRIVKEY_FILE

# ----------------- Directories -----------------
APP_DIR="/opt/marzban/marzban-emergency"
mkdir -p "$APP_DIR"
mkdir -p /var/lib/marzban/templates/subscription

# ----------------- Download Files -----------------
echo "⬇️ دانلود فایل‌ها از GitHub..."
wget -O "$APP_DIR/Dockerfile" \
https://raw.githubusercontent.com/younex65/Marzban-Emergeny-Charge2/refs/heads/main/Dockerfile

wget -O "$APP_DIR/main.py" \
https://raw.githubusercontent.com/younex65/Marzban-Emergeny-Charge2/refs/heads/main/main.py

# Python requirements for main.py
pip3 install fastapi uvicorn requests pydantic urllib3

# ----------------- ENV File -----------------
echo "📝 ساخت فایل .env..."
cat > "$APP_DIR/.env" <<EOF
MARZBAN_BASE_URL=https://127.0.0.1:$PANEL_PORT
MARZBAN_ADMIN_USERNAME=$ADMIN_USER
MARZBAN_ADMIN_PASSWORD=$ADMIN_PASS
MARZBAN_VERIFY_SSL=false
EOF

# ----------------- docker-compose.yml -----------------
COMPOSE_FILE="/opt/marzban/docker-compose.yml"

if [ ! -f "$COMPOSE_FILE" ]; then
cat > "$COMPOSE_FILE" <<EOF
version: '3'
services:
  marzban:
    image: gozargah/marzban:latest
    restart: always
    env_file: .env
    network_mode: host
    volumes:
      - /var/lib/marzban:/var/lib/marzban

  marzban-emergency:
    build: ./marzban-emergency
    restart: always
    env_file: ./marzban-emergency/.env
    network_mode: host
    volumes:
      - ./marzban-emergency:/app
      - /var/lib/marzban:/var/lib/marzban
EOF
else
  if ! grep -q "marzban-emergency:" "$COMPOSE_FILE"; then
    sed -i '/services:/a \
  marzban-emergency:\n    build: ./marzban-emergency\n    restart: always\n    env_file: ./marzban-emergency/.env\n    network_mode: host\n    volumes:\n      - ./marzban-emergency:/app\n      - /var/lib/marzban:/var/lib/marzban\n' "$COMPOSE_FILE"
  fi
fi

# ----------------- Docker Up -----------------
cd /opt/marzban
docker-compose up -d --build

# ----------------- Nginx Config -----------------
NGINX_CONF="/etc/nginx/conf.d/emergency.conf"

cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name $PANEL_ADDRESS;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $PANEL_ADDRESS;

    ssl_certificate     $CERT_FILE;
    ssl_certificate_key $PRIVKEY_FILE;

    client_max_body_size 50M;
    proxy_read_timeout 300;
    proxy_connect_timeout 300;
    proxy_send_timeout 300;

    location / {
        proxy_pass https://127.0.0.1:$PANEL_PORT;
        proxy_ssl_verify off;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }

    location /emergency/ {
        proxy_pass http://127.0.0.1:5010/emergency/;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF

nginx -t && systemctl restart nginx

# ----------------- Template -----------------
wget -O /var/lib/marzban/templates/subscription/index.html \
https://raw.githubusercontent.com/younex65/Marzban-Emergeny-Charge2/refs/heads/main/index.html

# ----------------- Restart Marzban -----------------
marzban restart

echo "✅ نصب با موفقیت انجام شد"
echo "📌 لاگ‌ها: docker-compose logs -f marzban (با Ctrl+C خارج شو)"
