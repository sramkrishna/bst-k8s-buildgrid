# gnome/ — GNOME OS builds

Ready-to-fire Argo Workflows that consume the generic `bst-build`
WorkflowTemplate (`argo/10-bst-build.yaml`) with GNOME-specific arguments
(repo, ref, target).

## What's here

- `smoke-workflow.yaml` — builds one small element from freedesktop-sdk.
  Wall time ~1-5 min warm. Use this to prove the pipeline works before
  waiting on a full ISO.
- `live-image-workflow.yaml` — full `gnomeos/live-image.bst`. Produces a
  ~3.5 GiB `disk.iso` in MinIO under `artifacts/runs/gnome-os-<random>/`.
  Wall time ~10-20 min warm.

## Prerequisites

- `argo/10-bst-build.yaml` applied (the `bst-build` WorkflowTemplate)
- Optionally, the MinIO layer applied — without it, the workflow still
  succeeds but the final upload step will fail (harmlessly, per the
  `|| true` in the script).

## Fire

```bash
kubectl -n buildgrid create -f gnome/smoke-workflow.yaml       # small
kubectl -n buildgrid create -f gnome/live-image-workflow.yaml  # full ISO
```

Track with `argo -n buildgrid list` or `argo -n buildgrid get <wf-name>`.

## Adapting for a fork or branch

Copy one of the manifests and change `ref` (branch/tag/commit) and/or
`repo` (fork URL). Everything else stays the same.

```yaml
# gnome/my-fork-workflow.yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: gnome-my-fork-
  namespace: buildgrid
spec:
  workflowTemplateRef: { name: bst-build }
  arguments:
    parameters:
      - { name: repo,   value: https://gitlab.gnome.org/YOUR-USER/gnome-build-meta.git }
      - { name: ref,    value: my-feature-branch }
      - { name: target, value: gnomeos/live-image.bst }
```
