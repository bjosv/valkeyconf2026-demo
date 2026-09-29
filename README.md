# ValkeyConf 2026 - Operator demo

A scripted, reproducible screencast of the Valkey operator, recorded with
[VHS](https://github.com/charmbracelet/vhs). The video is silent by design; it
is narrated live during the talk (slide 15).

The sequence:

1. **Deploy** a `ValkeyCluster` - TLS, an ACL user, live config,
   3 shards x 1 replica, and print the slot map.
2. **Start a write load** with an on-screen counter of acked vs lost writes.
3. **Upgrade** the Valkey image - rolling, replicas first, primary last.
4. **Scale out then in** (3 to 4 shards and back) with slot migration.
5. **Delete a primary pod** - Valkey fails over, the operator heals it.

The point of the demo: the `LOST` counter stays at **0** throughout, and the
`ROLE` column in `kubectl get valkeynodes` visibly changes during upgrade and
failover.

## Layout

```
+---------------------------+-------------------+
| action (your commands)    | write-load        |
| (deploy, upgrade, scale)  | (Writes/Acked/LOST)|
+---------------------------+-------------------+
| kubectl get valkeyclusters (STATE)            |
+-----------------------------------------------+
| kubectl get valkeynodes (ROLE)                |
+-----------------------------------------------+
```

The two bottom panes refresh every second (`watch`). Watch `STATE` in the
valkeyclusters pane and `ROLE` in the valkeynodes pane change during upgrade,
scale, and failover, while `LOST` in the write-load pane stays at 0.

## Prerequisites

Install these tools:

- [Docker](https://docs.docker.com/get-docker/) - runtime for kind
- [kind](https://kind.sigs.k8s.io/) - local Kubernetes in Docker
- [kubectl](https://kubernetes.io/docs/tasks/tools/) v1.31+
- [Helm](https://helm.sh/docs/intro/install/) 3 - installs the operator
- [VHS](https://github.com/charmbracelet/vhs) - records the terminal to MP4
- [ttyd](https://github.com/tsl0922/ttyd) - headless terminal VHS drives
- [tmux](https://github.com/tmux/tmux) - the multi-pane layout
- [ffmpeg](https://ffmpeg.org/) - VHS uses it to encode the video
- `openssl` - generates the demo TLS certificate

### Install on macOS (Homebrew)

```sh
brew install --cask docker
brew install kind kubectl helm vhs ttyd tmux ffmpeg
```

### Install on Linux

```sh
# Debian/Ubuntu base tools (use dnf/pacman on Fedora/Arch)
sudo apt-get install -y tmux ffmpeg openssl curl

# vhs (needs Go; ensure ~/go/bin is on PATH)
go install github.com/charmbracelet/vhs@latest

# ttyd (VHS drives it; distro packages are often old, so use the binary)
sudo curl -Lo /usr/local/bin/ttyd \
  https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.x86_64
sudo chmod +x /usr/local/bin/ttyd
# ARM64: use ttyd.aarch64  ·  or: pacman -S ttyd / dnf install ttyd / snap install ttyd --classic
```

Install **kind**, **kubectl**, and **helm** from their official docs:
[kind](https://kind.sigs.k8s.io/) ·
[kubectl](https://kubernetes.io/docs/tasks/tools/) ·
[helm](https://helm.sh/docs/intro/install/).

Docker (or Colima/OrbStack) must be running before you start - kind needs it.

### Verify everything is installed

```sh
make check
```

## Running the demo

```sh
# 1. Off-camera. Slow (image pulls, cluster bootstrap). Do NOT record this.
make setup

# 2. Record. Builds the tmux layout and drives the sequence via demo.tape.
make record        # -> out/demo.mp4

# 3. When done.
make teardown
```

To rehearse interactively instead of recording:

```sh
make layout               # build the panes
tmux attach -t demo       # drive the action pane yourself
make writeload            # start the counter when you reach that step
```

## Files

| Path | What |
|------|------|
| `manifests/valkeycluster.yaml` | Cluster: TLS, ACL user, cluster-node-timeout, 3x1 |
| `scripts/00-setup.sh` | Off-camera setup: kind, operator, secrets, image preload |
| `scripts/tmux-layout.sh` | Builds the tmux pane layout |
| `writeload-client/` | Go write-load client (persistent, cluster-aware) |
| `scripts/start-writeload.sh` | Runs the write-load client pod, shows the counter |
| `scripts/show-topology.sh` | Prints the per-primary slot map (used in step 1) |
| `scripts/teardown.sh` | Deletes the kind cluster |
| `demo.tape` | VHS script: the full recorded sequence |
| `SPEAKER_NOTES.md` | Talking points per demo step, for live narration |
| `Makefile` | `setup` / `layout` / `record` / `reset` / `teardown` |

## Notes and gotchas

- **Light theme** is set in `demo.tape` (`Github Light`) - reads better on a
  projector than a dark terminal.
- **Timings** in `demo.tape` (the `Sleep` lines) are tuned for a typical kind
  cluster. If your machine is slower, bump the sleeps so a step finishes before
  the tape moves on. Re-record until each step lands.
- **Two Valkey images** are pre-loaded in setup (`VK_FROM_IMG`, `VK_TO_IMG`) so
  the on-camera upgrade is instant. Set the starting version in the manifest
  (`spec.image`) and the target inline in the `demo.tape` upgrade patch; both
  need to exist in kind.
- **Scale-out/in needs Valkey 9.0+** (operator limitation). Use 9.x images.
- **TLS is a manual Secret** - the operator has no cert-manager integration yet,
  so `00-setup.sh` generates a self-signed cert. Its SANs must cover the pod
  FQDNs the operator dials (e.g. `valkey-my-cluster.demo.svc.cluster.local` and
  `*.valkey-my-cluster.demo.svc.cluster.local`), and the manifest sets
  `networking.discovery.preferredEndpointType: Hostname` so nodes are announced
  by name, not IP. The Secret also carries `ca.crt` (valkey and the metrics
  exporter mount it at `/tls`).
- **The demo ACL user needs CLUSTER read access.** A cluster-aware client
  (valkey-go) runs `CLUSTER SLOTS`/`SHARDS` to discover topology; the `demo`
  user therefore allows the read-only `cluster|...` subcommands. Without them,
  writes are misrouted and lost.
- **`cluster-node-timeout` is set to 5s** in the manifest so an abrupt
  primary-pod delete fails over quickly on camera; the default (15s) makes the
  failover window long and disruptive.
- **The write-load client** connects over TLS as the `demo` user with settings
  from the pod's environment (host `valkey-<cluster>`, CA at `/tls/ca.crt`,
  password from the ACL Secret via `secretKeyRef`, so no secret is shown on
  camera). It holds a persistent cluster connection and retries unacknowledged
  writes through failover/rebalance so `LOST` stays at 0. Rebuild it after code
  changes: `docker build -t writeload-client:demo ./writeload-client` then
  `kind load docker-image writeload-client:demo --name valkey-demo`.
- **Verify field names** against the operator version you install. These were
  written against the repo's `config/samples` and `docs/` (v1alpha1): top-level
  `spec.image`, `spec.networking.tls.certificates.server.secretName`,
  `spec.networking.discovery.preferredEndpointType`, and the `spec.users[]` ACL
  structure.
- Keep a **short fallback cut** (deploy + delete-primary only) in case the talk
  runs long; the speaker notes call for a ~4 min version.
