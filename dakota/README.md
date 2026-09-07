# dakota/ — Project Dakota builds

Argo Workflow example that consumes the generic `bst-build` WorkflowTemplate
with Dakota-specific arguments.

**Status: untested.** Dakota is BuildStream-based and consumes
gnome-build-meta as a junction, so the same `bst-build` template pipeline
(clone → snakeoil-if-present → bst build → checkout → MinIO mirror) *should*
work. But we haven't fired a Dakota workflow yet on this cluster; the
`target` element name in `example-workflow.yaml` is a placeholder and needs
verification against the current Dakota tree.

## Prerequisites

Same as `gnome/`:

- `argo/10-bst-build.yaml` applied
- Optionally, the MinIO layer

Additionally, if Dakota needs Dakota-specific pre-build setup (analogous to
GNOME OS's snakeoil boot keys), that logic will need to be added to the
`bst-build` template's `bst-run` script, or split into a Dakota-specific
WorkflowTemplate that extends `bst-build`.

## First-run checklist

1. Clone Dakota locally and confirm the target element:
   ```bash
   git clone --depth=1 https://github.com/projectbluefin/dakota.git
   cd dakota && ls elements/ images/     # or wherever the top-level lives
   ```
2. Update `dakota/example-workflow.yaml` `target` to whatever's real.
3. Fire it:
   ```bash
   kubectl -n buildgrid create -f dakota/example-workflow.yaml
   ```
4. Watch:
   ```bash
   argo -n buildgrid get <dakota-wf-name>
   argo -n buildgrid logs <dakota-wf-name> -f
   ```
5. If the build succeeds but the final artifact is a bootc OCI image rather
   than a filesystem tree, the `bst artifact checkout` + `mc mirror` steps
   in the shared template may need extending to push the OCI image to a
   registry instead of dropping files in MinIO. That's Dakota-specific
   plumbing — carve it out into its own WorkflowTemplate at that point,
   rather than bloating the shared one.

## Related

The projectbluefin/lab repo runs Dakota builds via Argo Workflows as its
production pipeline; parts of the shared `bst-build` template are inspired
by their `dakota-build-pipeline`. See:
https://github.com/projectbluefin/lab
