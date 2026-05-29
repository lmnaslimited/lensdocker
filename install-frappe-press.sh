#!/bin/bash
set -euo pipefail

DOMAIN="${1:-}"

if [[ -z "$DOMAIN" ]]; then
  echo "Usage: $0 your.domain.com"
  exit 1
fi

FRAPPE_USER="frappe"
BENCH_DIR="/home/$FRAPPE_USER/frappe-bench"

FRAPPE_TAG="version-15"
PRESS_TAG="v0.37.0"
PYTHON_VERSION="3.10"
NODE_VERSION="22.14.0"

MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-$(openssl rand -base64 24)}"
SITE_ADMIN_PASSWORD="${SITE_ADMIN_PASSWORD:-$(openssl rand -base64 24)}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-admin@$DOMAIN}"

cat >/root/frappe-press-credentials.txt <<EOF
Domain: https://$DOMAIN
Frappe Administrator: Administrator
Frappe Admin Password: $SITE_ADMIN_PASSWORD

MariaDB root password: $MYSQL_ROOT_PASSWORD

Frappe version: $FRAPPE_TAG
Press version: $PRESS_TAG
Python version: $PYTHON_VERSION
Node version: $NODE_VERSION
EOF

chmod 600 /root/frappe-press-credentials.txt
echo "Credentials saved at: /root/frappe-press-credentials.txt"

echo "==> Installing system packages"
apt update
apt upgrade -y

apt install -y \
  sudo git curl cron redis-server nginx supervisor fail2ban \
  mariadb-server mariadb-client libmariadb-dev pkg-config \
  xvfb libfontconfig wkhtmltopdf \
  build-essential libffi-dev libssl-dev \
  ca-certificates gnupg openssl \
  certbot python3-certbot-nginx ansible

echo "==> Creating frappe user"
if ! id "$FRAPPE_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$FRAPPE_USER"
fi

usermod -aG sudo "$FRAPPE_USER"
echo "$FRAPPE_USER ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/frappe
chmod 0440 /etc/sudoers.d/frappe

echo "==> Configuring MariaDB"
cat >/etc/mysql/mariadb.conf.d/99-frappe.cnf <<'EOF'
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4
EOF

systemctl enable --now mariadb
systemctl restart mariadb

mariadb <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL

echo "==> Starting services"
systemctl enable --now redis-server
systemctl enable --now nginx
systemctl enable --now supervisor
systemctl enable --now cron

echo "==> Installing Node, Python, Bench as frappe user"
sudo -iu "$FRAPPE_USER" bash <<EOF
set -euo pipefail

export NVM_DIR="\$HOME/.nvm"

if [[ ! -s "\$NVM_DIR/nvm.sh" ]]; then
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
fi

source "\$NVM_DIR/nvm.sh"
nvm install "$NODE_VERSION"
nvm alias default "$NODE_VERSION"
nvm use "$NODE_VERSION"

npm install -g yarn@1.22

curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="\$HOME/.local/bin:\$PATH"

uv python install "$PYTHON_VERSION"
PYTHON_BIN="\$(uv python find "$PYTHON_VERSION")"

uv tool install frappe-bench --force
export PATH="\$HOME/.local/bin:\$PATH"

# Ensure bench tool venv has pip/ansible support
/home/$FRAPPE_USER/.local/share/uv/tools/frappe-bench/bin/python -m ensurepip --upgrade || true
/home/$FRAPPE_USER/.local/share/uv/tools/frappe-bench/bin/python -m pip install ansible || true

cd "\$HOME"

if [[ -d "$BENCH_DIR" ]]; then
  mv "$BENCH_DIR" "\$HOME/frappe-bench-backup-\$(date +%F-%H%M%S)"
fi

bench init \
  --frappe-branch "$FRAPPE_TAG" \
  --python "\$PYTHON_BIN" \
  frappe-bench

cd "$BENCH_DIR"

bench get-app https://github.com/frappe/press.git \
  --branch "$PRESS_TAG" \
  --skip-assets \
  --resolve-deps

bench new-site "$DOMAIN" \
  --mariadb-root-password "$MYSQL_ROOT_PASSWORD" \
  --admin-password "$SITE_ADMIN_PASSWORD"

bench use "$DOMAIN"

export NODE_OPTIONS="--max-old-space-size=3072"
export SENTRY_TELEMETRY=false

bench --site "$DOMAIN" install-app press
bench build --app press
EOF

echo "==> Fixing ownership and permissions"
chown -R "$FRAPPE_USER:$FRAPPE_USER" "/home/$FRAPPE_USER"
chmod o+rx "/home/$FRAPPE_USER"
chmod -R o+rx "$BENCH_DIR/sites"

echo "==> Making bench available to sudo"
ln -sf /home/$FRAPPE_USER/.local/bin/bench /usr/local/bin/bench

echo "==> Setting up production"
cd "$BENCH_DIR"

sudo -u "$FRAPPE_USER" bench setup supervisor

ln -sf "$BENCH_DIR/config/supervisor.conf" /etc/supervisor/conf.d/frappe-bench.conf

supervisorctl reread
supervisorctl update
supervisorctl restart all || true

sudo -u "$FRAPPE_USER" bench setup nginx

rm -f /etc/nginx/sites-enabled/default

# Ensure nginx has log_format main
if ! grep -q "log_format main" /etc/nginx/nginx.conf; then
  sed -i '/http {/a\
        log_format main '\''$remote_addr - $remote_user [$time_local] "$request" '\''\
                        '\''$status $body_bytes_sent "$http_referer" '\''\
                        '\''"$http_user_agent" "$http_x_forwarded_for"'\'';' /etc/nginx/nginx.conf
fi

nginx -t
systemctl restart nginx

echo "==> Enabling multi-tenant DNS"
sudo -u "$FRAPPE_USER" bench config dns_multitenant on

yes | sudo -u "$FRAPPE_USER" bench setup nginx

ln -sf "$BENCH_DIR/config/nginx.conf" /etc/nginx/conf.d/frappe-bench.conf

nginx -t
systemctl restart nginx

echo "==> Setting up HTTPS using Bench"
env "PATH=/home/$FRAPPE_USER/.local/bin:/usr/local/bin:/usr/bin:/usr/sbin:$PATH" \
  bench setup lets-encrypt "$DOMAIN" \
  --email "$LETSENCRYPT_EMAIL" \
  --agree-tos \
  --non-interactive

ln -sf "$BENCH_DIR/config/nginx.conf" /etc/nginx/conf.d/frappe-bench.conf

nginx -t
systemctl restart nginx
supervisorctl restart all

echo "==> Done"
echo "Open: https://$DOMAIN"
echo "Credentials saved at: /root/frappe-press-credentials.txt"
