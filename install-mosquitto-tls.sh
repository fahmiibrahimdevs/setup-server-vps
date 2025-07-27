#!/bin/bash

set -e

# ===== Variabel Umum =====
MQTT_USER="nexaryn"
MQTT_PASS="31750321"
MQTT_TOPIC="#"
DOMAIN="localhost"
CERT_DIR="/etc/mosquitto/certs"
PASSWD_FILE="/etc/mosquitto/passwd"
ACL_FILE="/etc/mosquitto/acl"
CONF_FILE="/etc/mosquitto/conf.d/auth.conf"

# ===== Install Mosquitto =====
echo "[INFO] Menambahkan repository Mosquitto..."
sudo add-apt-repository -y ppa:mosquitto-dev/mosquitto-ppa
sudo apt update
sudo apt install -y mosquitto mosquitto-clients

# ===== Buat Direktori Sertifikat =====
echo "[INFO] Membuat direktori sertifikat..."
sudo mkdir -p "$CERT_DIR"

# ===== Generate Sertifikat TLS =====
echo "[INFO] Membuat sertifikat TLS self-signed..."
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
 -keyout "$CERT_DIR/server.key" \
 -out "$CERT_DIR/server.crt" \
 -subj "/CN=$DOMAIN"

sudo cp "$CERT_DIR/server.crt" "$CERT_DIR/ca.crt"

# ===== Buat Password & ACL =====
echo "[INFO] Menambahkan user MQTT dan ACL..."
sudo mosquitto_passwd -b -c "$PASSWD_FILE" "$MQTT_USER" "$MQTT_PASS"

echo "user $MQTT_USER" | sudo tee "$ACL_FILE" > /dev/null
echo "topic readwrite $MQTT_TOPIC" | sudo tee -a "$ACL_FILE" > /dev/null

# ===== Buat Konfigurasi Mosquitto =====
echo "[INFO] Menulis konfigurasi Mosquitto..."
sudo tee "$CONF_FILE" > /dev/null <<EOF
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

# ===== Atur Permission =====
echo "[INFO] Mengatur permission file dan ownership..."
sudo chown -R mosquitto: /etc/mosquitto
sudo chmod 640 $CERT_DIR/*.crt
sudo chmod 600 $CERT_DIR/*.key
sudo chmod 600 "$PASSWD_FILE"
sudo chmod 600 "$ACL_FILE"

# ===== Restart dan Status =====
echo "[INFO] Restart Mosquitto..."
sudo systemctl restart mosquitto
sudo systemctl enable mosquitto
sudo systemctl status mosquitto --no-pager
