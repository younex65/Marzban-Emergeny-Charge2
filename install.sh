#!/bin/bash
set -e

# --- 1. آپدیت و نصب nginx ---
echo "Updating system..."
sudo apt update -y && sudo apt upgrade -y

echo "Installing Nginx..."
sudo apt install -y nginx 

# --- 2. گرفتن اطلاعات از کاربر ---
read -p "Enter your panel address (e.g., panel.example.com): " PANEL_ADDR
read -p "Enter your panel port (e.g., 443): " PANEL_PORT
read -p "Enter admin username: " ADMIN_USER
read -sp "Enter admin password: " ADMIN_PASS
echo
read -p "Enter SSL certificate path: " CERT_PATH
read -p "Enter SSL private key path: " PRIV_KEY_PATH

# --- 3. ساخت پوشه marzban-emergency ---
EMERGENCY_DIR="/opt/marzban/marzban-emergency"
sudo mkdir -p "$EMERGENCY_DIR"

# --- 4. دانلود فایل main.py ---
sudo curl -L -o "$EMERGENCY_DIR/main.py" "https://raw.githubusercontent.com/younex65/Marzban-Emergeny-Charge/refs/heads/main/main.py"

# --- 5. ساخت فایل Dockerfile ---
sudo curl -L -o "$EMERGENCY_DIR/Dockerfile" "https://raw.githubusercontent.com/younex65/Marzban-Emergeny-Charge/refs/heads/main/Dockerfile"

# --- 6. ساخت فایل .env ---
cat <<EOF | sudo tee "$EMERGENCY_DIR/.env" > /dev/null
MARZBAN_BASE_URL=https://127.0.0.1:$PANEL_PORT
MARZBAN_ADMIN_USERNAME=$ADMIN_USER
MARZBAN_ADMIN_PASSWORD=$ADMIN_PASS
MARZBAN_VERIFY_SSL=false
EOF

# --- 7. ساخت فایل emergency.conf nginx ---
NGINX_CONF="/etc/nginx/conf.d/emergency.conf"
sudo tee "$NGINX_CONF" > /dev/null <<EOF
server {
    listen 80;
    server_name $PANEL_ADDR;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $PANEL_ADDR;

    ssl_certificate     $CERT_PATH;
    ssl_certificate_key $PRIV_KEY_PATH;

    client_max_body_size 50M;
    proxy_read_timeout   300;
    proxy_connect_timeout 300;
    proxy_send_timeout   300;

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

# --- 8. ساخت docker-compose.yml ---
DOCKER_COMPOSE_PATH="/opt/marzban/docker-compose.yml"
sudo tee "$DOCKER_COMPOSE_PATH" > /dev/null <<EOF
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
      - /var/lib/marzban:/var/lib/marzban
EOF

# --- 9. ساخت پوشه subscription و دانلود index.html ---
SUBS_DIR="/var/lib/marzban/templates/subscription"
sudo mkdir -p "$SUBS_DIR"
sudo curl -L -o "$SUBS_DIR/index.html" "https://raw.githubusercontent.com/younex65/Marzban-Emergeny-Charge/refs/heads/main/index.html"

# --- 10. ری استارت nginx و اجرای marzban restart ---
sudo systemctl restart nginx
sudo systemctl reload nginx

# اگر دستور marzban وجود دارد، اجرا کن
if command -v marzban >/dev/null 2>&1; then
    sudo marzban restart
fi

echo "Installation and setup completed successfully!"
