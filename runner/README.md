# bst in a pod — CI-runner style

Runs `bst build` inside a k8s Job instead of on brigid. Every build
gets a fresh clone of the target repo, uses cluster-internal BuildGrid,
and stores its cache on a cluster PVC. brigid is out of the critical
path.

Two pieces:
- **Runner image** (Dockerfile) — Fedora + bst + every plugin/tool we
  discovered gnome-build-meta needs.
- **k8s manifests** — PVC for the persistent bst cache, ConfigMap with
  the in-cluster BuildStream config, and a parameterized Job template.

## One-time setup

**Build and push the image to the in-cluster registry:**

```fish
cd ~/src/bst-k8s-buildgrid/runner
podman build -t fast-sfp1:30500/bst-runner:latest .
podman push  fast-sfp1:30500/bst-runner:latest
```

(Registry trust config was set up during the original BuildGrid
deployment — see the top-level README.)

**Apply the PVC + ConfigMap:**

```fish
kubectl apply -f 00-cache-pvc.yaml
kubectl apply -f 10-config.yaml
```

## Kicking off a build

Fill in the four env vars and apply the Job template:

```fish
set -x GIT_URL     https://gitlab.gnome.org/GNOME/gnome-build-meta.git
set -x GIT_REF     master
set -x BST_TARGET  gnomeos/live-image.bst
set -x JOB_NAME    gnome-os-(date +%s)

envsubst < job-template.yaml | kubectl apply -f -

# Follow the logs
kubectl -n buildgrid logs -f -l job-name=bst-build-$JOB_NAME
```

If `envsubst` isn't installed on brigid, `dnf install gettext` or use
`sed` / a heredoc.

## Retrieving the built artifact

The Job's final step checks the artifact into `/output/artifact` inside
the pod. To pull it to brigid:

```fish
# Find the pod (still running or completed within ttl)
set POD (kubectl -n buildgrid get pods -l job-name=bst-build-$JOB_NAME \
             -o jsonpath='{.items[0].metadata.name}')
kubectl -n buildgrid cp $POD:/output/artifact ./gnome-os-out
```

For a proper "publish the ISO" story, later replace the emptyDir output
mount with a MinIO/S3 sidecar upload as the last Job step.

## What still uses brigid

- Kicking off the Job (`kubectl apply`) — trivial, just an API call.
- Downloading the finished ISO (`kubectl cp`) — could be replaced by
  serving from MinIO in the cluster.

Everything else — clone, fetch sources, upload to CAS, submit to
BuildGrid, wait, checkout artifact — happens inside the cluster on the
runner pod.
