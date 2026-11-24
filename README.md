# bolt-deploy.sh

### Installation

      /bin/bash -c "$(curl -fsSL (https://raw.githubusercontent.com/ProjectZeroDays/bolt-installer/refs/heads/Your-Momma-Beeotch/install.sh))"

One-shot installer and launcher for [bolt](https://github.com/cyberstrikeus/bolt) — the
containerized security-tool MCP server. Detects the host, installs Docker if it's
missing, pulls the image digest pinned to the host architecture, starts the
container, mints a pairing code, and opens a local control panel.

## What it does

In order, aborting on the first hard failure:

1. Detects OS family and distro from `uname` and `/etc/os-release`; flags WSL.
2. Maps `uname -m` to `linux/amd64` or `linux/arm64` and selects the matching
   pinned digest.
3. Installs Docker if no `docker` binary is present — `get.docker.com` on Linux,
   `brew install --cask docker` on macOS, distro packages if that host is
   unreachable.
4. Starts the daemon and waits up to 60s for it to answer.
5. Resolves an admin token: `--token`, then a running container's env, then the
   saved token file, then a fresh 32-byte random value. Saved to disk either way.
6. Refuses to start if the port is taken by something else.
7. Pulls the pinned image, retrying via tag if the digest pull fails.
8. Runs the container with `NET_RAW` + `NET_ADMIN`, a `/data` volume, and
   `--restart unless-stopped`.
9. Waits for `/health` to return 200 (90s budget).
10. Mints a single-use pairing code via `POST /pair`.
11. Writes a local HTML control panel.
12. Opens the panel, falling back to `/health`.

## Requirements

- Linux, macOS, or WSL2.
- `amd64` or `arm64`. Other architectures fall back to the index digest and then
  to the bare tag, which may not resolve.
- `sudo` (or root), `curl`, `openssl`.
- macOS: Homebrew, and Docker Desktop must be installable and launchable.
- WSL: Docker Desktop with WSL integration, or a systemd-enabled distro.
  Bare WSL1 will not start a daemon.

## Quick start

```sh
chmod +x bolt-deploy.sh
sudo ./bolt-deploy.sh
