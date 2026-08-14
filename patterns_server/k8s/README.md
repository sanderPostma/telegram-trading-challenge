# Telegram patterns server — node02 (microk8s) deploy

Standalone k8s deploy that replaces the Pi's Docker-Compose setup. Serves
`../../config/telegram_patterns.yaml` at:

    https://telegram-patterns.sander.dnsrouter.nl/telegram_patterns.yaml

## How it works

- Stock `nginx:1.27` (no custom image to build/import) serves one file.
- `nginx.conf` and `telegram_patterns.yaml` are loaded into **ConfigMaps from
  the repo files** at deploy time, so `config/telegram_patterns.yaml` stays the
  single source of truth.
- TLS via **cert-manager** (`letsencrypt-prod` ClusterIssuer, HTTP-01) and
  **Traefik `IngressRoute`** — mirrors `infra/k8s/trading-stack/extras/botctl-certificate.yaml`.
  Uses the same shared Traefik instance (its `kubernetescrd` provider watches
  all namespaces), on the `websecure` (443) entrypoint. Runs in its own
  `telegram-patterns` namespace, isolated from `trading-stack`.

## Prerequisites

1. **DNS**: `telegram-patterns.sander.dnsrouter.nl` must have an A record
   pointing at node02, or the Let's Encrypt HTTP-01 challenge cannot complete.
2. node02 access via the MCP server-catalog tools (see `bot-prod-deploy.md`).
   All node02 commands go through `microk8s kubectl` as the `ubuntu` user
   (no sudo needed for microk8s).

## Deploy

All commands are run on node02 via `remote_session_exec` (or `remote_exec`).
Files are uploaded with `remote_file_transfer`. Run from the repo root
(`apps/tmg-challenge`) locally.

```sh
# 1. Upload the manifest + the two source files to node02 staging.
remote_file_transfer(server="node02", direction="upload",
  local_path="patterns_server/k8s/telegram-patterns.yaml",
  remote_path="/home/ubuntu/telegram-patterns.yaml")
remote_file_transfer(server="node02", direction="upload",
  local_path="patterns_server/nginx.conf",
  remote_path="/home/ubuntu/telegram-patterns-nginx.conf")
remote_file_transfer(server="node02", direction="upload",
  local_path="config/telegram_patterns.yaml",
  remote_path="/home/ubuntu/telegram_patterns.yaml")

# 2. Namespace + deployment/service/ingressroute/certificate.
remote_session_exec: microk8s kubectl apply -f /home/ubuntu/telegram-patterns.yaml

# 3. ConfigMaps generated straight from the source files (single source of
#    truth — no YAML duplicated into a manifest). Re-runnable (apply pattern).
remote_session_exec: microk8s kubectl create configmap telegram-patterns-nginx \
  --from-file=default.conf=/home/ubuntu/telegram-patterns-nginx.conf \
  -n telegram-patterns --dry-run=client -o yaml | microk8s kubectl apply -f -
remote_session_exec: microk8s kubectl create configmap telegram-patterns-yaml \
  --from-file=telegram_patterns.yaml=/home/ubuntu/telegram_patterns.yaml \
  -n telegram-patterns --dry-run=client -o yaml | microk8s kubectl apply -f -

# 4. Roll the deployment so it picks up the ConfigMaps (first apply may have
#    started before the ConfigMaps existed).
remote_session_exec: microk8s kubectl rollout restart deploy/telegram-patterns -n telegram-patterns
remote_session_exec: microk8s kubectl rollout status  deploy/telegram-patterns -n telegram-patterns --timeout=120s

# 5. Clean staging copies.
remote_session_exec: rm -f /home/ubuntu/telegram-patterns.yaml /home/ubuntu/telegram-patterns-nginx.conf /home/ubuntu/telegram_patterns.yaml
```

## Verify

```sh
# Pod running, cert issued (READY=True), route live.
remote_session_exec: microk8s kubectl get pods -n telegram-patterns
remote_session_exec: microk8s kubectl get certificate -n telegram-patterns
remote_session_exec: microk8s kubectl describe certificate telegram-patterns-cert -n telegram-patterns | tail -20

# End-to-end from the workstation (after DNS + cert are live):
curl -sSf https://telegram-patterns.sander.dnsrouter.nl/telegram_patterns.yaml | head
```

Certificate issuance can take 1-2 min on first deploy (ACME HTTP-01). If it
stays `READY=False`, check the DNS A record and that node02 port 80 is open
(it is, per the node02 setup summary), then:

    microk8s kubectl describe order,challenge -n telegram-patterns

## Updating patterns later

Edit `config/telegram_patterns.yaml`, then re-run steps 1 (the yaml only), 3
(the `telegram-patterns-yaml` ConfigMap), and 4 (rollout restart). No image
rebuild — the file is a ConfigMap.
```
