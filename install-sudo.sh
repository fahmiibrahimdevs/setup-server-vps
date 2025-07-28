#!/bin/bash

# ==============================
# VPS Setup Script - Ubuntu 24.04 (sudo-friendly)
# Author: Midragon Dev (Refactored)
# Date: 2025-07-27
# ==============================

set -e

REAL_USER="${SUDO_USER:-$USER}"
USER_HOME=$(eval echo "~$REAL_USER")
ZSHRC="$USER_HOME/.zshrc"

log_step() {
  echo -e "\n[$1] $2..."
  sleep 1
}

is_installed() {
  dpkg -l | grep -qw "$1"
}

### 1. Update & Upgrade
log_step "1/13" "Updating system"
sudo apt update && sudo apt upgrade -y
sudo apt remove -y apache2* || true
sudo apt-mark hold apache2 || true

### 2. Set Timezone
log_step "2/13" "Setting timezone to Asia/Jakarta"
sudo timedatectl set-timezone Asia/Jakarta

### 3. Setup Swap
log_step "3/13" "Creating 4GB Swap"
if ! sudo swapon --show | grep -q '/swapfile'; then
  sudo fallocate -l 4G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
else
  echo "✅ Swap already exists."
fi

### 4. Install Tools & NGINX
log_step "4/13" "Installing tools & NGINX"
sudo apt install -y git openssh-server unzip curl wget software-properties-common ca-certificates lsb-release htop neofetch

if ! is_installed nginx; then
  sudo apt install -y nginx
  sudo systemctl enable nginx
  sudo systemctl start nginx
else
  echo "✅ NGINX already installed."
fi

### 5. Setup Firewall (UFW)
log_step "5/13" "Configuring UFW firewall"
sudo apt install -y ufw
sudo ufw allow OpenSSH
sudo ufw allow 'Nginx Full'
sudo ufw allow 1883
sudo ufw allow 8080
sudo ufw allow 9001
sudo ufw allow 8883
sudo ufw allow 9443
sudo ufw --force enable

### 6. Install PHP 8.1–8.4
log_step "6/13" "Installing PHP versions and extensions"
sudo add-apt-repository ppa:ondrej/php -y || true
sudo apt update

for version in 8.1 8.2 8.3 8.4; do
  if ! is_installed php$version; then
    sudo apt install -y php$version php$version-fpm php$version-cli php$version-common php$version-mysql \
      php$version-curl php$version-mbstring php$version-xml php$version-bcmath php$version-gd \
      php$version-zip php$version-soap php$version-intl
    sudo systemctl enable php$version-fpm
    sudo systemctl start php$version-fpm
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

if [ -f "$ZSHRC" ] && ! grep -q "composer81" "$ZSHRC"; then
  cat <<'EOL' | sudo tee -a "$ZSHRC" > /dev/null

# Composer aliases for multiple PHP versions
alias composer81='php8.1 /usr/local/bin/composer'
alias composer82='php8.2 /usr/local/bin/composer'
alias composer83='php8.3 /usr/local/bin/composer'
alias composer84='php8.4 /usr/local/bin/composer'
EOL
  echo "✅ Composer aliases added to $ZSHRC"
else
  echo "✅ Composer aliases already exist in $ZSHRC"
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

sudo add-apt-repository -y ppa:mosquitto-dev/mosquitto-ppa
sudo apt update
sudo apt install -y mosquitto mosquitto-clients

sudo mkdir -p "$CERT_DIR"
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "$CERT_DIR/server.key" \
  -out "$CERT_DIR/server.crt" \
  -subj "/CN=$DOMAIN"
sudo cp "$CERT_DIR/server.crt" "$CERT_DIR/ca.crt"

sudo mosquitto_passwd -b -c "$PASSWD_FILE" "$MQTT_USER" "$MQTT_PASS"
echo "user $MQTT_USER" | sudo tee "$ACL_FILE"
echo "topic readwrite $MQTT_TOPIC" | sudo tee -a "$ACL_FILE"

sudo tee "$CONF_FILE" > /dev/null <<EOF
listener 1883
protocol mqtt

listener 9001
protocol websockets

listener 8883
protocol mqtt
cafile $CERT_DIR/ca.crt
certfile $CERT_DIR/server.crt
keyfile $CERT_DIR/server.key

listener 9443
protocol websockets
cafile $CERT_DIR/ca.crt
certfile $CERT_DIR/server.crt
keyfile $CERT_DIR/server.key

allow_anonymous false
password_file $PASSWD_FILE
acl_file $ACL_FILE
EOF

sudo chown -R mosquitto: /etc/mosquitto
sudo chmod 640 $CERT_DIR/*.crt
sudo chmod 600 $CERT_DIR/*.key
sudo chmod 600 "$PASSWD_FILE"
sudo chmod 600 "$ACL_FILE"

sudo systemctl enable mosquitto
sudo systemctl restart mosquitto

### 9. Install MariaDB
log_step "9/13" "Installing MariaDB"
if ! is_installed mariadb-server; then
  sudo apt install -y mariadb-server
else
  echo "✅ MariaDB already installed."
fi

sudo mysql -u root <<EOF
CREATE USER IF NOT EXISTS 'nexaryn'@'localhost' IDENTIFIED BY '31750321@admin';
GRANT ALL PRIVILEGES ON *.* TO 'nexaryn'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

### 10. Install phpMyAdmin + NGINX config
log_step "10/13" "Installing phpMyAdmin and NGINX integration"
if ! is_installed phpmyadmin; then
  echo 'phpmyadmin phpmyadmin/dbconfig-install boolean true' | sudo debconf-set-selections
  echo 'phpmyadmin phpmyadmin/app-password-confirm password root' | sudo debconf-set-selections
  echo 'phpmyadmin phpmyadmin/mysql/admin-pass password root' | sudo debconf-set-selections
  echo 'phpmyadmin phpmyadmin/mysql/app-pass password root' | sudo debconf-set-selections
  echo 'phpmyadmin phpmyadmin/reconfigure-webserver multiselect none' | sudo debconf-set-selections
  sudo apt install -y phpmyadmin
else
  echo "✅ phpMyAdmin already installed."
fi

sudo tee /etc/nginx/sites-available/phpmyadmin.conf > /dev/null <<EOF
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

sudo ln -sf /etc/nginx/sites-available/phpmyadmin.conf /etc/nginx/sites-enabled/phpmyadmin.conf
sudo nginx -t && sudo systemctl reload nginx

### 11. Install Certbot
log_step "11/13" "Installing Certbot"
if ! is_installed certbot; then
  sudo apt install -y certbot python3-certbot-nginx
else
  echo "✅ Certbot already installed."
fi

### 12. Install NVM & Node.js
log_step "12/13" "Installing NVM and Node.js"
export NVM_DIR="$USER_HOME/.nvm"
if [ ! -d "$NVM_DIR" ]; then
  sudo -u "$REAL_USER" curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
fi

[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
sudo -u "$REAL_USER" bash -c "source $NVM_DIR/nvm.sh && nvm install --lts"

### 13. Done
log_step "13/13" "✅ Setup selesai! Silakan restart server jika diperlukan."
