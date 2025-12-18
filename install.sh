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

# --- 4. ساخت فایل main.py ---
cat <<'EOF' | sudo tee "$EMERGENCY_DIR/main.py" > /dev/null
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
import os, requests, time, json, threading, urllib3
from pydantic import BaseModel
from typing import Optional

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

MARZBAN_BASE = os.getenv("MARZBAN_BASE_URL", "").rstrip("/")
ADMIN_USER = os.getenv("MARZBAN_ADMIN_USERNAME", "")
ADMIN_PASS = os.getenv("MARZBAN_ADMIN_PASSWORD", "")
VERIFY_SSL = os.getenv("MARZBAN_VERIFY_SSL", "false").lower() == "true"

_token_cache = {"access": None, "exp": 0}
_token_lock = threading.Lock()
STORE_PATH = "/var/lib/marzban/emergency_flags.json"
if not os.path.isdir("/var/lib/marzban"):
    os.makedirs("/var/lib/marzban", exist_ok=True)

def load_store():
    try:
        with open(STORE_PATH) as f:
            return json.load(f)
    except:
        return {}

def save_store(d):
    tmp = STORE_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
    os.replace(tmp, STORE_PATH)

def get_new_token():
    url = f"{MARZBAN_BASE}/api/admin/token"
    data = {"username": ADMIN_USER, "password": ADMIN_PASS, "grant_type": "password"}
    r = requests.post(url, data=data, verify=VERIFY_SSL, timeout=10)
    if r.status_code != 200:
        raise Exception(f"Token error {r.status_code}: {r.text}")
    js = r.json()
    token = js.get("access_token")
    exp = js.get("exp", int(time.time()) + 3600)
    if not token:
        raise Exception("No access_token returned")
    return token, exp

def get_token():
    now = time.time()
    with _token_lock:
        if _token_cache["access"] and now < _token_cache["exp"] - 10:
            return _token_cache["access"]
        tok, exp = get_new_token()
        _token_cache["access"] = tok
        _token_cache["exp"] = exp
        return tok

def marz_get(path: str):
    t = get_token()
    headers = {"Authorization": f"Bearer {t}"}
    url = f"{MARZBAN_BASE}{path}"
    r = requests.get(url, headers=headers, verify=VERIFY_SSL)
    if r.status_code == 401:
        with _token_lock:
            _token_cache["exp"] = 0
        t = get_token()
        headers["Authorization"] = f"Bearer {t}"
        r = requests.get(url, headers=headers, verify=VERIFY_SSL)
    if r.status_code != 200:
        raise Exception(f"GET {path} failed: {r.status_code} {r.text}")
    return r.json()

def marz_put(path: str, payload: dict):
    t = get_token()
    headers = {"Authorization": f"Bearer {t}", "Content-Type": "application/json"}
    url = f"{MARZBAN_BASE}{path}"
    r = requests.put(url, json=payload, headers=headers, verify=VERIFY_SSL)
    if r.status_code == 401:
        with _token_lock:
            _token_cache["exp"] = 0
        t = get_token()
        headers["Authorization"] = f"Bearer {t}"
        r = requests.put(url, json=payload, headers=headers, verify=VERIFY_SSL)
    if r.status_code not in (200, 204):
        raise Exception(f"PUT {path} failed: {r.status_code} {r.text}")
    return True

app = FastAPI()
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

class GrantRequest(BaseModel):
    add_bytes: int
    add_seconds: int

def to_int(v):
    try:
        return int(v)
    except:
        return 0

@app.get("/emergency/{username}")
def check(username: str):
    store = load_store()
    rec = store.get(username)
    if not rec:
        return {"username": username, "used": False}
    try:
        user = marz_get(f"/api/user/{username}")
    except Exception as e:
        return {"username": username, "used": True, "error": str(e)}
    cur_limit = to_int(user.get("data_limit"))
    cur_exp = to_int(user.get("expire"))
    old_limit = to_int(rec.get("saved_data_limit"))
    old_exp = to_int(rec.get("saved_expire"))
    if cur_limit > old_limit or cur_exp > old_exp:
        store.pop(username, None)
        save_store(store)
        return {"username": username, "used": False, "renewed": True}
    return {"username": username, "used": True, "record": rec}

@app.post("/emergency/{username}/grant")
def grant(username: str, body: GrantRequest, req: Request):
    referer = req.headers.get("referer", "")
    origin = req.headers.get("origin", "")
    if not referer and not origin:
        raise HTTPException(403, "Forbidden")
    store = load_store()
    if store.get(username, {}).get("used"):
        raise HTTPException(400, "Already used")
    try:
        user = marz_get(f"/api/user/{username}")
    except Exception as e:
        raise HTTPException(500, str(e))
    now = int(time.time())
    cur_limit = to_int(user.get("data_limit"))
    cur_exp = to_int(user.get("expire"))
    new_limit = cur_limit + body.add_bytes
    base = cur_exp if cur_exp > now else now
    new_exp = base + body.add_seconds
    marz_put(f"/api/user/{username}", {"data_limit": new_limit, "expire": new_exp})
    store[username] = {
        "used": True,
        "granted_at": now,
        "saved_data_limit": cur_limit,
        "saved_expire": cur_exp,
        "granted_data_limit": new_limit,
        "granted_expire": new_exp
    }
    save_store(store)
    return {"ok": True, "username": username}
EOF

# --- 5. ساخت فایل Dockerfile ---
cat <<'EOF' | sudo tee "$EMERGENCY_DIR/Dockerfile" > /dev/null
FROM python:3.10-slim

ENV PYTHONUNBUFFERED=1
WORKDIR /app

RUN pip install --no-cache-dir fastapi uvicorn requests python-dotenv

COPY main.py /app/main.py
COPY .env /app/.env

EXPOSE 5010

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "5010"]
EOF

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
sudo curl -L -o "$SUBS_DIR/index.html" "https://raw.githubusercontent.com/younex65/Marzban-Emergeny-Charge2/refs/heads/main/index.html"

# --- 10. ری استارت nginx و اجرای marzban restart ---
sudo systemctl restart nginx
sudo systemctl reload nginx

# اگر دستور marzban وجود دارد، اجرا کن
if command -v marzban >/dev/null 2>&1; then
    sudo marzban restart
fi

echo "Installation and setup completed successfully!"
