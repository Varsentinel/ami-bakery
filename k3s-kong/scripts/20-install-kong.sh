#!/usr/bin/env bash
# Render the Kong Gateway chart to static manifests and drop them into the k3s
# auto-deploy directory. Rendering at build time (rather than shipping a
# HelmChart CR) means first boot needs no access to charts.konghq.com.
set -euxo pipefail

: "${KONG_CHART_VERSION:?}"
: "${KONG_NAMESPACE:?}"
: "${HELM_VERSION:?}"

MANIFEST_DIR=/var/lib/rancher/k3s/server/manifests
RENDERED=/tmp/kong-rendered.yaml

curl -sfL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o /tmp/get-helm-3
chmod +x /tmp/get-helm-3
DESIRED_VERSION="${HELM_VERSION}" /tmp/get-helm-3
rm -f /tmp/get-helm-3

helm version

helm repo add kong https://charts.konghq.com
helm repo update kong

# --include-crds pulls in the Kong Ingress Controller CRDs, which the chart
# keeps in crds/ and helm template would otherwise skip.
helm template kong kong/kong \
  --version "${KONG_CHART_VERSION}" \
  --namespace "${KONG_NAMESPACE}" \
  --include-crds \
  --values /tmp/bake/kong-values.yaml \
  > "${RENDERED}"

# Fail the build now, not at first boot, if the chart stopped producing what
# this image promises.
grep -q "kind: CustomResourceDefinition" "${RENDERED}" || { echo "FATAL: no CRDs rendered"; exit 1; }
grep -q "name: kong-kong-proxy" "${RENDERED}"          || { echo "FATAL: proxy Service missing"; exit 1; }
grep -q "type: LoadBalancer" "${RENDERED}"             || { echo "FATAL: proxy Service is not a LoadBalancer"; exit 1; }
grep -qE "^[[:space:]]+port: 443$" "${RENDERED}"        || { echo "FATAL: proxy Service does not expose 443"; exit 1; }

install -d -m 0755 "${MANIFEST_DIR}"

# One ordered file: Namespace, then the default IngressClass, then the chart.
# k3s applies each manifest file top to bottom, so the namespace exists before
# anything is placed in it.
{
  cat <<NS
apiVersion: v1
kind: Namespace
metadata:
  name: ${KONG_NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: ami-bakery
---
NS
  cat /tmp/bake/kong-ingressclass.yaml
  echo "---"
  cat "${RENDERED}"
} > "${MANIFEST_DIR}/kong.yaml"

chmod 0600 "${MANIFEST_DIR}/kong.yaml"
rm -f "${RENDERED}"

# Record what went in, for anyone inspecting a running instance later.
install -d -m 0755 /etc/ami-bakery
cat > /etc/ami-bakery/k3s-kong.json <<META
{
  "k3s_version": "${K3S_VERSION}",
  "kong_chart_version": "${KONG_CHART_VERSION}",
  "kong_namespace": "${KONG_NAMESPACE}",
  "traefik": "disabled",
  "ingress_ports": [80, 443],
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
META

wc -l "${MANIFEST_DIR}/kong.yaml"
