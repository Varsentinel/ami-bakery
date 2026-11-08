#!/usr/bin/env bash
# Host firewall. Security groups remain the outer layer; this is the in-image
# one, and it is what makes :443 explicitly permitted rather than merely
# unblocked.
set -euxo pipefail

if [ "${ENABLE_UFW:-true}" != "true" ]; then
  ufw --force disable || true
  echo "ufw disabled by request: ingress filtering is left to security groups."
  exit 0
fi

PORTS="${FIREWALL_TCP_PORTS:-22 80 443 6443}"

ufw --force reset

ufw default deny incoming
ufw default allow outgoing

# Without this, ufw's FORWARD policy drops pod-to-pod and pod-to-service
# traffic and the cluster looks broken in ways that are hard to trace.
ufw default allow routed

# Port 22 is allowed unconditionally while the build runs, otherwise enabling
# ufw would cut off the provisioners that still have to run. If the caller did
# not ask for 22, the rule is dropped again at the end of this script; the
# live SSH session survives that because ufw permits ESTABLISHED traffic.
ufw allow 22/tcp
for port in ${PORTS}; do
  ufw allow "${port}/tcp"
done

# Cluster-internal traffic: pod CIDR, service CIDR and the flannel/CNI bridge.
# These must match cluster-cidr / service-cidr in files/k3s-config.yaml.
ufw allow from 10.42.0.0/16 comment 'k3s pod CIDR'
ufw allow from 10.43.0.0/16 comment 'k3s service CIDR'
ufw allow in on cni0
ufw allow in on flannel.1

# flannel VXLAN between nodes, if this image is ever used for a multi-node cluster.
ufw allow 8472/udp comment 'flannel vxlan'
# kubelet metrics (metrics-server).
ufw allow from 10.42.0.0/16 to any port 10250 proto tcp comment 'kubelet'

ufw --force enable

case " ${PORTS} " in
  *" 22 "*) ;;
  *)
    echo "22 not in FIREWALL_TCP_PORTS: closing SSH on the baked image."
    ufw delete allow 22/tcp
    ;;
esac

ufw status verbose
