# GNOME OS build journal

Chronological log of what broke, why, and what changed while getting
`bst build gnomeos/live-image.bst` (from `gnome-build-meta` `main` = GNOME 51)
to complete against this cluster.

Each entry documents:
- **Initial assumption** — what we thought would work
- **Observed error**
- **Root cause** — what actually happened
- **Fix** — the change applied, with the file it touched

---

## 0. Baseline going in (post-hello-smoke-test)

Coming out of the hello-world smoke test, the cluster had:

- BuildGrid nightly, `!lru-storage 2048M` (in-memory only)
- 1 worker, 5 Gi emptyDir cache, `--request-timeout=30`,
  `--cas-remote=http://buildgrid:50051`
- Instance name `""`, `--staging-mode=copy-or-link` on workers
- Client `~/.config/buildstream2.conf` with both `cache.storage-service`
  and `remote-execution.*`

Prep changes made before the first GNOME OS attempt:

1. **CAS store upgrade** — `!lru-storage` → `!disk-storage` on a 500 Gi PVC
   (in-memory would evict constantly under GNOME-scale traffic).
   `k8s/20-buildgrid-config.yaml`, `k8s/40-buildgrid.yaml`
2. **Worker scale** — 1 → 25 replicas.
   `k8s/50-workers.yaml`
3. **Client-side gnome-build-meta deps**:
   - `pipx inject BuildStream dulwich buildstream-plugins buildstream-plugins-community requests tomlkit`
   - `brew install lzip` (host tool required by `tar` source plugin)
   - `make -C files/boot-keys IMPORT_MODE=snakeoil` (dummy secure-boot keys)

---

## 1. `Unregistered platform property [remoteApisSocketPath]`

**Assumption:** BuildGrid's default known platform properties (`ISA`,
`OSFamily`) covered what a real client sends.

**Error:**
```
FAILED_PRECONDITION: Unregistered platform property
  [remoteApisSocketPath={'tmp/casd.sock'}].
  Known properties are: [{'ISA', 'OSFamily'}]
```

**Root cause:** gnome-build-meta's `project.conf` has a
`sandbox.remote-apis-socket` config for the recc integration. This
causes bst to add `remoteApisSocketPath` as a platform property on every
action. BuildGrid's scheduler rejects unrecognised properties by default.

**Fix:** Add a `property-set` to the scheduler that wildcards this key,
so BuildGrid accepts it (workers don't advertise it — see § 3 for the
followup that made recc actually work).

`k8s/20-buildgrid-config.yaml`:
```yaml
schedulers:
  - !sql-scheduler &state-database
    …
    property-set: !dynamic-property-set
      wildcard-property-keys:
        - remoteApisSocketPath
```

---

## 2. Worker pod evicted — EmptyDir cache exceeded 5 Gi

**Assumption:** 5 Gi ephemeral scratch per worker was enough (it was for
the hello-world test).

**Error (in kubelet events for a `worker-*` pod):**
```
Warning  Evicted  ... Usage of EmptyDir volume "cache" exceeds the limit "5Gi".
```
Client side: `Job was retried 5 unsuccessfully. Aborting.`

**Root cause:** A single GNOME OS build action's input tree (base runtime
+ all deps + sources) is much larger than 5 Gi. buildbox-casd on the
worker caches all these blobs; kubelet evicts the pod when the emptyDir
hits its size limit.

**Fix:** Bump the worker's cache `sizeLimit` to 50 Gi.

`k8s/50-workers.yaml`:
```yaml
volumes:
  - name: cache
    emptyDir:
      sizeLimit: 50Gi
```

---

## 3. `Neither the execution nor the action cache service is enabled for instance ""`

**Assumption:** The worker's local casd only needed `--cas-remote` — that
covers the CAS proxy path buildbox-worker uses when fetching input
blobs and pushing outputs.

**Error:**
```
Error staging "f57a0b334…/706" into "":
  "9: Neither the execution nor the action cache service is enabled
   for instance """"
```
(gRPC code 9 = FAILED_PRECONDITION.)

**Root cause:** gnome-build-meta actions run `recc` inside the sandbox.
recc talks to a mounted `/tmp/casd.sock` — that socket **is** the
worker's local casd. When recc submits a nested Execute or does an
ActionCache lookup through that socket, the local casd needs upstream
config for AC and Execution too, not just CAS.

**Fix:** Add `--ac-remote` and `--exec-remote` to the worker's local
casd sidecar (all pointing at BuildGrid).

`k8s/50-workers.yaml`, `local-casd` container args:
```yaml
- --cas-remote=http://buildgrid:50051
- --ac-remote=http://buildgrid:50051
- --exec-remote=http://buildgrid:50051
```

---

## 4. `Deadline Exceeded` during "Integrating sandbox"

**Assumption:** `--request-timeout=30` on buildbox-worker (copied from
BuildStream's own CI compose) would be fine.

**Error (on `gnomeos/usr/filesystem.bst`):**
```
Waiting for the remote build to complete    SUCCESS (in 4:47)
Running commands                             FAILURE
Integrating sandbox                          FAILURE
[909bf22c] gnomeos/usr/filesystem.bst        FAILURE  Deadline Exceeded
```

**Root cause:** The main action finished in ~5 min, but the follow-up
integration action (runs `ldconfig`, `glib-compile-schemas`,
`update-mime-database`, etc. on the huge filesystem tree) took longer
than 30 s of RPC deadline. `--request-timeout=30` bounds all gRPC
requests from buildbox-worker, including the polling for a long-running
integrate action.

**Fix:** Remove `--request-timeout` entirely. Default is 0 = unlimited,
which is what the workload needs.

`k8s/50-workers.yaml`:
```yaml
# (line removed)
- --request-timeout=30
```

---

## ✅ Build completed after iteration 4

Same `bst build gnomeos/live-image.bst` command, run once more after the
`--request-timeout` removal:

```
Pipeline Summary
    Total:       1119
    Session:     801
    Pull Queue:  processed 0, skipped 801, failed 0
    Fetch Queue: processed 0, skipped 801, failed 0
    Build Queue: processed 5, skipped 796, failed 0

Elapsed (wall clock) time: 18:44
Exit status: 0
```

**Caveat on the timing.** This wasn't a clean cold build. Iterations 1-4
each pulled 100-700 artifacts and executed 1-8 actions before failing.
By the time this final run started, brigid's local cache was already
warm, so only the 5 previously-failing leaf actions had to execute.
The `18:44` reflects the finish-line push of a resumed build, not a
from-scratch cold time.

## ⏱  Clean cold-vs-warm measurement

Full-wipe protocol:

```bash
# Wipe brigid + cluster CAS + scheduler
rm -rf ~/.cache/buildstream
kubectl -n buildgrid scale deploy buildgrid --replicas=0
kubectl -n buildgrid delete pvc bgd-cas-store
kubectl apply -f k8s/40-buildgrid.yaml
kubectl -n buildgrid scale deploy buildgrid --replicas=1
kubectl -n buildgrid exec postgres-0 -- \
  psql -U bgd -d bgd -c "delete from operations; delete from jobs; delete from bots;"
kubectl -n buildgrid rollout restart deploy/worker

# Cold — nothing in bst or cluster cache
/usr/bin/time -v bst build gnomeos/live-image.bst

# Warm — same command immediately after
/usr/bin/time -v bst build gnomeos/live-image.bst
```

**Measured on this cluster / brigid:**

| Run  | Wall clock  | Notes |
|------|-------------|-------|
| Cold | **1:07:48** | 801 elements pulled from `gbm.gnome.org:11003`; 5 leaf actions executed on workers. brigid's uplink and CPU were the bottleneck. |
| Warm | **0:19.45** | bst walks the plan, sees everything cached locally, exits. |

Speedup ≈ **210×**.

**Later measurements as we iterated:**

| Setup                                | Wall time | Notes |
|--------------------------------------|-----------|-------|
| Cold via unwarmed proxy              | **11:00** | § 5 below — proxy warming; cluster has faster path to gnome.org than brigid |
| Direct-to-gnome, partial state       | **32:00** | after reverting proxy config; caches partially populated from previous attempts |

**Where the cold hour actually goes:** almost entirely I/O to gbm.gnome.org
plus brigid's Python-side blob handling. Workers on the cluster are mostly
idle — only the last dozen elements actually execute remotely. If you want
to see the *cluster* work hard, set `BST_ARTIFACT_CACHES_OVERRIDE=none`
and re-do the cold run; every action then runs on your workers instead of
being pulled prebuilt (multi-hour, full stress test).

## 5. Cache proxy attempt (partial success — parked)

**Assumption:** deploying a `buildbox-casd` in caching-proxy mode
(`--cas-remote=https://gbm.gnome.org:11003`, `--ac-remote=…`,
`--ra-remote=…`) in the cluster would let bst pull `artifacts:` and
`source-caches:` from a warm LAN cache instead of gnome.org, dramatically
cutting cold-2 time.

**First observation (encouraging):** the "prime the proxy" cold run took
**11 min**, down from the 1:07:48 baseline — a **~6×** speedup even
while the proxy was still filling. Two contributors: the cluster's
outbound path to gnome.org is fatter/cleaner than brigid's, and some
blobs had already been streamed through during earlier `bst show` calls.

`k8s/60-cache-proxy.yaml` — deployed and running.

**Then it broke on cold-2.** Proxy logs full of:
```
fetchBlob failed with: 3: FetchBlob: Missing URI
fetchBlob failed with: 5: Asset not found in local cache.
```

**Root cause (partly understood):** the Remote Asset protocol returns
either the asset blob directly or a URI to fetch from. Some responses
from gbm.gnome.org's upstream come back without URIs (probably CAS-native
references), and buildbox-casd's Remote Asset proxy path doesn't handle
that flow cleanly — it needs to resolve via the CAS side but doesn't.

**Fix (temporary):** disable the projects override in
`~/.config/buildstream2.conf`; bst goes direct to gbm.gnome.org again.
Cache-proxy Deployment stays running for future investigation.

**What to try later:**
- Different casd flags (e.g. `--local-server-instance` behavior with proxy)
- A newer buildbox-casd version if one lands
- Splitting artifacts (proxied) from source-caches (direct) if only one
  path is broken
- fdo's own local-cache setup — they have a working proxy pattern in
  their `infrastructure/local-cache` compose; likely a different
  proxy shape (e.g. traefik + casd combo).

## 6. Compute utilisation — 3 of 4 nodes were idle

**Assumption:** all 4 physical machines were sharing the build load.

**Observation:** every worker pod was on fast-sfp3. The other three had
0 % CPU during builds.

**Root cause:** fast-sfp1/2/4 are k8s control-plane nodes with the
standard `node-role.kubernetes.io/control-plane:NoSchedule` taint. sfp3
is the only plain worker node. All 25 worker pods packed onto sfp3.

**Fix:**
1. Uncordon and untaint sfp1, sfp2, sfp4 so pods can schedule
   everywhere.
   ```
   kubectl uncordon fast-sfp1
   kubectl taint nodes fast-sfp1 node-role.kubernetes.io/control-plane-
   kubectl taint nodes fast-sfp2 node-role.kubernetes.io/control-plane-
   kubectl taint nodes fast-sfp4 node-role.kubernetes.io/control-plane-
   ```
2. Add `podAntiAffinity` (preferred) on the worker Deployment so k8s
   spreads pods across nodes instead of packing.
   `k8s/50-workers.yaml`.
3. `sfp1` also needed a `/usr/libexec/cni → /opt/cni/bin` symlink —
   its containerd 2.2.0 uses the older CNI plugin path, distinct from
   sfp2/sfp4 (containerd 2.2.3). See [[sfp1-cni-symlink]] memory.

**Trade-off accepted:** control-plane services (etcd, apiserver) now
share hosts with build workloads. Fine for a home lab; not what you'd
do in prod. Future path: run k3s control-plane in a small VM on sfp1
(user has IPMI console for safety), keep all 4 physical boxes as pure
workers.

**Post-fix distribution:** 9 / 7 / 5 / 4 pods across sfp1/2/3/4.

## 7. `Concurrent RPC limit exceeded!` under battle-station load

**Assumption:** BuildGrid's default RPC concurrency was fine.

**Observation:** on a from-scratch build (`BST_ARTIFACT_CACHES_OVERRIDE=none`)
with **48 workers × 4 nodes**, staging blobs during
`gnomeos/usr/filesystem.bst` (a large aggregate element) failed:

```
Could not fetch missing blob …: Concurrent RPC limit exceeded!
```

**Root cause:** BuildGrid's `thread-pool-size` defaults to 100. It maps
directly to both `max_workers` and `maximum_concurrent_rpcs` on the gRPC
server. Under load, 48 workers each pipeline several concurrent CAS RPCs
during staging; the 100-thread ceiling gets saturated and the server
rejects new requests.

**Fix:** bump `thread-pool-size` to `1000` in `k8s/20-buildgrid-config.yaml`.

Log line confirms after restart:
```
Setting up gRPC server. compression=0 max_workers=1000 maximum_concurrent_rpcs=1000
```

**Sizing hint:** roughly plan for `workers × 8–16` as an upper bound on
peak concurrent RPCs per BuildGrid replica. Cheaper to over-provision
threads than to hit the wall.

## 8. Runner-pod SIGSEGV in casd on fedora:41 base

**Assumption:** any recent Fedora base for the runner image would work,
since bst 2.8 + casd 1.4.15 work fine on brigid (Fedora 44).

**Observation:** the runner pod (originally `FROM fedora:41`) crashed
reproducibly with `Buildbox-casd died during the run. Exit code: -11`
(SIGSEGV). Only during active bst use — casd standalone (`--version`,
idle daemon) worked cleanly.

**Root cause:** glibc version mismatch. Bundled casd binary in the bst
2.8 pipx wheel is compiled against a newer glibc than Fedora 41 ships.
Idle codepaths work; concurrent RPC handling (CaptureFiles/CaptureTree
under load) tripped an ABI issue and crashed.

**Fix:** `FROM registry.fedoraproject.org/fedora:latest` (currently 44,
matching brigid's host). Verified with a small target build in the pod
— completed in 1:57, exit 0.

**Followup thought:** worth pinning to `fedora:44` explicitly rather
than `:latest` so a future `:latest` bump doesn't reintroduce drift
in the other direction.

## What we learned about running gbm against a fresh BuildGrid

## What we learned about running gbm against a fresh BuildGrid

- **Platform properties.** Any project that touches recc,
  `remote-apis-socket`, or custom sandbox integrations will send
  properties the vanilla scheduler doesn't know. Wildcard them all
  liberally in `!dynamic-property-set`.
- **Worker ephemeral scratch is big.** Multi-GiB per action is normal
  for OS-scale builds. Size worker `emptyDir` for the largest single
  action, not the average.
- **Local casd on the worker is really a proxy of *everything*.** If any
  action inside the sandbox uses the mounted casd socket for anything
  beyond CAS reads/writes (recc does), the local casd needs the full
  set of `--{cas,ac,exec,ra}-remote` flags. Missing one shows up as
  cryptic FAILED_PRECONDITION errors.
- **Never set a small gRPC deadline on the worker.** Integration
  commands can genuinely take minutes on OS-scale artifacts.
- **Most of gnome-build-meta pulls from `gbm.gnome.org:11003` as
  prebuilt artifacts.** For a fair "cluster stress" test, disable the
  upstream artifact cache via `BST_ARTIFACT_CACHES_OVERRIDE=none`, else
  you're mostly timing brigid's outbound bandwidth.
