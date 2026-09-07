# Running changedetection.io with Podman

This directory **adds** Podman support. It does not change or replace the
project's Docker support — `Dockerfile`, `docker-compose.yml` and
`docker-entrypoint.sh` in the repository root are untouched and remain the
Docker path.

Everything here targets **rootless** Podman, which is the default mode and the
one that matters if you cannot install or run Docker.

| File | What it is |
| --- | --- |
| `podman-compose.yml` | Compose file with the rootless-Podman deltas applied |
| `changedetection.container` / `changedetection.volume` | Quadlet systemd units — the native Podman deployment |
| `changedetection-kube.yaml` | Manifest for `podman kube play` (and real Kubernetes) |
| `build.ps1` / `run.ps1` / `logs.ps1` | Windows one-liners |

## Windows: Podman Desktop + WSL2

Podman on Windows runs a Linux VM (`podman machine`) on top of **WSL2**, so WSL
has to exist first. Installing it needs administrator rights — this is the only
elevated step.

```powershell
# elevated PowerShell, once; reboot afterwards
wsl --install --no-distribution

winget install RedHat.Podman-Desktop

# 2 CPUs / 2GB is not enough once Chrome-based fetching is enabled
podman machine init --cpus 4 --memory 4096 --disk-size 60
podman machine start

podman info      # must succeed before anything below will work
```

### Then

```powershell
.\contrib\podman\build.ps1        # build the image from this repo
.\contrib\podman\run.ps1          # run it, http://localhost:5000
.\contrib\podman\logs.ps1         # follow the logs
```

Or pull the prebuilt image instead of building:

```powershell
podman pull ghcr.io/dgtlmoon/changedetection.io:latest
podman-compose -f contrib/podman/podman-compose.yml up -d
```

### Build speed on Windows

The repository lives on the Windows filesystem, which the podman machine reaches
through the 9p mount at `/mnt/c/...`. That path is slow, and this image installs
a large dependency tree. If a build feels stalled rather than slow, clone into
the WSL filesystem and build there:

```powershell
podman machine ssh
git clone https://github.com/dgtlmoon/changedetection.io.git ~/changedetection.io
cd ~/changedetection.io && podman build -t changedetection:dev .
```

## Linux: Quadlet (systemd)

The deployment path with no compose dependency at all.

```bash
mkdir -p ~/.config/containers/systemd
cp changedetection.container changedetection.volume ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user start changedetection
journalctl --user -u changedetection -f

# keep it running after you log out
loginctl enable-linger "$USER"
```

`AutoUpdate=registry` is set, so `podman auto-update` pulls and restarts on a
new `:latest` tag.

## Rootless gotchas, and why the files look the way they do

**Use the named volume, not a bind mount.** Rootless Podman maps the container's
root to your unprivileged uid. A host bind mount at `/datastore` therefore
arrives owned by ids the container cannot write, and changedetection.io fails on
first write. `changedetection-data:/datastore` avoids this completely. If you do
bind-mount something (`proxies.json`, say), append `:Z` so SELinux relabels it —
required on Fedora/RHEL, harmless elsewhere.

**Chrome needs a bigger `/dev/shm`.** Podman defaults it to 64MB. The
`sockpuppetbrowser` service crashes with renderer / "Target closed" errors well
before that is genuinely exhausted, so `shm_size: 2gb` is set on it. The same
applies to a plain `podman run`: pass `--shm-size=2g`.

**Ports stay above 1024.** Rootless cannot bind privileged ports without
lowering `net.ipv4.ip_unprivileged_port_start`, so 5000 is kept as-is. Put a
reverse proxy in front rather than moving the container to 80/443.

**Image names are fully qualified.** Podman has no implicit Docker Hub, and an
unqualified name either prompts for a registry or fails outright in a
non-interactive shell. Every image here is written as
`ghcr.io/...` or `docker.io/...`.

**`--mount=type=cache`.** The root `Dockerfile` uses BuildKit cache mounts in
four places. Buildah supports them, so `podman build` works unmodified. On an
older Buildah that mishandles them, build with `.\build.ps1 -NoCache`.

**`podman-compose` vs `podman compose`.** These are different programs:
`podman-compose` is a standalone Python implementation, while `podman compose`
delegates to whatever external compose binary it can find. `podman-compose.yml`
is written for and tested against **`podman-compose`**.

```powershell
pip install podman-compose
```

## Data and backups

Everything lives in the `changedetection-data` volume.

```bash
podman volume export changedetection-data -o changedetection-backup.tar
podman volume import changedetection-data changedetection-backup.tar
```
