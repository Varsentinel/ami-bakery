#!/usr/bin/env bash
# Install k3s with Traefik disabled. The service is enabled but never started
# here: it comes up for the first time in 30-validate.sh, and the state that
# creates is wiped again in 40-reset-k3s.sh.
set -euxo pipefail

: "${K3S_VERSION:?}"

install -m 0600 /tmp/bake/k3s-config.yaml /etc/rancher/k3s/config.yaml

# Per-instance configuration (TLS SANs) generated at first boot.
install -m 0755 /tmp/bake/k3s-tls-san.sh /usr/local/bin/k3s-tls-san.sh
install -m 0644 /tmp/bake/k3s-tls-san.service /etc/systemd/system/k3s-tls-san.service

curl -sfL https://get.k3s.io -o /tmp/k3s-install.sh
chmod +x /tmp/k3s-install.sh

# INSTALL_K3S_SKIP_START keeps the installer from starting a server that would
# bake node certificates, a node password and a cluster token into the image.
INSTALL_K3S_VERSION="${K3S_VERSION}" \
INSTALL_K3S_SKIP_START=true \
INSTALL_K3S_EXEC="server" \
  /tmp/k3s-install.sh
rm -f /tmp/k3s-install.sh

# Guarantee the SAN drop-in exists before k3s reads its config.
install -d -m 0755 /etc/systemd/system/k3s.service.d
cat > /etc/systemd/system/k3s.service.d/10-tls-san.conf <<'DROPIN'
[Unit]
Wants=k3s-tls-san.service
After=k3s-tls-san.service
DROPIN

systemctl daemon-reload
systemctl enable k3s-tls-san.service
systemctl enable k3s.service

# The config must carry the disable list before k3s ever starts; 30-validate.sh
# checks the result in a live cluster.
grep -qE '^[[:space:]]*- traefik$' /etc/rancher/k3s/config.yaml \
  || { echo "FATAL: traefik is not in the disable list of /etc/rancher/k3s/config.yaml"; exit 1; }

k3s --version
