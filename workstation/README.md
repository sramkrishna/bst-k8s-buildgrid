# workstation/ — client-side helpers

Bits that run on your workstation (not the cluster) to make daily
operation nicer. Everything here is optional — the core cluster works
without any of it.

## What's here

- `bin/bst-wf-watcher` — bash script that watches Argo Workflows in the
  `buildgrid` namespace via `kubectl --watch`, and posts an ntfy.sh
  notification whenever a workflow reaches a terminal phase (Succeeded /
  Failed / Error).
- `systemd/bst-wf-watcher.service` — a systemd `--user` unit that runs
  the watcher as a background service, restarts it if `kubectl`'s watch
  stream expires (the k8s API server closes long-lived watches after
  ~30-60 min), and persists a "notified" state file so restarts don't
  spam re-notifications.

## Install

```bash
# 1. Copy the script into a location on $PATH (must be before any brew paths
#    if you also have Homebrew installed).
install -m 0755 workstation/bin/bst-wf-watcher ~/.local/bin/bst-wf-watcher

# 2. Copy the unit file into your systemd user directory.
install -m 0644 -D workstation/systemd/bst-wf-watcher.service \
    ~/.config/systemd/user/bst-wf-watcher.service

# 3. Reload systemd and enable the unit.
systemctl --user daemon-reload
systemctl --user enable --now bst-wf-watcher.service

# 4. (Optional) Keep it running after logout — worth it for a laptop that's
#    always on but sometimes logged out.
loginctl enable-linger $USER
```

## Configure

The script reads a few env vars, all with sensible defaults:

| Var             | Default                                     | Purpose                        |
|-----------------|---------------------------------------------|--------------------------------|
| `NAMESPACE`     | `buildgrid`                                 | Argo namespace to watch        |
| `NTFY_URL`      | `http://100.106.218.95:2586/gnome_os_notify`| Where to POST notifications    |
| `MINIO_BASE`    | `http://192.168.88.11:30900/artifacts/runs` | Prefix for the artifacts link  |
| `STATE_DIRECTORY` | (set by systemd, `~/.local/state/bst-wf-watcher`) | Where the notified-set lives |

**Edit these in the systemd unit** by adding an `Environment=` line under
`[Service]`, or by dropping an override file at
`~/.config/systemd/user/bst-wf-watcher.service.d/override.conf`.

## Ops

```bash
systemctl --user status  bst-wf-watcher.service --no-pager
systemctl --user restart bst-wf-watcher.service
journalctl --user -u bst-wf-watcher -f            # live logs

# Nuke the notified-set (will re-fire ntfys for everything currently terminal on next start)
rm ~/.local/state/bst-wf-watcher/notified
systemctl --user restart bst-wf-watcher.service

# Test the ntfy channel end-to-end without going through Argo:
curl -d "test from $USER" "$NTFY_URL"
```

## Design notes

- **`Restart=always`, not `on-failure`.** `kubectl --watch` exits cleanly
  (status 0) when the API server closes the stream — `on-failure` would
  leave the watcher silently stopped, and any workflow that terminates
  during the gap would go unreported.
- **Catch-up on startup.** If the state file is non-empty (i.e. this is
  a restart, not the first-ever install), any workflow that terminated
  while the watcher was down will get a delayed ntfy on the next start.
  First-ever install seeds silently to avoid paging for old history.
- **Runs on the workstation, not the cluster.** Nodes in this setup
  aren't on Tailscale, so pods can't reach an ntfy server bound to a
  Tailscale IP. Firing from the workstation sidesteps the whole class
  of cluster-egress problems.
