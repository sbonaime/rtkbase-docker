# RTKBase Docker Recipe

> Recipe to build and rebuild a Docker image of https://github.com/Stefal/rtkbase,
> intended to run on a MacBook Air M1 (Apple Silicon / arm64) with Docker Desktop.

Files in this repo:
- [`Dockerfile`](Dockerfile) — builds the image from a chosen RTKBase git ref.
- [`entrypoint.sh`](entrypoint.sh) — wires up persistent state, then starts systemd.
- [`docker-compose.yml`](docker-compose.yml) — run configuration (privileged mode, volumes, port).
- [`docker-compose.usb.yml`](docker-compose.usb.yml) — optional overlay to pass a physical
  USB/serial GNSS receiver through to the container (see section 3a).
- [`build.sh`](build.sh) — builds/tags an image for a given ref (defaults to the latest release),
  and exports it as `rtkbase-<ref>.tar.gz` at the repo root for offline transfer (see section 4b).

## 1. What RTKBase is

RTKBase is **not designed to run in a container**. It's a set of bash scripts plus a Python
(Flask/SocketIO) web app, meant to be installed directly on an SBC (Raspberry Pi, Orange Pi...)
via `tools/install.sh`. There is **no official Dockerfile** in the upstream repository.

Key components:
- **`web_app/`** — the Flask/SocketIO web UI (`server.py` is the entry point, served through
  gunicorn+gevent). Requires Python >= 3.11.
- **RTKLIB (`str2str`, `rtkrcv`, `convbin`)** — compiled from
  https://github.com/rtklibexplorer/RTKLIB (tag v2.5.0), either from a prebuilt binary shipped
  for known SBCs, or compiled from source as a fallback (which is what happens automatically
  in a generic container, since it isn't a Raspberry Pi/Orange Pi).
- **systemd units** (`unit/*.service`) — `rtkbase_web`, `str2str_tcp`, `str2str_ntrip_*`,
  `rtkbase_archive.timer`, etc. `run_cast.sh` reads `settings.conf` and launches the right
  `str2str` instance for each unit.
- **Important detail found while reading `web_app/server.py` / `ServiceController.py`**:
  the web UI does **not** just shell out to `systemctl` for convenience — it talks to systemd
  directly over D-Bus using **`pystemd`** to start/stop/restart services and report their
  status, and it runs `systemctl status` / `journalctl` for the `/diagnostic` page. This means
  **a real systemd instance must be reachable inside the container** for the web UI's service
  toggle switches and diagnostics page to work at all.
- **gpsd + chrony** — used to sync system time from the GNSS receiver's PPS signal. Not
  applicable without real hardware/GPIO, skipped in this recipe.
- **udev rules + polkit** — used to detect/authorize access to the GNSS receiver's serial/USB
  port on the host SBC. In practice, `install.sh`'s `install_polkit_rules.sh` never actually
  installs `polkitd`/copies its rules on this Debian bookworm base (a `dpkg-query` guard in that
  script always considers polkitd "already present" and skips it — confirmed with both this
  image and the original single-stage one), so those rules simply don't exist here either way;
  this is harmless since services already run as root in the container.
- Hardware access required for real use: the GNSS receiver's serial/USB port
  (`/dev/ttyUSB0`, `/dev/ttyACM0`, a UART, ...).

Upstream requirements: **Debian >= 12 (bookworm)**, **Python >= 3.11**.

## 2. Consequence: why this image runs systemd as PID 1

Because `pystemd`/`systemctl`/`journalctl` are baked into the web app itself (not something we
can easily patch out without diverging from upstream), the most faithful way to containerize
RTKBase is to **run systemd inside the container** and let `install.sh` set things up exactly
as it does on a real machine, rather than reinventing a custom process supervisor that the web
UI wouldn't know how to talk to.

Practical implications:
- The image installs `systemd`/`systemd-sysv`/`dbus`, and `ENTRYPOINT` execs `/sbin/init`.
- The container must run **`privileged`** (or an equivalent fine-grained set of
  capabilities/mounts) so systemd can manage cgroups — see `docker-compose.yml`.
- `gpsd`, `chrony`, `avahi`/zeroconf and GNSS auto-detection/configuration are **not** installed
  by default at build time (no real hardware/GPIO at build time, and no point in an NTP source
  for a container). They can be added later by running the matching `install.sh` steps manually
  inside a shell in the container if really needed.

## 2a. Reducing the image size (multi-stage build)

RTKBase's own installer needs a full build toolchain to work: `gcc`/`make`/`build-essential` to
compile RTKLIB from source, `python3-dev`/`libxml2-dev`/`libxslt-dev`/`libssl-dev`/`libffi-dev`
so `pip` can build C extensions (`lxml`, `pystemd`, `gevent`...), plus `git`/`wget` to fetch
sources. None of that toolchain is needed once `str2str`/`rtkrcv`/`convbin` are built and the
venv's packages are installed — so the [`Dockerfile`](Dockerfile) uses a **two-stage build**:
a `builder` stage runs the exact same `install.sh` steps as before, and a slim `final` stage
(`debian:bookworm-slim`) only installs the runtime packages/shared libraries and `COPY
--from=builder` the actual build output (the `rtkbase` checkout + venv, the compiled RTKLIB
binaries, systemd units, udev rules, `/etc/environment`).

The builder stage also strips a few things that were pure dead weight in the old single-stage
image, discovered by inspecting the built image's filesystem (`docker history` /
`du -sh` inside a running container):
- The cloned `rtkbase` repo's `.git` directory (**~280MB** of history, never read at runtime).
- `tools/bin/` prebuilt RTKLIB binaries for other SBC architectures/models (armv6l, armv7l, and
  an aarch64 copy) — `install.sh` only uses these when
  `/sys/firmware/devicetree/base/model` matches a short Raspberry Pi/Orange Pi allowlist, which a
  generic container (or a Teltonika router) never does, so it always compiles from source
  instead; the binary that's actually used is already installed to `/usr/local/bin`.
- Leftover `pip`/`apt` caches from `install.sh`'s own internal `pip install`/`apt-get install`
  calls.

**Measured result** (`docker buildx build --platform linux/arm64`, RTKBase v2.7.0): **1.42GB →
462MB**, about a **67% reduction**. Verified functionally identical to the previous single-stage
image by running both side by side (`docker run` with the same privileged/cgroup flags as
`docker-compose.yml`): same `systemctl status` output for `rtkbase_web`/`str2str_tcp`, same HTTP
302 from the web UI, same RTKLIB binary `--version` output, and the venv's compiled Python
extensions (`lxml`, `pystemd`, `gevent`) import fine against the final stage's runtime-only
`libxml2`/`libxslt1.1`/`libssl3`/`libffi8` packages.

Nothing changes for day-to-day usage — `./build.sh` and `docker compose up -d` work exactly as
described in section 4, just producing/running a smaller image.

## 3. macOS / Apple Silicon (M1) limitations

- **Architecture**: the M1 is `arm64/aarch64`. `build.sh` builds for `linux/arm64` explicitly
  via `docker buildx`, which matches Docker Desktop's Linux VM on Apple Silicon. RTKLIB is
  compiled from source in the image rather than reusing upstream's prebuilt `aarch64` binaries,
  to avoid any glibc/libc mismatch.
- **Privileged containers**: Docker Desktop on macOS runs everything inside one Linux VM, and
  `--privileged` containers work fine there (this isn't a bare-metal Linux kernel concern) — no
  special host configuration is required beyond what's already in `docker-compose.yml`.
- **GNSS receiver access (USB/serial) is the real limitation**: on Linux, passing through a
  device is a simple `--device /dev/ttyUSB0`. **Docker Desktop for Mac does not expose host
  USB/serial devices to its Linux VM** — there is no direct passthrough. Options:
  - Point RTKBase at a GNSS receiver that's reachable over the network (some receivers expose a
    TCP raw stream), instead of a local serial port.
  - Use a USB-over-IP solution (e.g. `usbip`) to expose the host's USB device into the VM —
    possible but fiddly and not guaranteed stable.
  - Treat the Mac as a **build/dev machine only**: build and test the image (web UI, service
    plumbing) on the M1, then transfer it to a real Linux SBC/router with the receiver plugged
    in — either via `./build.sh` + `docker load` (section 4b) or `docker buildx build --push`
    to a registry — and actually run/deploy it there.
- **Practical takeaway**: on the Mac itself, expect to be able to build the image, start it, and
  reach the web UI (in a "no receiver configured" state). Full end-to-end use with a real GNSS
  receiver needs either a Linux host or a network-attached receiver.

## 3a. USB/serial GNSS receiver passthrough (Linux hosts)

On a Linux host (bare metal, VM, SBC, or a Linux-based router such as the Teltonika RUTC40 —
see section 3b), the container can be given direct access to the receiver's USB serial device
node via the `docker-compose.usb.yml` overlay, kept separate from `docker-compose.yml` so the
default `docker compose up -d` workflow (e.g. on macOS) is unaffected.

1. Plug the receiver in and find its device node on the host:
   ```bash
   ls -l /dev/serial/by-id/          # preferred: stable name, survives reboots/re-enumeration
   # or, less stable (can shift if other USB-serial devices are plugged/unplugged):
   ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null
   ```
2. Launch with that path as the `RTKBASE_USB_DEVICE` parameter:
   ```bash
   RTKBASE_USB_DEVICE=/dev/serial/by-id/usb-u-blox_..._if00 \
     docker compose -f docker-compose.yml -f docker-compose.usb.yml up -d
   ```
   Or persist it in a `.env` file (`RTKBASE_USB_DEVICE=/dev/ttyACM0`) next to the compose files
   and just run `docker compose -f docker-compose.yml -f docker-compose.usb.yml up -d`.
3. From the RTKBase web UI, configure the GNSS receiver to use that same path inside the
   container (the overlay maps the host path to the identical path in the container, so
   whatever `RTKBASE_USB_DEVICE` was set to is what `settings.conf` should reference).

The container already runs `privileged: true` (needed for systemd, see section 2), so no
additional udev/permission setup is required for the device node to be accessible.

## 3b. Running on ARM SBCs / routers (e.g. Teltonika RUTC40/RUTC50, Cortex-A53)

The RUTC40/RUTC50 are `arm64/aarch64` (Cortex-A53), the same target architecture `build.sh`
already builds for (`linux/arm64`, chosen originally for Apple Silicon), so the same image
applies as-is — no second recipe is needed purely for the CPU architecture. What follows is
confirmed from an actual RUTC50 deployment (RutOS Docker feature):

- **`docker compose` is not available on RutOS.** Its `docker`/`dockerd` opkg packages ship only
  the engine and the base `docker` CLI — there is no `docker-compose`/`docker compose` plugin
  binary and none is offered through `opkg`. Don't rely on `docker-compose.yml` /
  `docker-compose.usb.yml` on this device; use the equivalent `docker run` command instead (see
  section 4c for a full example combining the base config + USB passthrough).
- **The Docker service is disabled by default and needs its storage pointed at external
  storage.** Even after installing the `docker`/`dockerd` packages (via the RutOS web UI or
  `opkg`), the UCI config (`/etc/config/dockerd`, section `globals`) ships with `option enabled
  '0'` and `option data_root '/opt/docker/'` — `/opt` lives on the tiny internal
  overlay/flash partition (~200MB total on a RUTC50), nowhere near enough for a Docker image
  store. Before anything else works:
  ```bash
  uci set dockerd.globals.enabled='1'
  uci set dockerd.globals.data_root='/mnt/sda/docker/data'   # or wherever your external storage is mounted
  uci commit dockerd
  /etc/init.d/dockerd restart
  ```
  (The RutOS web UI's Services → Docker page sets the same UCI options, if you prefer that.)
- **The external storage must be a Linux-native filesystem (ext4), not FAT32/exFAT.** A USB
  key/SD card mounted as `vfat` cannot back Docker's `overlay2` storage driver (`failed to mount
  overlay: invalid argument` in the dockerd log — FAT lacks the symlink/xattr/permission support
  overlay2 needs) or even `fuse-overlayfs` (not installed on RutOS). Docker then silently falls
  back to the `vfs` storage driver, which is both extremely slow (`docker load`/`docker run` can
  hang for many minutes doing full file copies instead of copy-on-write) and can still fail
  outright on files a FAT filesystem simply cannot represent (symlinks, device nodes). If
  `mount | grep <your storage>` shows `type vfat`, reformat it as ext4 first:
  ```bash
  /etc/init.d/dockerd stop
  umount /mnt/sda
  mkfs.ext4 -F /dev/sda      # WARNING: erases everything on that device
  mount /dev/sda /mnt/sda
  /etc/init.d/dockerd start
  ```
  After this, dockerd's log should show `storage-driver=overlay2` (not `vfs`), and `docker
  load`/`docker run` become fast and reliable again.
- **Privileged containers / cgroups**: this image needs `--privileged`, `cgroup: host` and a
  `/sys/fs/cgroup` mount so systemd can boot as PID 1 (section 2). Confirmed working on RutOS:
  `mount | grep cgroup` shows `cgroup2` mounted, and `--privileged` containers start fine.
- **Storage/RAM constraints for the image itself**: thanks to the multi-stage build (section
  2a), the image is ~460MB instead of ~1.4GB, which fits much more comfortably once external
  storage is used correctly (see above). RTKLIB and the Python venv are still compiled/built
  during the build itself, which is RAM/CPU intensive — build on a workstation instead, then
  transfer the prebuilt image to the router (`./build.sh` + `docker load`, see section 4b),
  rather than building on-device.
- **USB passthrough**: unchanged — the GNSS receiver plugged into the router shows up as a
  `/dev/ttyUSB*`/`/dev/ttyACM*` node, or (as seen in practice on a RUTC50) a stable
  `/dev/usb_serial_<id>` alias created by RutOS's own udev rules. Either way, pass that device
  path through with `--device=<path>:<path>` on `docker run` (section 4c), the same principle
  as the `RTKBASE_USB_DEVICE` compose overlay described in section 3a.

## 4. Usage

```bash
# One-off build for the latest RTKBase release, loaded into the local Docker Desktop:
./build.sh

# Build a specific ref (release tag, branch, or commit):
./build.sh dev

# Run it (creates ./rtkbase-data on the host for persistent settings/data/logs):
docker compose up -d

# Run it with a physical USB/serial GNSS receiver passed through (Linux host, see section 3a):
RTKBASE_USB_DEVICE=/dev/ttyACM0 docker compose -f docker-compose.yml -f docker-compose.usb.yml up -d

# Web UI:
open http://localhost:8080
# Default password: admin (see upstream README) — change it from the settings page.
```

### 4a. Build example — macOS / Apple Silicon (local use)

`build.sh` already targets `linux/arm64` and uses `--load`, which is exactly what an Apple
Silicon Mac needs (Docker Desktop's VM is arm64, so the image runs natively, no emulation):

```bash
# From the repo root, on a MacBook (M1/M2/M3, arm64):
./build.sh                 # latest RTKBase release -> rtkbase:latest, rtkbase:<tag>, loaded locally
./build.sh v2.7.0           # or a specific release/branch/commit ref

# Then run it locally:
docker compose up -d
open http://localhost:8080
```

No extra flags needed: the resulting image stays in the local Docker Desktop image store and
is used directly by `docker-compose.yml`.

### 4b. Build example — Teltonika RUTC50 (arm64 router)

The RUTC50 (like the RUTC40) is `arm64/aarch64`, so it needs the same `linux/arm64` image —
but its flash/RAM are too limited to build on-device (see section 3b), and it typically has no
access to a Docker registry. `build.sh` already builds for `linux/arm64` and, by default, also
exports the result as a single `rtkbase-<ref>.tar.gz` file at the repo root — copy that file
over and `docker load` it directly on the router, no registry involved:

```bash
# 1. On your build workstation (Mac, Linux, CI runner...), just run the normal build:
./build.sh v2.7.0
# -> produces both rtkbase:v2.7.0 / rtkbase:latest locally, AND
#    ./rtkbase-v2.7.0.tar.gz (a gzipped `docker save` of both tags, ~190MB for a 462MB image)

# 2. Copy that file to the RUTC50 (scp over the router's LAN/VPN, a USB key, etc.):
scp rtkbase-v2.7.0.tar.gz root@<rutc50-ip>:/tmp/

# 3. On the RUTC50 itself (SSH), load it — this recreates both the "rtkbase:v2.7.0" and
#    "rtkbase:latest" tags exactly as they exist locally, ready for docker-compose.yml's
#    `image: rtkbase:${RTKBASE_REF:-latest}`:
docker load -i /tmp/rtkbase-v2.7.0.tar.gz

# 4. Then run it — RutOS has no `docker compose` (see section 3b), so use the plain
#    `docker run` equivalent instead; see section 4c for the full command.
```

Set `EXPORT_TAR=0 ./build.sh` to skip producing the `.tar.gz` (e.g. for quick local-only
rebuilds during development). If you do have a registry reachable from the router instead,
`docker buildx build --platform linux/arm64 --push` works too — but for a router with no
registry access, the `docker save`/`docker load` file transfer above is simpler and doesn't
need a `docker login`. Either way, see section 3b for the RutOS-specific setup (enabling the
Docker service, pointing its storage at external ext4 storage) needed before either approach
works.

### 4c. Running on RutOS (no `docker compose`) — plain `docker run`

As found in section 3b, RutOS ships no `docker compose`/`docker-compose` plugin at all. The
following reproduces the exact same configuration as `docker-compose.yml` +
`docker-compose.usb.yml` combined, using only the base `docker` CLI:

```bash
# Persistent state directory, on the external ext4 storage (see section 3b) rather than the
# tiny internal flash:
mkdir -p /mnt/sda/docker/rtkbase-data

docker run -d --name rtkbase \
  --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run --tmpfs /run/lock \
  -p 8080:80 \
  -v /mnt/sda/docker/rtkbase-data:/persist \
  --device=/dev/ttyUSB4:/dev/ttyUSB4 \
  --restart unless-stopped \
  rtkbase:latest
```

- Replace `/dev/ttyUSB4` with your GNSS receiver's actual device path — on a RUTC50 this can
  also be a stable `/dev/usb_serial_<id>` alias created by RutOS's own udev rules rather than a
  plain `/dev/ttyUSB0`/`/dev/ttyACM0` (check with `ls -la /dev/ttyUSB* /dev/usb_serial_*` or
  `dmesg` after plugging the receiver in). Configure the GNSS receiver in the RTKBase web UI to
  use that same path.
- Adjust `/mnt/sda/docker/rtkbase-data` to wherever your external storage is mounted.
- Check `docker images` first to confirm the loaded image's actual tag (`rtkbase:latest` or
  `rtkbase:<ref>`) if you didn't load both tags.
- Manage it afterwards with plain `docker` commands: `docker ps -a`, `docker logs rtkbase`,
  `docker restart rtkbase`, `docker stop rtkbase`, etc. — there is no `docker compose down`
  equivalent needed since there's no compose project here, just `docker rm -f rtkbase` to
  remove it.

Persistent state lives under `./rtkbase-data/` on the host (`settings.conf`, `data/`, `logs/`),
mounted at `/persist` in the container and symlinked into place by `entrypoint.sh`. Rebuilding
the image (new RTKBase version) and recreating the container keeps that state intact.

**Always start the container via `docker compose up -d`, not a plain `docker run rtkbase:latest`.**
Since this image runs systemd as PID 1 (see section 2), it needs the privileged mode, cgroup
namespace and `/sys/fs/cgroup` mount that `docker-compose.yml` provides — without them systemd
fails to boot and the container exits immediately (exit code 255, no logs). If you need the
`docker run` equivalent (e.g. for scripting), reproduce the same flags:

```bash
docker run -d --name rtkbase \
  --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run --tmpfs /run/lock \
  -p 8080:80 \
  -v "$(pwd)/rtkbase-data:/persist" \
  rtkbase:latest
```

## 5. Rebuilding when the upstream repo is updated

`build.sh`:
1. Resolves the RTKBase ref to build: an explicit argument (tag/branch/commit), or by default
   the **latest GitHub release** (`GET /repos/Stefal/rtkbase/releases/latest`).
2. Runs `docker buildx build --platform linux/arm64 --build-arg RTKBASE_REF=<ref> -t
   rtkbase:<ref> -t rtkbase:latest --load .` — the `Dockerfile` always re-downloads
   `install.sh` and clones `rtkbase` at that ref during the build, so nothing about the
   RTKBase source is cached/vendored locally.
3. Tags the resulting image with the RTKBase ref, so you can keep older images around
   (`rtkbase:v2.7.0`, `rtkbase:dev`) and roll back by just running a different tag.
4. Exports both tags as a single `rtkbase-<ref>.tar.gz` file at the repo root
   (`docker save ... | gzip`), ready to be copied to and `docker load`-ed on a device with no
   registry access (section 4b). Set `EXPORT_TAR=0` to skip this step.

To publish/deploy on another machine over a registry instead of a file transfer (e.g. a
Raspberry Pi actually connected to the GNSS receiver, reachable from a registry), add
`--platform linux/arm64,linux/amd64 --push` (with a registry login) instead of `--load`.

Optional next step: a small GitHub Actions workflow (schedule-triggered) that checks for a new
RTKBase release and re-runs `build.sh` + pushes automatically — not set up yet, left as a TODO.

## 6. Validation status

Build-tested end-to-end on a MacBook Air M1 (`docker buildx build --platform linux/arm64`,
image size **462MB** since the multi-stage build described in section 2a, down from the
original single-stage image's ~1.42GB) and run-tested with `docker compose up -d`:
- `systemctl is-system-running` reports `running` inside the container.
- `rtkbase_web.service` is `active (running)`, and the login page is served correctly on
  `http://localhost:8080`.
- `str2str_tcp.service` fails to start (`stream server start error`, auto-restart loop) — this
  is **expected**: `settings.conf` has no GNSS receiver configured/attached, exactly the
  limitation described in section 3.
- Re-validated after the multi-stage refactor by running the old single-stage image and the new
  slim one side by side with identical flags: same `systemctl status` output for both services,
  same HTTP 302 from the web UI, same RTKLIB binary `--version` output, and the venv's compiled
  extensions (`lxml`, `pystemd`, `gevent`) import fine.
- Validated the `docker save`/`docker load` file-transfer path (section 4b): `./build.sh`
  produces `rtkbase-<ref>.tar.gz` (~192MB compressed for the 462MB image); after removing the
  local images entirely and reloading from that file, both `rtkbase:<ref>` and `rtkbase:latest`
  tags are restored, and `docker compose up -d` boots and serves the web UI identically.

Known harmless noise seen during build/run (all non-fatal, matches what's expected from running
`install.sh` outside a real SBC with systemd not yet booted):
- `udevadm control --reload`: `Failed to send reload request: No such file or directory`.
- `install_polkit_rules.sh`: `cp: cannot create regular file '/etc/polkit-1/rules.d/'`.
- `opizero_temp_offset.sh`: `/sys/class/thermal/thermal_zone0/temp: No such file or directory`.
- `systemctl enable ...` during the Docker build: `Failed to connect to bus: Host is down`
  (falls back to plain symlink creation, which is all `enable` needs — confirmed working).
- One `AssertionError` traceback from `gevent`/`socketio` right after `rtkbase_web` starts;
  the service stays active and the web UI responds normally, so this looks cosmetic, but keep
  an eye on it if socket.io features misbehave.

Other notes:
- `str2str_tcp.service` is enabled explicitly in the `Dockerfile` (`systemctl enable
  str2str_tcp.service`) since `install.sh --unit-files` only enables `rtkbase_web` and the
  archive timer by default. Other optional services (NTRIP casters, RTCM server...) stay
  disabled until toggled from the web UI or `settings.conf`.
- gpsd/chrony/avahi are intentionally not installed; add them back manually (`install.sh
  --gpsd-chrony`, `--zeroconf`) inside a running container if you need them.
- Still untested: pointing `settings.conf` at a real/simulated GNSS source (serial device or
  `ext_tcp_source`) to confirm `str2str_tcp` actually starts successfully end-to-end.

## 7. Sources consulted

- Upstream README: https://github.com/Stefal/rtkbase
- Full install script: https://raw.githubusercontent.com/Stefal/rtkbase/master/tools/install.sh
- `web_app/server.py` (entry point, gunicorn binding, pystemd usage, diagnostic route):
  https://raw.githubusercontent.com/Stefal/rtkbase/master/web_app/server.py
- `unit/str2str_tcp.service`, `unit/rtkbase_web.service`:
  https://raw.githubusercontent.com/Stefal/rtkbase/master/unit/
- `run_cast.sh`, `settings.conf.default` (web port, str2str invocation):
  https://raw.githubusercontent.com/Stefal/rtkbase/master/
- `web_app/requirements.txt` (confirms `pystemd`, `gunicorn`, `gevent`, Flask stack):
  https://raw.githubusercontent.com/Stefal/rtkbase/master/web_app/requirements.txt
