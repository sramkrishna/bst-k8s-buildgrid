# bst-k8s-buildgrid

A recipe — manifests plus instructions — for standing up
[BuildGrid](https://gitlab.com/BuildGrid/buildgrid) and its worker fleet on
Kubernetes so a [BuildStream](https://buildstream.build/) client can submit
builds to it. **Not a fork of any upstream project.** This repo just
consumes them.

The point: `bst build gnomeos/live-image.bst` (or any other BuildStream
target) runs on your cluster instead of on your laptop. Optional layers on
top add [Argo Workflows](https://argo-workflows.readthedocs.io/) for
pipeline-shaped builds, [MinIO](https://min.io/) for durable artifacts,
[kube-prometheus-stack](https://github.com/prometheus-operator/kube-prometheus)
for monitoring, and a small [ntfy.sh](https://ntfy.sh/) watcher unit that
pings your phone when a build finishes.

Verified end-to-end on a 4-node kubeadm cluster building GNOME OS
`live-image.bst` ISOs.

## Layout

```
k8s/          BuildGrid + Postgres + workers + registry (numbered apply order)
runner/       bst-runner image + MinIO + Job template for fish-helper builds
argo/         Argo RBAC, PVC, and the generic `bst-build` WorkflowTemplate

gnome/        GNOME OS example Workflows (invoke bst-build with GNOME args)
dakota/       Project Dakota example Workflow (invoke bst-build with Dakota args)
workstation/  Client-side helpers — ntfy watcher script + systemd unit

client/       sample bst 2.x user config to copy to ~/.config/
example/      minimal smoke-test BuildStream project
CHEATSHEET.md         day-to-day operations reference
GNOME-OS-JOURNAL.md   chronological log of what broke and why during buildout
```

`gnome/`, `dakota/`, and `workstation/` are independent — install any
subset. The core (`k8s/`, `argo/`) is what everything else builds on top of.

## Upstream projects consumed (not forked)

| Component                | Upstream                                                        |
|--------------------------|-----------------------------------------------------------------|
| BuildGrid (REAPI server) | https://gitlab.com/BuildGrid/buildgrid                          |
| buildbox-worker / casd   | https://gitlab.com/BuildGrid/buildbox/buildbox                  |
| BuildStream (client)     | https://buildstream.build/                                      |
| Argo Workflows           | https://argo-workflows.readthedocs.io/                          |
| MinIO                    | https://min.io/                                                 |
| kube-prometheus-stack    | https://github.com/prometheus-operator/kube-prometheus          |
| ntfy                     | https://ntfy.sh/                                                |

## Prerequisites

- `kubectl` talks to a working cluster (kubeadm or similar; `local-path`
  StorageClass or swap in your own in the PVC manifests).
- CNI works (pod-to-pod, pod-to-Service traffic).
- Nodes can pull from `registry.gitlab.com` (BuildGrid + buildbox images)
  and `quay.io/minio`.
- 200+ GiB spare disk on one node for BuildGrid's CAS PVC (increase for
  bigger workloads — GNOME OS live-image needs ~500 GiB).
- Client machine has BuildStream 2.7+ installable (pipx on immutable
  distros, distro package elsewhere).

## Secrets management

Secret manifests are not committed. For every `*-secret.yaml`, a
`*-secret.example.yaml` sibling exists with a `REPLACE_ME` placeholder.
Before your first `kubectl apply`, copy each example, fill in a real
generated value, and apply the resulting (gitignored) file:

```bash
# Postgres credentials
cp k8s/10-postgres-secret.example.yaml k8s/10-postgres-secret.yaml
sed -i "s|REPLACE_ME|$(openssl rand -base64 32)|" k8s/10-postgres-secret.yaml

# MinIO root credentials (only needed if you install the MinIO layer)
cp runner/07-minio-secret.example.yaml runner/07-minio-secret.yaml
sed -i "s|REPLACE_ME|$(openssl rand -base64 32)|" runner/07-minio-secret.yaml
```

The `.gitignore` covers the real files; only the `*.example.yaml` variants
get pushed.

## Runbook

### 1. BuildGrid + workers (the core)

```bash
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/10-postgres-secret.yaml    # from the template you filled in above
kubectl apply -f k8s/11-postgres-service.yaml
kubectl apply -f k8s/12-postgres-statefulset.yaml
kubectl -n buildgrid rollout status statefulset/postgres

kubectl apply -f k8s/20-buildgrid-config.yaml
kubectl apply -f k8s/30-buildgrid-migrate.yaml
kubectl -n buildgrid wait --for=condition=complete job/buildgrid-migrate --timeout=180s

kubectl apply -f k8s/40-buildgrid.yaml
kubectl -n buildgrid rollout status deploy/buildgrid

kubectl apply -f k8s/50-workers.yaml
kubectl -n buildgrid rollout status deploy/worker

kubectl apply -f k8s/70-registry.yaml    # in-cluster image registry for bst-runner
```

Verify a worker registered:

```bash
kubectl -n buildgrid exec postgres-0 -- \
    psql -U bgd -d bgd -c \
    "select bot_id, bot_status, instance_name from bots order by last_update_timestamp desc limit 3;"
```

Expect one row per worker replica with `bot_status = 1` and empty
`instance_name`.

### 2. Client side

On the machine you'll run `bst` from:

```bash
brew install pipx    # or your OS's pipx equivalent
pipx install BuildStream
bst --version        # expect 2.7+
```

Copy the user config and point it at your cluster:

```bash
mkdir -p ~/.config
cp client/buildstream2.conf ~/.config/buildstream2.conf
# Edit ~/.config/buildstream2.conf and set the URL to any cluster node IP
# on port 30515 (the NodePort exposed by 40-buildgrid.yaml).
```

### 3. Smoke test

```bash
cd example
bst source track base.bst
bst build hello.bst
bst artifact checkout hello.bst --directory ./output
cat output/hello.txt         # → hello
```

If this works, the core is proven. Anything below is optional depending on
how much of the wider stack you want.

### 4. (Optional) Argo Workflows — pipeline-shaped builds

Install Argo Workflows from its official manifest, then apply the extras:

```bash
kubectl create namespace argo
kubectl apply -n argo -f \
    https://github.com/argoproj/argo-workflows/releases/download/v4.0.5/install.yaml

kubectl apply -f argo/00-rbac.yaml
kubectl apply -f argo/05-cache-pvc.yaml
kubectl apply -f argo/10-bst-build.yaml
```

Fire a build (using a GNOME example):

```bash
kubectl -n buildgrid create -f gnome/smoke-workflow.yaml       # small target
kubectl -n buildgrid create -f gnome/live-image-workflow.yaml  # full ISO
```

For Dakota builds see `dakota/`. For any other BuildStream project, copy
one of the example Workflow manifests and change `repo`, `ref`, `target`.

### 5. (Optional) MinIO for artifact storage

The Argo template's final step uploads artifacts to MinIO. Skip if you
don't need durable artifact storage.

```bash
kubectl apply -f runner/00-cache-pvc.yaml
kubectl apply -f runner/05-output-pvc.yaml
kubectl apply -f runner/07-minio-secret.yaml   # from your filled-in template
kubectl apply -f runner/07-minio.yaml
kubectl apply -f runner/10-config.yaml
```

Artifacts land at `http://<any-node>:30900/artifacts/runs/<workflow-name>/`.

### 6. (Optional) Monitoring

Cluster CPU/mem/temp + Prometheus/Grafana:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install monitoring prometheus-community/kube-prometheus-stack \
    -n monitoring --create-namespace
```

Import Grafana dashboards 1860 (Node Exporter Full) and 15760 (K8s cluster).

### 7. (Optional) Workstation ntfy watcher

A small systemd `--user` unit that watches your Argo workflows and pushes
[ntfy.sh](https://ntfy.sh/) notifications on completion. Runs on your
laptop, not the cluster (nodes aren't on your Tailscale, so pods can't
reach a personal ntfy IP). See `workstation/README.md` for install +
configuration.

## Why these specific choices

Decisions that weren't obvious from reading either BuildGrid or BuildStream
docs alone:

- **Single BuildGrid pod hosting `!cas`, `!bytestream`, `!action-cache`,
  `!execution`, `!bots` on port 50051.** Matches BuildGrid's `default.yml`
  and BuildStream's own CI compose file. Splitting services across pods
  works but adds coordination overhead and diverges from tested paths.

- **`nightly` BuildGrid image, not a tagged release.** BuildStream CI runs
  against nightly. Older tagged images have config-schema drift and known
  API mismatches with recent BuildStream versions.

- **Empty instance name `''`.** Every working reference uses `''`. Named
  instances (e.g. `buildgrid`) cause silent mismatches with buildbox-casd
  defaults and surface as `Invalid instance name` or empty-blob errors.

- **`disk-storage` PVC-backed CAS + `sql-scheduler`.** Persistent CAS lets
  the cluster keep its warm cache across BuildGrid restarts, which
  dramatically speeds up repeat builds. The schema migration Job populates
  the CAS index tables.

- **Worker `--runner-arg=--staging-mode=copy-or-link`.** The killer.
  buildbox-run's default staging is FUSE, and FUSE inside a k8s pod dies
  with exit 2 (kernel plumbing missing even with `privileged: true`).
  Copy-or-link stages via hardlinks and works fine.

- **casd sidecar on the worker pod, worker connects via UNIX socket.**
  The worker uses `LocalCAS.StageTree` RPC which only buildbox-casd
  implements. BuildGrid's `!cas` is plain REAPI, no StageTree. So a
  local casd (proxying to BuildGrid CAS) is required.

- **Client-side `cache.storage-service` AND `remote-execution.*` blocks.**
  Two separate config paths in BuildStream 2.x. `cache.storage-service` is
  what makes bst spawn its client-side casd with `--cas-remote`; without
  it, bst's Python-only upload path drops multi-blob directory trees
  silently and BuildGrid rejects the action with `Missing entries under
  root directory`.

- **NodePort 30515 instead of LoadBalancer.** Cluster has MetalLB but its
  L2 advertisement isn't announcing (unrelated FRR-mode issue). NodePort
  works from any node IP.

- **`property-set: !dynamic-property-set` with `wildcard-property-keys:
  [remoteApisSocketPath]`.** gnome-build-meta sends this platform property
  for its recc integration; without the wildcard, BuildGrid rejects the
  action with `Unregistered platform property [remoteApisSocketPath]`.

## Troubleshooting

**bst hangs at `Waiting for the remote build to complete`.**
Check `kubectl -n buildgrid logs deploy/worker -c worker --tail=30` for
runner errors. Most common: FUSE-related failure means the worker isn't
picking up `--staging-mode=copy-or-link`.

**Action error `Missing entries under root directory: <hash>/...`.**
The client didn't upload all input blobs. Cause is almost always missing
`cache.storage-service` in `~/.config/buildstream2.conf`.

**Worker not registered (no rows in `bots` table).**
Check the worker pod's `worker` container logs for connectivity errors to
the BuildGrid Service.

**OOMKilled (exit 137) during Argo workflow.**
Bump `resources.limits.memory` in `argo/10-gnome-build.yaml`. Batch
workloads on multi-hundred-GiB nodes should get generous limits; unused
headroom doesn't cost anything.

More at `CHEATSHEET.md` section 8.

## Teardown

```bash
kubectl delete namespace buildgrid
```

Wipes everything including the Postgres PVC and the CAS. Argo and
monitoring namespaces (if you installed them) come off separately.

## Contributing

This is a personal / homelab-shaped repo, but PRs improving portability
(different StorageClasses, non-kubeadm distributions, minor version bumps)
are welcome. For substantial changes to the architecture, open an issue
first — the decisions in "Why these specific choices" are load-bearing.
