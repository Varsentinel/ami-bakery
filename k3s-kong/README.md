# k3s-kong

Packer template for an AMI that boots straight into a single-node k3s cluster
with **Traefik disabled** and **Kong Gateway** answering ingress on **:443**
(and :80).

Launch an instance, wait for k3s to come up, point DNS at it, apply an
`Ingress`, and traffic flows. No Helm install, no chart download, no registry
pull at run time.

## What is in the image

| | |
|---|---|
| OS | Ubuntu 24.04 LTS (`ubuntu_release`, amd64 or arm64) |
| Kubernetes | k3s `v1.37.2+k3s1` (`k3s_version`), server mode, single node |
| Ingress | Kong Gateway 3.9 via the `kong/kong` chart `3.4.1` (`kong_chart_version`), DB-less, Kong Ingress Controller as a sidecar |
| Traefik | disabled via `disable: [traefik]` in `/etc/rancher/k3s/config.yaml` — never deployed, not even on the first boot |
| Ingress class | `kong`, annotated as the cluster default, so an `Ingress` without `ingressClassName` still works |
| Host ports | 80 and 443, published by k3s ServiceLB (klipper) from the `kong-kong-proxy` Service |
| Firewall | ufw enabled, inbound TCP 22/80/443/6443 (`firewall_tcp_ports`) plus k3s-internal traffic |
| Images | every container image the cluster needs is preloaded at `/var/lib/rancher/k3s/agent/images/k3s-kong-preload.tar` |

## Build

```sh
packer init .
packer validate .
cp k3s-kong.pkrvars.hcl.example k3s-kong.pkrvars.hcl   # then edit
packer build -var-file=k3s-kong.pkrvars.hcl .
```

Or without a vars file:

```sh
packer build -var aws_region=ap-southeast-1 -var architecture=arm64 .
```

Needs AWS credentials with the usual Packer EC2 permissions (run/terminate
instances, create AMIs and snapshots, manage a temporary key pair and security
group). The build takes roughly 10–15 minutes, most of it pulling Kong images.
The AMI id is written to `manifest.json`.

## Using the AMI

The security group is **not** part of the image. Open 443 (and 80, and 22 if
you need SSH) in the security group you attach — ufw inside the image permits
them, but the security group is still the outer gate.

```sh
aws ec2 run-instances \
  --image-id ami-xxxxxxxxxxxx \
  --instance-type t3.medium \
  --security-group-ids sg-xxxxxxxx \
  --key-name my-key
```

Then, on the instance:

```sh
sudo k3s kubectl get nodes
sudo k3s kubectl -n kong get pods,svc
curl -k https://localhost/            # {"message":"no Route matched with those values"}
```

That 404 is Kong: the proxy is live and has no routes yet. Add one:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo
spec:
  # ingressClassName can be omitted: "kong" is the default class.
  rules:
    - host: demo.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: demo
                port:
                  number: 80
```

For real TLS, install a certificate as a `Secret` and reference it under
`spec.tls`, or add cert-manager. The image ships no certificate, so Kong serves
its self-signed default until you provide one — hence `curl -k` above.

First boot takes a minute or two: k3s imports the preloaded image tarball
before starting the Kong pod. Watch it with
`journalctl -u k3s -f`.

## How it is put together

```
k3s-kong.pkr.hcl    source + build blocks
variables.pkr.hcl   all inputs
files/              everything baked into the image verbatim
scripts/            build steps, run in order
```

The build runs seven scripts:

| Script | Does |
|---|---|
| `00-base.sh` | waits out cloud-init, installs prerequisites, kernel modules, sysctls, swap off |
| `10-install-k3s.sh` | installs k3s with `INSTALL_K3S_SKIP_START=true`, installs the first-boot unit |
| `20-install-kong.sh` | `helm template`s the Kong chart into `/var/lib/rancher/k3s/server/manifests/kong.yaml` |
| `30-validate.sh` | boots the cluster, asserts Traefik is gone and Kong answers on :443, exports the pulled images |
| `40-reset-k3s.sh` | wipes the cluster identity created by that boot |
| `50-firewall.sh` | ufw rules |
| `99-cleanup.sh` | removes Helm, cloud-init state, machine-id, host keys, logs |

Three decisions are worth knowing about.

**Kong is rendered to static YAML, not installed.** `20-install-kong.sh` runs
`helm template --include-crds` at build time and writes one ordered file
(Namespace → IngressClass → chart) into k3s's auto-deploy directory. k3s applies
it on first boot. The alternative — shipping a `HelmChart` custom resource —
would make every first boot depend on `charts.konghq.com` being up. Helm itself
is deleted from the image afterwards. The build fails immediately if the chart
stops rendering the CRDs, the proxy Service, or port 443.

**k3s is started once during the build, then reset.** Starting it is what
pulls the container images, and it is the only honest way to assert the image
works. But a k3s server that has run holds a cluster CA, a server token, a node
password, a sqlite datastore and kubelet certificates, all tied to the build
instance. Baked into an AMI, every instance from it would share one identity and
one set of secrets. `40-reset-k3s.sh` deletes all of it and verifies the
deletion, keeping only the two instance-independent pieces: the auto-deploy
manifests and the exported image tarball. `/var/lib/rancher/k3s/data` (the
extracted k3s binaries) also stays — it is version-specific, not
instance-specific.

**Port 443 comes from ServiceLB, not a cloud load balancer.** The Kong proxy
Service is a `LoadBalancer`; k3s's built-in ServiceLB answers it by running
klipper pods that bind the node's :80 and :443. With Traefik disabled nothing
competes for those ports. No ELB/NLB is created or needed. If you *do* want an
NLB in front, keep this as-is and target the instance on 443.

## Tuning

- **Kong values** — `files/kong-values.yaml`. Rendered at build time, so any
  change needs a rebuild.
- **k3s flags** — `files/k3s-config.yaml`. Per-instance values must not go
  here; the file is identical on every instance. `files/k3s-tls-san.sh` runs
  before `k3s.service` on each boot and writes the instance's IPs and hostnames
  as TLS SANs into `/etc/rancher/k3s/config.yaml.d/10-instance.yaml`. Add other
  per-instance settings there.
- **Changing the instance's address** — the TLS SANs are baked into the
  certificate on first boot. After a stop/start gives the instance a new public
  IP, run `sudo k3s certificate rotate && sudo systemctl restart k3s` to reissue
  with the refreshed SANs. An Elastic IP avoids the problem.
- **Remote `kubectl`** — the kubeconfig is `0600` by design. Copy
  `/etc/rancher/k3s/k3s.yaml` off the box and replace `127.0.0.1` with the
  instance address; the first-boot SANs make the certificate valid for it.
  Setting `write-kubeconfig-mode: "0644"` instead makes every local user
  cluster-admin.
- **Closing the API** — drop `"6443"` from `firewall_tcp_ports`.
- **No host firewall** — `enable_ufw = false` leaves filtering to security
  groups entirely.
- **Faster, unverified builds** — `validate_build = false` skips the boot test.
  It also skips the image preload, so instances then pull Kong from the
  internet on first boot. Not recommended.

## Managing Kong after launch

Because Kong lives in k3s's auto-deploy directory, k3s owns it: **deleting
`kong.yaml` makes k3s delete the Kong resources.** To take over with Helm
instead, disable the addon first and leave the file in place:

```sh
sudo touch /var/lib/rancher/k3s/server/manifests/kong.yaml.skip
sudo systemctl restart k3s
helm upgrade --install kong kong/kong -n kong ...
```

To change Kong's configuration without taking over, edit
`files/kong-values.yaml` and rebuild the AMI. That is the intended path: the
image is the unit of change.

## Caveats

- Single node. The template bakes a k3s *server*; it is not a join-an-existing-
  cluster agent image.
- The Kong chart pinned here (`3.4.1`, Kong 3.9, KIC 3.5) predates k3s 1.37's
  Kubernetes release. The build validates that exact pairing end to end, so a
  build that fails in `30-validate.sh` is the signal to pin `k3s_version` back
  a minor or two — e.g. `v1.34.13+k3s1` — rather than to debug the image.
- Kong OSS, DB-less. No Postgres, no Kong Manager, no Enterprise features. The
  Admin API is not exposed; only the sidecar controller reaches it.
