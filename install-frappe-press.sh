#!/usr/bin/env bash
# Revised Frappe Press installer for Ubuntu 22.04/24.04
# - keeps DNS / lets-encrypt interactive when needed
# - avoids piping `yes` into bench setup nginx
# - can resume from failed stage
# - writes recovery commands on failure

set -Eeuo pipefail

DOMAIN="${1:-}"
if [[ -z "$DOMAIN" ]]; then
  echo "Usage: sudo bash $0 your.domain.com"
  exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash $0 $DOMAIN"
  exit 1
fi

FRAPPE_USER="${FRAPPE_USER:-frappe}"
BENCH_DIR="/home/$FRAPPE_USER/frappe-bench"
FRAPPE_TAG="${FRAPPE_TAG:-version-15}"
PRESS_TAG="${PRESS_TAG:-v0.37.0}"
PYTHON_VERSION="${PYTHON_VERSION:-3.10}"
NODE_VERSION="${NODE_VERSION:-22.14.0}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-admin@$DOMAIN}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-$(openssl rand -base64 24)}"
SITE_ADMIN_PASSWORD="${SITE_ADMIN_PASSWORD:-$(openssl rand -base64 24)}"
SKIP_SSL="${SKIP_SSL:-0}"
START_AT="${START_AT:-}"

LOG_FILE="/var/log/frappe-press-install-$(date +%Y%m%d-%H%M%S).log"
STATE_DIR="/root/.frappe-press-installer"
STATE_FILE="$STATE_DIR/state"
CRED_FILE="/root/frappe-press-credentials.txt"
RECOVERY_FILE="/root/frappe-press-recovery.txt"
mkdir -p "$STATE_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

stage_order=(packages user mariadb services bench site production dns ssl final)

mark_done() { echo "$1" >> "$STATE_FILE"; }
is_done() { [[ -f "$STATE_FILE" ]] && grep -qx "$1" "$STATE_FILE"; }
should_run() {
  local stage="$1"
  if [[ -n "$START_AT" ]]; then
    [[ "$stage" == "$START_AT" ]] && START_AT="__started__"
    [[ "$START_AT" == "__started__" ]] || return 1
  fi
  ! is_done "$stage"
}

write_recovery() {
  cat > "$RECOVERY_FILE" <<EOF2
Frappe Press installer recovery
================================
Domain: $DOMAIN
Log: $LOG_FILE
Credentials: $CRED_FILE

Common recovery checks:
  sudo tail -200 $LOG_FILE
  sudo nginx -t
  sudo systemctl status nginx --no-pager
  sudo systemctl status supervisor --no-pager
  sudo supervisorctl status
  sudo journalctl -u nginx -n 100 --no-pager

Resume installer from failed stage:
  sudo START_AT=$CURRENT_STAGE bash $0 $DOMAIN

Manual nginx recovery:
  cd $BENCH_DIR
  sudo -u $FRAPPE_USER bench setup nginx
  sudo ln -sf $BENCH_DIR/config/nginx.conf /etc/nginx/conf.d/frappe-bench.conf
  sudo rm -f /etc/nginx/sites-enabled/default
  sudo nginx -t && sudo systemctl restart nginx

Manual DNS/multitenant recovery:
  cd $BENCH_DIR
  sudo -u $FRAPPE_USER bench config dns_multitenant on
  sudo -u $FRAPPE_USER bench setup nginx
  sudo ln -sf $BENCH_DIR/config/nginx.conf /etc/nginx/conf.d/frappe-bench.conf
  sudo nginx -t && sudo systemctl restart nginx

Manual certificate recovery - preferred interactive certbot nginx plugin:
  sudo certbot --nginx -d $DOMAIN -m $LETSENCRYPT_EMAIL --agree-tos --redirect
  sudo nginx -t && sudo systemctl restart nginx

Manual certificate recovery - bench command, interactive:
  cd $BENCH_DIR
  sudo env PATH=/home/$FRAPPE_USER/.local/bin:/usr/local/bin:/usr/bin:/usr/sbin:\$PATH bench setup lets-encrypt $DOMAIN --email $LETSENCRYPT_EMAIL
  sudo nginx -t && sudo systemctl restart nginx

If DNS is not ready yet, skip SSL and resume later:
  sudo SKIP_SSL=1 START_AT=ssl bash $0 $DOMAIN
  # after A record points to this server and port 80 is reachable:
  sudo START_AT=ssl bash $0 $DOMAIN
EOF2
  echo "Recovery notes written to $RECOVERY_FILE"
}

fail_handler() {
  local line="$1" code="$2"
  echo
  echo "ERROR: stage '$CURRENT_STAGE' failed at line $line with exit code $code"
  write_recovery
  exit "$code"
}
CURRENT_STAGE="init"
trap 'fail_handler $LINENO $?' ERR

run_stage() {
  local stage="$1"; shift
  CURRENT_STAGE="$stage"
  if should_run "$stage"; then
    echo
    echo "==> [$stage] $*"
    "$stage"
    mark_done "$stage"
  else
    echo "==> [$stage] already done, skipping"
  fi
}

safe_nginx_restart() {
  nginx -t
  systemctl restart nginx
}

packages() {
  apt update
  DEBIAN_FRONTEND=noninteractive apt upgrade -y
  DEBIAN_FRONTEND=noninteractive apt install -y \
    sudo git curl cron redis-server nginx supervisor fail2ban \
    mariadb-server mariadb-client libmariadb-dev pkg-config \
    xvfb libfontconfig wkhtmltopdf \
    build-essential libffi-dev libssl-dev \
    ca-certificates gnupg openssl \
    certbot python3-certbot-nginx ansible python3-pip
}

user() {
  if ! id "$FRAPPE_USER" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "$FRAPPE_USER"
  fi
  usermod -aG sudo "$FRAPPE_USER"
  echo "$FRAPPE_USER ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/frappe
  chmod 0440 /etc/sudoers.d/frappe
}

mariadb() {
  cat >/etc/mysql/mariadb.conf.d/99-frappe.cnf <<'EOF2'
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4
EOF2
  systemctl enable --now mariadb
  systemctl restart mariadb
  mariadb <<EOF2
ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF2
  cat > /root/.my.cnf <<EOF2
[client]
user=root
password=$MYSQL_ROOT_PASSWORD
EOF2
  chmod 600 /root/.my.cnf
}

services() {
  systemctl enable --now redis-server nginx supervisor cron
}

bench() {
  sudo -iu "$FRAPPE_USER" bash <<EOF2
set -Eeuo pipefail
if [[ ! -d ~/.nvm ]]; then
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi
export NVM_DIR="\$HOME/.nvm"
. "\$NVM_DIR/nvm.sh"
nvm install $NODE_VERSION
nvm alias default $NODE_VERSION
npm install -g yarn
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="\$HOME/.local/bin:\$PATH"
uv python install $PYTHON_VERSION
uv tool install --python $PYTHON_VERSION frappe-bench
if [[ ! -d "$BENCH_DIR" ]]; then
  bench init --frappe-branch $FRAPPE_TAG --python $PYTHON_VERSION frappe-bench
fi
cd "$BENCH_DIR"
bench get-app --branch $PRESS_TAG press https://github.com/frappe/press || true
EOF2
  ln -sf /home/$FRAPPE_USER/.local/bin/bench /usr/local/bin/bench
}

site() {
  cat > "$CRED_FILE" <<EOF2
DOMAIN=$DOMAIN
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
SITE_ADMIN_PASSWORD=$SITE_ADMIN_PASSWORD
LETSENCRYPT_EMAIL=$LETSENCRYPT_EMAIL
EOF2
  chmod 600 "$CRED_FILE"

  sudo -iu "$FRAPPE_USER" bash <<EOF2
set -Eeuo pipefail
export PATH="\$HOME/.local/bin:\$PATH"
cd "$BENCH_DIR"
if [[ ! -d "sites/$DOMAIN" ]]; then
  bench new-site "$DOMAIN" \
    --mariadb-root-password "$MYSQL_ROOT_PASSWORD" \
    --admin-password "$SITE_ADMIN_PASSWORD"
fi
bench --site "$DOMAIN" install-app press || true
bench use "$DOMAIN"
EOF2
}

production() {
  chown -R "$FRAPPE_USER:$FRAPPE_USER" "/home/$FRAPPE_USER"
  chmod o+rx "/home/$FRAPPE_USER"
  chmod -R o+rx "$BENCH_DIR/sites"

  cd "$BENCH_DIR"
  sudo -u "$FRAPPE_USER" bench setup supervisor
  ln -sf "$BENCH_DIR/config/supervisor.conf" /etc/supervisor/conf.d/frappe-bench.conf
  supervisorctl reread || true
  supervisorctl update || true
  supervisorctl restart all || true

  sudo -u "$FRAPPE_USER" bench setup nginx
  rm -f /etc/nginx/sites-enabled/default
  ln -sf "$BENCH_DIR/config/nginx.conf" /etc/nginx/conf.d/frappe-bench.conf
  safe_nginx_restart
}

dns() {
  cd "$BENCH_DIR"
  sudo -u "$FRAPPE_USER" bench config dns_multitenant on

  if [[ -f "$BENCH_DIR/config/nginx.conf" ]]; then
    cp -a "$BENCH_DIR/config/nginx.conf" "$BENCH_DIR/config/nginx.conf.bak.$(date +%Y%m%d-%H%M%S)"
  fi

  echo "bench setup nginx may ask to overwrite nginx.conf. Answer y when prompted."
  sudo -u "$FRAPPE_USER" bench setup nginx
  ln -sf "$BENCH_DIR/config/nginx.conf" /etc/nginx/conf.d/frappe-bench.conf
  rm -f /etc/nginx/sites-enabled/default
  safe_nginx_restart
}

ssl() {
  if [[ "$SKIP_SSL" == "1" ]]; then
    echo "SKIP_SSL=1 set; leaving HTTP working. Run START_AT=ssl later after DNS is ready."
    return 0
  fi

  cd "$BENCH_DIR"
  echo
  echo "Before continuing, confirm:"
  echo "  1. $DOMAIN A record points to this server"
  echo "  2. ports 80 and 443 are open"
  echo "  3. nginx -t passes"
  read -r -p "Continue with SSL certificate setup? [y/N] " answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "SSL skipped. Resume later with: sudo START_AT=ssl bash $0 $DOMAIN"; return 0 ;;
  esac

  # Use certbot directly first. It is clearer, interactive, and avoids bench permission edge cases.
  certbot --nginx -d "$DOMAIN" -m "$LETSENCRYPT_EMAIL" --agree-tos --redirect || {
    echo "certbot nginx plugin failed; trying bench setup lets-encrypt interactively."
    env "PATH=/home/$FRAPPE_USER/.local/bin:/usr/local/bin:/usr/bin:/usr/sbin:$PATH" \
      bench setup lets-encrypt "$DOMAIN" --email "$LETSENCRYPT_EMAIL"
  }

  ln -sf "$BENCH_DIR/config/nginx.conf" /etc/nginx/conf.d/frappe-bench.conf
  safe_nginx_restart
}

final() {
  supervisorctl restart all || true
  echo
  echo "Done. Open: https://$DOMAIN"
  echo "Credentials: $CRED_FILE"
  echo "Log: $LOG_FILE"
}

run_stage packages "Installing system packages"
run_stage user "Creating frappe user"
run_stage mariadb "Configuring MariaDB"
run_stage services "Starting services"
run_stage bench "Installing Node, Python, Bench, Frappe, Press"
run_stage site "Creating site and installing Press"
run_stage production "Setting up supervisor and nginx"
run_stage dns "Enabling multitenant DNS and regenerating nginx config"
run_stage ssl "Setting up HTTPS"
run_stage final "Final service restart"
