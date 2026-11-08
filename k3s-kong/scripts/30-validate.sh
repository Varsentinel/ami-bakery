#!/usr/bin/env bash
# Boot the cluster once during the build to prove the image works, then export
# every container image it pulled so first boot needs no registry access.
set -euxo pipefail

if [ "${VALIDATE_BUILD:-true}" != "true" ]; then
  echo "VALIDATE_BUILD=false: skipping boot test and image preload."
  echo "WARNING: the AMI is unverified and will pull Kong images from the internet on first boot."
  exit 0
fi

: "${KONG_NAMESPACE:?}"
: "${ARCH:?}"

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
IMAGE_DIR=/var/lib/rancher/k3s/agent/images

kc() { k3s kubectl "$@"; }

# k3s applies /var/lib/rancher/k3s/server/manifests asynchronously after the
# API server comes up, so every object below has to be waited into existence
# before it can be waited on. `kubectl wait` and `rollout status` both fail
# immediately on a resource that does not exist yet.
await() {
  local what="$1" tries="${2:-60}" i
  set +x
  for ((i = 1; i <= tries; i++)); do
    if kc get ${what} >/dev/null 2>&1; then
      echo "await: ${what} present after $(( (i - 1) * 5 ))s"
      set -x
      return 0
    fi
    sleep 5
  done
  set -x
  echo "FATAL: ${what} never appeared after $((tries * 5))s"
  return 1
}

systemctl start k3s

# API server.
for i in $(seq 1 60); do
  kc get --raw='/readyz' >/dev/null 2>&1 && break
  if [ "${i}" -eq 60 ]; then
    journalctl -u k3s --no-pager | tail -100
    echo "FATAL: API server never became ready"
    exit 1
  fi
  sleep 5
done

await "node" 60
kc wait --for=condition=Ready node --all --timeout=300s

# ---------------------------------------------------------------------------
# Traefik must be absent, not merely unhealthy.
# ---------------------------------------------------------------------------
if kc -n kube-system get deployment traefik >/dev/null 2>&1; then
  echo "FATAL: Traefik is deployed; the disable list did not take effect"
  exit 1
fi
if kc get ingressclass traefik >/dev/null 2>&1; then
  echo "FATAL: Traefik IngressClass exists"
  exit 1
fi
test ! -f /var/lib/rancher/k3s/server/manifests/traefik.yaml \
  || test -f /var/lib/rancher/k3s/server/manifests/traefik.yaml.skip \
  || { echo "FATAL: bundled Traefik manifest is present and not skipped"; exit 1; }
echo "Traefik: absent, as intended."

# ---------------------------------------------------------------------------
# Kong.
# ---------------------------------------------------------------------------
await "crd/kongplugins.configuration.konghq.com" 60
await "crd/kongconsumers.configuration.konghq.com" 60
kc wait --for=condition=established --timeout=180s \
  crd/kongplugins.configuration.konghq.com \
  crd/kongconsumers.configuration.konghq.com

# The default IngressClass has to be ours.
kc get ingressclass kong \
  -o jsonpath='{.metadata.annotations.ingressclass\.kubernetes\.io/is-default-class}' \
  | grep -qx true || { echo "FATAL: kong is not the default IngressClass"; exit 1; }

await "-n ${KONG_NAMESPACE} deployment/kong-kong" 60
kc -n "${KONG_NAMESPACE}" rollout status deployment/kong-kong --timeout=600s

# ServiceLB must have published the proxy on the node.
await "-n ${KONG_NAMESPACE} svc/kong-kong-proxy" 30
for i in $(seq 1 60); do
  lb_ip="$(kc -n "${KONG_NAMESPACE}" get svc kong-kong-proxy \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [ -n "${lb_ip}" ] && break
  if [ "${i}" -eq 60 ]; then
    kc -n "${KONG_NAMESPACE}" describe svc kong-kong-proxy
    kc -n kube-system get pods -l svccontroller.k3s.cattle.io/svcname=kong-kong-proxy -o wide
    echo "FATAL: proxy Service got no external IP from ServiceLB"
    exit 1
  fi
  sleep 5
done
echo "Kong proxy published at ${lb_ip}"

# ---------------------------------------------------------------------------
# The point of the whole image: something answers on 443 and 80.
# ---------------------------------------------------------------------------
# 404 is Kong's "no Route matched" - the proxy is up with no routes configured.
for i in $(seq 1 30); do
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 https://127.0.0.1:443/ || true)"
  [ "${code}" = "404" ] && break
  if [ "${i}" -eq 30 ]; then
    ss -lntp || true
    kc -n "${KONG_NAMESPACE}" logs deployment/kong-kong --all-containers --tail=100 || true
    echo "FATAL: no Kong response on :443 (last HTTP code: ${code:-none})"
    exit 1
  fi
  sleep 5
done
echo "HTTPS ingress on :443 -> HTTP ${code} from Kong."

code_http="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:80/ || true)"
[ "${code_http}" = "404" ] || { echo "FATAL: no Kong response on :80 (HTTP ${code_http:-none})"; exit 1; }
echo "HTTP ingress on :80 -> HTTP ${code_http} from Kong."

curl -sk --max-time 10 https://127.0.0.1:443/ | head -c 200 || true
echo

# ---------------------------------------------------------------------------
# Preload: export the images containerd just pulled into the k3s airgap
# directory. On first boot k3s imports these instead of hitting a registry, so
# instances come up without egress to docker.io / ghcr.io.
# ---------------------------------------------------------------------------
install -d -m 0755 "${IMAGE_DIR}"

mapfile -t images < <(k3s ctr images ls -q | grep -v '^sha256:' | sort -u)
[ "${#images[@]}" -gt 0 ] || { echo "FATAL: containerd reported no images to export"; exit 1; }
printf 'exporting: %s\n' "${images[@]}"

k3s ctr images export \
  --platform "linux/${ARCH}" \
  "${IMAGE_DIR}/k3s-kong-preload.tar" \
  "${images[@]}"

chmod 0644 "${IMAGE_DIR}/k3s-kong-preload.tar"
du -h "${IMAGE_DIR}/k3s-kong-preload.tar"
