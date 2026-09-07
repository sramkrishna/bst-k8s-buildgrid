# BuildGrid-on-k8s cheatsheet

Quick reference for operating and inspecting the cluster. File paths are
relative to this repo (`~/src/bst-k8s-buildgrid/`). For "how did we build this"
narrative, see `GNOME-OS-JOURNAL.md`.

---

## 0. Cluster basics

Nodes: `fast-sfp1..4` at `192.168.88.11..14`, 256 GiB / 12+ cores each.
Only `sfp1` is on Tailscale (via brigid). Nodes live in a house — watch temps.

Namespaces we care about:

| Namespace    | What lives there                                                    |
|--------------|---------------------------------------------------------------------|
| `buildgrid`  | BuildGrid + workers + MinIO + Argo template + bst-runner Jobs       |
| `argo`       | Argo workflow-controller + argo-server                              |
| `monitoring` | Prometheus + Grafana + Alertmanager + node-exporter (helm-managed)  |
| `kube-system`| Cilium CNI, coredns, kube-proxy, etc                                |

`kubectl` command shape — nearly every command is:

```
kubectl [-n NS] <verb> <resource> [name] [flags]
```

Handy shortnames: `po` pods, `svc` services, `deploy` deployments,
`ds` daemonsets, `sts` statefulsets, `pvc` persistent volume claims,
`cm` configmaps, `sec` secrets, `wf` (Argo) workflow, `wt` workflow template.

Find them all: `kubectl api-resources`.

---

## 1. BuildGrid (the REAPI server)

Manifests:

- `k8s/20-buildgrid-config.yaml` — controller.yml (scheduler, `!disk-storage`, thread pool)
- `k8s/40-buildgrid.yaml` — Deployment + Service (ClusterIP + NodePort 30515)
- `k8s/30-buildgrid-migrate.yaml` — one-shot schema migration Job
- `k8s/50-workers.yaml` — worker Deployment (48 replicas, casd sidecar)
- `k8s/60-cache-proxy.yaml` — Remote Asset cache proxy (currently unused)

Endpoints:

- In-cluster: `buildgrid.buildgrid.svc.cluster.local:50051`
- LAN: `192.168.88.11:30515`

Common ops:

```fish
# Status + logs
kubectl -n buildgrid get deploy buildgrid
kubectl -n buildgrid logs deploy/buildgrid --tail 100
kubectl -n buildgrid logs deploy/buildgrid --tail 100 | grep -iE 'error|warn'

# Restart (config-only, no image change)
kubectl -n buildgrid rollout restart deploy/buildgrid

# Apply config changes
kubectl apply -f k8s/20-buildgrid-config.yaml
kubectl -n buildgrid rollout restart deploy/buildgrid
```

---

## 2. Workers

Manifest: `k8s/50-workers.yaml`. Each pod has two containers — the worker itself
and a local `buildbox-casd` sidecar. Requires `privileged: true` for bwrap.

```fish
# Count and placement
kubectl -n buildgrid get deploy worker
kubectl -n buildgrid get pods -l app=worker -o wide \
    | awk 'NR>1 {print $7}' | sort | uniq -c   # per-node distribution

# Logs — pick either container
kubectl -n buildgrid logs pod/<worker-pod> -c worker --tail 50
kubectl -n buildgrid logs pod/<worker-pod> -c casd   --tail 50

# Temporary scale (won't persist across `apply`)
kubectl -n buildgrid scale deploy/worker --replicas=24

# Permanent scale — edit replicas in k8s/50-workers.yaml, then:
kubectl apply -f k8s/50-workers.yaml
```

Thermal note: 48 workers on 4 nodes = 12/node. Under sustained load, the
house heats up — memory `cluster-thermals`. Scale down before long jobs
if it's already warm.

---

## 3. bst client — fish helper (interactive)

- Function: `~/.config/fish/functions/bst-build.fish`
- Runner image build: `runner/Dockerfile`
- Runner Job template: `runner/job-template.yaml` (envsubst'd per invocation)
- bst user config: `~/.config/buildstream2.conf`

```fish
bst-build gnomeos/live-image.bst              # ref/repo default to master + gnome-build-meta
bst-build gnomeos/live-image.bst master https://gitlab.gnome.org/GNOME/gnome-build-meta.git
```

Fires a k8s Job named `bst-build-<slug>-<epoch>`, polls to completion,
pushes ntfy from brigid.

```fish
# All bst-runner Jobs
kubectl -n buildgrid get jobs -l app=bst-runner
kubectl -n buildgrid logs -l app=bst-runner --tail 50   # aggregate
```

---

## 4. Argo Workflows (cluster-driven builds)

Manifests:

- `argo/00-rbac.yaml` — ServiceAccount `workflow` + Role + RoleBinding
- `argo/05-cache-pvc.yaml` — `bst-workflow-cache` PVC (100 GiB, RWO)
- `argo/10-gnome-build.yaml` — the `gnome-build` `WorkflowTemplate`
- `argo/example-smoke-workflow.yaml` — quick sanity (freedesktop-sdk git.bst)
- `argo/example-live-image-workflow.yaml` — real gnomeos/live-image.bst

Fire a build:

```fish
kubectl -n buildgrid create -f argo/example-smoke-workflow.yaml       # ~1-5 min
kubectl -n buildgrid create -f argo/example-live-image-workflow.yaml  # ~10-15 min warm
```

Inspect:

```fish
argo -n buildgrid list
argo -n buildgrid get <wf>                    # DAG + per-step status
argo -n buildgrid logs <wf> -f                # follow all pods in workflow
argo -n buildgrid delete <wf>                 # cleanup

# From kubectl (no argo CLI):
kubectl -n buildgrid get wf
kubectl -n buildgrid get wf <wf> -o yaml
kubectl -n buildgrid logs -l workflows.argoproj.io/workflow=<wf> --tail=-1
```

Argo UI (browser):

```fish
kubectl -n argo port-forward svc/argo-server 2746:2746 &
# → https://localhost:2746   (self-signed, click through)
```

Reload the WorkflowTemplate after editing:

```fish
kubectl apply -f argo/10-gnome-build.yaml
```

Concurrency: currently **one workflow at a time** — `bst-workflow-cache` is RWO.
Multiple concurrent workflows will pend on volume attachment. RWX unlock is a
follow-up (Longhorn/NFS).

---

## 5. MinIO (artifact storage)

Manifest: `runner/07-minio.yaml`. Bucket `artifacts` has anonymous-read policy.

- Console: http://192.168.88.11:30901
- API/HTTP: http://192.168.88.11:30900
- Bucket path: `artifacts/runs/<workflow-name>/`

```fish
# Root credentials
kubectl -n buildgrid get secret minio-root -o json \
    | jq -r '.data | map_values(@base64d) | to_entries[] | "\(.key)=\(.value)"'

# List artifacts by workflow (public read)
curl -s http://192.168.88.11:30900/artifacts/ \
    | grep -oE 'runs/[^"<]+' | sort -u

# List everything under one run
curl -s "http://192.168.88.11:30900/artifacts/?prefix=runs/<wf-name>/" \
    | grep -oE '<Key>[^<]+' | sed 's/<Key>//'
```

---

## 6. Monitoring (kube-prometheus-stack)

Installed via helm as release `monitoring` in namespace `monitoring`.

- Grafana: `kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80 &` → http://localhost:3000 (admin)
- Password: `kubectl -n monitoring get secret monitoring-grafana -o jsonpath="{.data.admin-password}" | base64 -d; echo`
- Prometheus: `kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 &` → http://localhost:9090
- Alertmanager: `kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093 &` → http://localhost:9093

Dashboards to import in Grafana (from grafana.com): **1860** (Node Exporter Full),
**15760** (Kubernetes cluster).

Upgrade the chart later:

```fish
helm repo update
helm -n monitoring upgrade monitoring prometheus-community/kube-prometheus-stack
```

Legacy hand-rolled monitoring (`monitoring/*.yaml`) is superseded by the helm
release. Kept in-repo as historical reference; safe to delete once you're
comfortable.

---

## 7. ntfy watcher (brigid-side notification)

- Systemd unit: `~/.config/systemd/user/bst-wf-watcher.service`
- Script: `~/.local/bin/bst-wf-watcher`
- State file: `~/.local/state/bst-wf-watcher/notified`
- ntfy target: `http://100.106.218.95:2586/gnome_os_notify`

```fish
systemctl --user status  bst-wf-watcher.service --no-pager | head -10
systemctl --user restart bst-wf-watcher.service
journalctl --user -u bst-wf-watcher -f
journalctl --user -u bst-wf-watcher --since "1 hour ago" --no-pager

# Test ntfy directly (bypass the watcher)
curl -d "test from brigid" http://100.106.218.95:2586/gnome_os_notify
```

Persistence:

```fish
loginctl enable-linger sri   # already done — keeps unit running when logged out
```

---

## 8. Common troubleshooting

**Pod won't schedule / Pending**

```fish
kubectl -n NS describe pod POD | tail -30
# → look at Events: block. Common: FailedScheduling with a specific reason.
#   - "didn't have free ports" → hostPort conflict, see `ss -tlnp` on the node
#   - "0/N nodes ... untolerated taint" → add tolerations or untaint
#   - "Insufficient memory" → node full; scale down or add capacity
```

**Pod crashing / restarting**

```fish
kubectl -n NS logs POD --previous            # logs from prior container run
kubectl -n NS describe pod POD | grep -A5 State
kubectl -n NS get events --sort-by=.lastTimestamp | tail -20
```

**OOMKilled (exit 137)**

Bump `resources.limits.memory` in the manifest. `xz -T0 -9` alone reserves
~674 MiB × cores. Batch pods on 256 GiB nodes should have generous limits
(32–64 GiB is fine; nothing is actually reserved unless used).

**DNS not resolving inside the cluster**

```fish
kubectl -n kube-system get pods -l k8s-app=kube-dns
kubectl run tmp --rm -it --image=busybox:1.36 -- nslookup kubernetes.default
```

**Node NotReady**

```fish
kubectl describe node <NODE> | grep -A10 Conditions
# Also check on the node: journalctl -u kubelet --no-pager | tail -50
```

**CNI missing after reboot (sfp1 quirk)**

Symlink `/usr/libexec/cni` → `/opt/cni/bin`. Memory `sfp1-cni-symlink`.

---

## 8b. Port-forwarding pattern

`kubectl port-forward` tunnels a local port on brigid through the k8s API
server to an in-cluster service. Not SSH (looks similar in effect).

```
kubectl -n <namespace> port-forward <svc|pod|deploy>/<name> <local-port>:<remote-port>
```

Default binds to `127.0.0.1` (brigid-local only). Add `--address 0.0.0.0` to
expose on the LAN for phones/laptops.

Trailing `&` backgrounds it; kill later with `jobs; kill %N`.

Common tunnels used in this stack:

```fish
kubectl -n monitoring  port-forward svc/monitoring-grafana                       3000:80   &
kubectl -n monitoring  port-forward svc/monitoring-kube-prometheus-prometheus    9090:9090 &
kubectl -n monitoring  port-forward svc/monitoring-kube-prometheus-alertmanager  9093:9093 &
kubectl -n argo        port-forward svc/argo-server                              2746:2746 &
```

---

## 9. Parallelism reference

| Layer                        | How to check                                          |
|------------------------------|-------------------------------------------------------|
| Node capacity                | `kubectl top nodes`                                   |
| Worker count                 | `kubectl -n buildgrid get pods -l app=worker \| wc -l` |
| Per-worker concurrency       | 1 action per worker (buildbox-worker default)         |
| bst client `--jobs`          | Defaults to runner-pod CPU count                      |
| Argo concurrent workflows    | 1 (RWO cache PVC bottleneck; RWX would unlock)        |
| BuildGrid RPC pool           | `thread-pool-size: 1000` in `k8s/20-buildgrid-config.yaml` |

---

## 10. Rebuild from scratch (rough order)

For when you tear it all down and want to put it back:

1. `kubectl apply -f k8s/00-namespace.yaml`
2. Postgres: `10-postgres-secret.yaml`, `11-postgres-service.yaml`, `12-postgres-statefulset.yaml`
3. Wait for postgres Ready, then run `30-buildgrid-migrate.yaml` (schema)
4. BuildGrid: `20-buildgrid-config.yaml`, `40-buildgrid.yaml`
5. Workers: `50-workers.yaml` (needs `privileged: true` in cluster PSP/PSA)
6. MinIO: `runner/07-minio.yaml`
7. bst-runner image: `podman build -t fast-sfp1:30500/bst-runner:v6 runner/` + push
8. Argo: install from official manifest, then apply `argo/00-rbac.yaml`, `argo/05-cache-pvc.yaml`, `argo/10-gnome-build.yaml`
9. Monitoring: `helm install monitoring prometheus-community/kube-prometheus-stack -n monitoring --create-namespace`
10. Watcher: copy `~/.local/bin/bst-wf-watcher` + `~/.config/systemd/user/bst-wf-watcher.service`, then `systemctl --user enable --now bst-wf-watcher`

Each step + gotcha is chronicled in `GNOME-OS-JOURNAL.md`. When you rebuild
by hand, follow this cheatsheet, and every time you hit a snag write it into
the journal before fixing so future-you has a record.
