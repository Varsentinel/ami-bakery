#!/usr/bin/env bash
# Base OS preparation.
set -euxo pipefail

# cloud-init is still running when Packer's SSH connection comes up; apt would
# race against it.
cloud-init status --wait || true

apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  iptables \
  jq \
  zstd \
  ufw

# k3s needs these for its iptables/conntrack handling on Ubuntu.
apt-get install -y --no-install-recommends conntrack

# Kernel modules and sysctls k3s/flannel rely on. Baking them means the first
# boot does not depend on k3s loading them itself.
cat > /etc/modules-load.d/k3s.conf <<'MODULES'
overlay
br_netfilter
MODULES

modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/99-k3s.conf <<'SYSCTL'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
# Kong and the API server both keep a lot of sockets open.
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
SYSCTL

sysctl --system

# Swap must stay off for the kubelet.
swapoff -a || true
sed -i '/\bswap\b/ s/^\([^#]\)/#\1/' /etc/fstab

install -d -m 0755 /etc/rancher/k3s /etc/rancher/k3s/config.yaml.d
