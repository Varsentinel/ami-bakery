#!/usr/bin/env bash
# Return k3s to a pre-first-boot state.
#
# This is the step that makes the image reusable. A k3s server that has run
# once holds a cluster CA, a node password, a server token, a sqlite datastore
# and kubelet certificates - all tied to the build instance. Baked into an AMI,
# every instance launched from it would share one identity and one set of
# secrets. Only the parts that are genuinely instance-independent are kept:
# the auto-deploy manifests and the preloaded image tarball.
set -euxo pipefail

if [ "${VALIDATE_BUILD:-true}" != "true" ]; then
  echo "k3s was never started; nothing to reset."
  exit 0
fi

# Staged on the same filesystem as the data it holds: the preloaded image
# tarball is well over a gigabyte, and /tmp is tmpfs on some Ubuntu releases.
KEEP="$(mktemp -d -p /var/lib/rancher)"

# Stop everything and unmount the pod filesystems.
/usr/local/bin/k3s-killall.sh
systemctl stop k3s || true

# k3s-killall.sh normally clears these, but a leftover containerd snapshot
# mount would make the rm -rf below fail half-way through.
awk '$2 ~ "^/var/lib/rancher/k3s|^/run/k3s" {print $2}' /proc/mounts \
  | sort -r | xargs -r umount -lf || true

mv /var/lib/rancher/k3s/server/manifests "${KEEP}/manifests"
mv /var/lib/rancher/k3s/agent/images "${KEEP}/images"

# Instance-specific state. /var/lib/rancher/k3s/data (the extracted k3s
# binaries) is deliberately left in place: it is version-specific, not
# instance-specific, and keeping it saves ~15s on first boot.
rm -rf \
  /var/lib/rancher/k3s/server \
  /var/lib/rancher/k3s/agent \
  /var/lib/kubelet \
  /var/lib/cni \
  /etc/cni/net.d \
  /etc/rancher/node \
  /etc/rancher/k3s/k3s.yaml \
  /etc/rancher/k3s/config.yaml.d/10-instance.yaml \
  /var/log/pods \
  /var/log/containers \
  /run/k3s \
  /run/flannel

install -d -m 0700 /var/lib/rancher/k3s/server
install -d -m 0700 /var/lib/rancher/k3s/agent
mv "${KEEP}/manifests" /var/lib/rancher/k3s/server/manifests
mv "${KEEP}/images" /var/lib/rancher/k3s/agent/images
rmdir "${KEEP}"

# Nothing identifying may survive.
for leftover in \
  /var/lib/rancher/k3s/server/token \
  /var/lib/rancher/k3s/server/tls \
  /var/lib/rancher/k3s/server/db \
  /var/lib/rancher/k3s/server/cred \
  /etc/rancher/node/password \
  /etc/rancher/k3s/k3s.yaml
do
  test ! -e "${leftover}" || { echo "FATAL: ${leftover} survived the reset"; exit 1; }
done

test -f /var/lib/rancher/k3s/server/manifests/kong.yaml || { echo "FATAL: Kong manifests lost"; exit 1; }
test -f /var/lib/rancher/k3s/agent/images/k3s-kong-preload.tar || { echo "FATAL: preloaded images lost"; exit 1; }

# k3s must still be set to start on boot.
systemctl is-enabled k3s.service
systemctl is-enabled k3s-tls-san.service

find /var/lib/rancher/k3s -maxdepth 3 | sort
