#!/usr/bin/env bash
# Strip build-time tooling and per-instance identity so the AMI is a clean
# template.
set -euxo pipefail

# Helm was only needed to render the chart.
rm -f /usr/local/bin/helm
rm -rf /root/.cache/helm /root/.config/helm /root/.local/share/helm
rm -rf /home/ubuntu/.cache/helm /home/ubuntu/.config/helm /home/ubuntu/.local/share/helm

rm -rf /tmp/bake /tmp/kong-rendered.yaml

apt-get -y autoremove --purge
apt-get -y clean
rm -rf /var/lib/apt/lists/*

# cloud-init must treat the next boot as a first boot, or it will not pick up
# the new instance's user-data, hostname or SSH keys.
cloud-init clean --logs --seed || true
rm -rf /var/lib/cloud/instances/* /var/lib/cloud/instance

# A duplicated machine-id makes journald and DHCP leases collide across
# instances. Truncating (not deleting) tells systemd to generate a new one.
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id

# Host keys are regenerated on first boot by the ssh service.
rm -f /etc/ssh/ssh_host_*

# Logs and shell history from the build.
journalctl --rotate || true
journalctl --vacuum-time=1s || true
find /var/log -type f \( -name '*.gz' -o -name '*.1' -o -name '*.old' \) -delete
# /var/log/journal is excluded: it was just vacuumed, and truncating live
# journal files leaves journald with corrupt ones to complain about.
find /var/log -type f -not -path '/var/log/journal/*' -exec truncate -s 0 {} +

# ufw writes a dated backup of the old ruleset on every reset.
rm -f /etc/ufw/*.rules.2* /etc/ufw/*.rules.bak
rm -f /root/.bash_history /home/ubuntu/.bash_history
rm -rf /root/.ssh/authorized_keys

# Discard freed blocks. (Deliberately not zero-filling: EBS snapshots skip
# blocks that were never written, so writing zeros would *grow* the snapshot.)
sync
fstrim -av || true

echo "Image contents:"
cat /etc/ami-bakery/k3s-kong.json
