#!/bin/bash

# ==============================
# VPS Setup Script - Ubuntu 24.04
# Author: Midragon Dev (Refactored)
# Date: 2025-07-27
# ==============================

set -e

log_step() {
  echo -e "\n[$1] $2..."
  sleep 1
}

is_installed() {
  dpkg -l | grep -qw "$1"
}

### 1. Update & Upgrade
log_step "1/13" "Updating system"
apt update && apt upgrade -y
apt remove -y apache2* || true
apt-mark hold apache2 || true

### 2. Set Timezone
log_step "2/13" "Setting timezone to Asia/Jakarta"
timedatectl set-timezone Asia/Jakarta

### 3. Setup Swap
log_step "3/13" "Creating 4GB Swap"
if ! swapon --show | grep -q '/swapfile'; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
else
  echo "✅ Swap already exists."
fi

### 4. Install Tools & NGINX
log_step "4/13" "Installing tools & NGINX"
apt install -y git openssh-server unzip curl wget software-properties-common ca-certificates lsb-release htop neofetch

if ! is_installed nginx; then
  apt install -y nginx
  systemctl enable nginx
  systemctl start nginx
else
  echo "✅ NGINX already installed."
fi

### 5. Setup Firewall (UFW)
log_step "5/13" "Configuring UFW firewall"
apt install -y ufw
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw allow 1883
ufw allow 8080
ufw allow 9001
ufw allow 8883
ufw allow 9443
ufw --force enable

### 6. Install PHP 8.1–8.4
log_step "6/13" "Installing PHP versions and extensions"
add-apt-repository ppa:ondrej/php -y || true
apt update
for version in 8.1 8.2 8.3 8.4; do
  if ! is_installed php$version; then
    apt install -y php$version php$version-fpm php$version-cli php$version-common php$version-mysql \
      php$version-curl php$version-mbstring php$version-xml php$version-bcmath php$version-gd \
      php$version-zip php$version-soap php$version-intl
    systemctl enable php$version-fpm
    systemctl start php$version-fpm
    echo "✅ PHP $version installed."
  else
    echo "✅ PHP $version already installed."
  fi
done

### 7. Install Composer & Alias
log_step "7/13" "Installing Composer and aliases"
if [ ! -f /usr/local/bin/composer ]; then
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
fi

ZSHRC="$HOME/.zshrc"
if ! grep -q "composer81" "$ZSHRC"; then
  cat <<'EOL' >> "$ZSHRC"

# Composer aliases for multiple PHP versions
alias composer81='php8.1 /usr/local/bin/composer'
alias composer82='php8.2 /usr/local/bin/composer'
alias composer83='php8.3 /usr/local/bin/composer'
alias composer84='php8.4 /usr/local/bin/composer'
EOL
  echo "✅ Composer aliases added to ~/.zshrc"
else
  echo "✅ Composer aliases already exist in ~/.zshrc"
fi

### 8. Install Mosquitto MQTT (with TLS, WebSocket, Auth)
log_step "8/13" "Installing Mosquitto MQTT with TLS, WebSocket, and Auth"

CERT_DIR="/etc/mosquitto/certs"
PASSWD_FILE="/etc/mosquitto/passwd"
ACL_FILE="/etc/mosquitto/acl"
MQTT_USER="nexaryn"
MQTT_PASS="31750321"
MQTT_TOPIC="#"
DOMAIN="localhost"
CONF_FILE="/etc/mosquitto/conf.d/auth.conf"

add-apt-repository -y ppa:mosquitto-dev/mosquitto-ppa
apt update
apt install -y mosquitto mosquitto-clients

mkdir -p "$CERT_DIR"
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "$CERT_DIR/server.key" \
  -out "$CERT_DIR/server.crt" \
  -subj "/CN=$DOMAIN"
cp "$CERT_DIR/server.crt" "$CERT_DIR/ca.crt"

mosquitto_passwd -b -c "$PASSWD_FILE" "$MQTT_USER" "$MQTT_PASS"
echo "user $MQTT_USER" > "$ACL_FILE"
echo "topic readwrite $MQTT_TOPIC" >> "$ACL_FILE"

cat <<EOF > "$CONF_FILE"
# MQTT tanpa TLS
listener 1883
protocol mqtt

# WebSocket tanpa TLS
listener 9001
protocol websockets

# MQTT dengan TLS
listener 8883
protocol mqtt
cafile $CERT_DIR/ca.crt
certfile $CERT_DIR/server.crt
keyfile $CERT_DIR/server.key

# WebSocket dengan TLS
listener 9443
protocol websockets
cafile $CERT_DIR/ca.crt
certfile $CERT_DIR/server.crt
keyfile $CERT_DIR/server.key

# Auth
allow_anonymous false
password_file $PASSWD_FILE
acl_file $ACL_FILE
EOF

chown -R mosquitto: /etc/mosquitto
chmod 640 $CERT_DIR/*.crt
chmod 600 $CERT_DIR/*.key
chmod 600 "$PASSWD_FILE"
chmod 600 "$ACL_FILE"

systemctl enable mosquitto
systemctl restart mosquitto

### 9. Install MariaDB
log_step "9/13" "Installing MariaDB"
if ! is_installed mariadb-server; then
  apt install -y mariadb-server
else
  echo "✅ MariaDB already installed."
fi

mysql -u root <<EOF
CREATE USER IF NOT EXISTS 'nexaryn'@'localhost' IDENTIFIED BY '31750321@admin';
GRANT ALL PRIVILEGES ON *.* TO 'nexaryn'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

### 10. Install phpMyAdmin + NGINX config
log_step "10/13" "Installing phpMyAdmin and NGINX integration"

if ! is_installed phpmyadmin; then
  echo 'phpmyadmin phpmyadmin/dbconfig-install boolean true' | debconf-set-selections
  echo 'phpmyadmin phpmyadmin/app-password-confirm password root' | debconf-set-selections
  echo 'phpmyadmin phpmyadmin/mysql/admin-pass password root' | debconf-set-selections
  echo 'phpmyadmin phpmyadmin/mysql/app-pass password root' | debconf-set-selections
  echo 'phpmyadmin phpmyadmin/reconfigure-webserver multiselect none' | debconf-set-selections
  apt install -y phpmyadmin
else
  echo "✅ phpMyAdmin already installed."
fi

cat <<EOF > /etc/nginx/sites-available/phpmyadmin.conf
server {
    listen 8080;
    server_name _;

    root /var/www/html;
    index index.php index.html;

    location /phpmyadmin {
        alias /usr/share/phpmyadmin;
        index index.php;

        location ~ ^/phpmyadmin/(.+\.php)$ {
            alias /usr/share/phpmyadmin/\$1;
            fastcgi_pass unix:/run/php/php8.4-fpm.sock;
            fastcgi_index index.php;
            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME /usr/share/phpmyadmin/\$1;
        }

        location ~* ^/phpmyadmin/(.+\.(jpg|jpeg|gif|css|png|js|ico|html|xml|txt))$ {
            alias /usr/share/phpmyadmin/\$1;
        }
    }

    location /phpMyAdmin {
        rewrite ^/* /phpmyadmin last;
    }
}
EOF

ln -sf /etc/nginx/sites-available/phpmyadmin.conf /etc/nginx/sites-enabled/phpmyadmin.conf
nginx -t && systemctl reload nginx

### 11. Install Certbot
log_step "11/13" "Installing Certbot"
if ! is_installed certbot; then
  apt install -y certbot python3-certbot-nginx
else
  echo "✅ Certbot already installed."
fi

### 12. Install NVM & Node.js
log_step "12/13" "Installing NVM and Node.js"
export NVM_DIR="$HOME/.nvm"
if [ ! -d "$NVM_DIR" ]; then
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
fi

[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm install --lts || true

### 13. Done
log_step "13/13" "✅ Setup selesai! Silakan restart server jika diperlukan."
