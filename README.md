# RTKBase Docker

A Docker recipe for [RTKBase](https://github.com/Stefal/rtkbase) — a GNSS base station web
frontend for RTKLIB — that isn't officially containerized upstream. Builds a `linux/arm64`
image (Apple Silicon / arm64 Linux SBCs and routers) with a multi-stage `Dockerfile` to keep the
final image small (~460MB), runs it with systemd as PID 1 so RTKBase's own service management
(`pystemd`/`systemctl`) keeps working unmodified, and supports passing a physical USB/serial
GNSS receiver through to the container.

## Quick start (macOS / Apple Silicon)

```bash
./build.sh                 # builds rtkbase:latest for the latest RTKBase release
docker compose up -d
open http://localhost:8080
```

## Passing a physical USB/serial GNSS receiver through (Linux host)

```bash
RTKBASE_USB_DEVICE=/dev/ttyACM0 docker compose -f docker-compose.yml -f docker-compose.usb.yml up -d
```

## Deploying on an ARM router/SBC (e.g. Teltonika RUTC50), with no registry access

```bash
./build.sh v2.7.0                       # also exports ./rtkbase-<ref>.tar.gz
scp rtkbase-v2.7.0.tar.gz root@<device-ip>:/tmp/
# then on the device:
docker load -i /tmp/rtkbase-v2.7.0.tar.gz
```

See [Teltonika-rtkbase.md](Teltonika-rtkbase.md) for the full field-tested steps specific to a
Teltonika RUTC50 (RutOS), including formatting external storage and running the container with
plain `docker run` since RutOS ships no `docker compose`.

## Documentation

**[RTKBASE_DOCKER_RECIPE.md](RTKBASE_DOCKER_RECIPE.md)** is the full recipe: how RTKBase works
and why this image runs systemd as PID 1, the multi-stage build that keeps the image small,
macOS/Apple Silicon limitations, USB passthrough, ARM router/SBC considerations, build/usage
examples, and validation status.

## Files in this repo

- [`Dockerfile`](Dockerfile) — multi-stage build of the image from a chosen RTKBase git ref.
- [`entrypoint.sh`](entrypoint.sh) — wires up persistent state, then starts systemd.
- [`docker-compose.yml`](docker-compose.yml) — run configuration (privileged mode, volumes, port).
- [`docker-compose.usb.yml`](docker-compose.usb.yml) — optional overlay to pass a physical
  USB/serial GNSS receiver through to the container.
- [`build.sh`](build.sh) — builds/tags an image for a given ref (defaults to the latest release),
  and exports it as `rtkbase-<ref>.tar.gz` for offline transfer to devices with no registry access.
- [`Teltonika-rtkbase.md`](Teltonika-rtkbase.md) — field notes for deploying on a Teltonika
  RUTC50 router.

## Disclaimer

RTKBase itself is not designed to run in a container and has no official Docker support; this
recipe reproduces its installer (`tools/install.sh`) inside an image. See
[RTKBASE_DOCKER_RECIPE.md](RTKBASE_DOCKER_RECIPE.md) for known limitations (e.g. macOS/Docker
Desktop has no direct USB passthrough).
