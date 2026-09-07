# Teltonika RUTC50 - RTKBase Setup

Quick field notes for deploying the prebuilt RTKBase image on a Teltonika RUTC50 router
(RutOS). See [RTKBASE_DOCKER_RECIPE.md](RTKBASE_DOCKER_RECIPE.md) sections 2a/3b/4b/4c for the
full background, rationale, and troubleshooting behind each step below.

## 1. Format the USB flash drive

RutOS Docker needs a Linux-native filesystem (ext4) for its image store — FAT32/exFAT doesn't
support the symlinks/permissions Docker's `overlay2` storage driver requires. Format the USB
flash drive as ext4 (⚠️ this erases everything on it):

```bash
mkfs.ext4 -F /dev/sda
```

## 2. Copy the Docker image to the USB flash drive

Assuming the image was already downloaded to the router's `/tmp` folder (see section 4b of the
main recipe for how to build/export it), copy it to the USB flash drive:

```bash
mkdir -p /mnt/sda/docker
cp /tmp/rtkbase-v2.7.0.tar.gz /mnt/sda/docker/
```

## 3. Start the Docker daemon on the USB flash drive

Point Docker's storage at the USB drive instead of the tiny internal flash, and enable the
service:

```bash
rm -f /var/run/docker.pid
uci set dockerd.globals.enabled='1'
uci set dockerd.globals.data_root='/mnt/sda/docker/data'
uci commit dockerd

mkdir -p /mnt/sda/docker/data
mkdir -p /mnt/sda/docker/rtkbase-data
dockerd --data-root=/mnt/sda/docker/data > /mnt/sda/docker/dockerd.log 2>&1 &
```

## 4. Find the GNSS receiver's USB device path (optional — for reference/troubleshooting)

The startup script in step 5 auto-detects this, but it's useful to check manually first:

```bash
ls /dev/ttyUSB*
```

It should show up as something like `/dev/ttyUSB4` (the exact number depends on what else is
plugged in / detection order).

## 5. Load the Docker image and run the container

RutOS has no `docker compose` plugin, so use the [`start-rtkbase-rutc50.sh`](start-rtkbase-rutc50.sh)
script (see section 4c/4d of the main recipe for the plain `docker run` it's built on). Copy it
to the router alongside the image (e.g. also under `/mnt/sda/docker/`), then:

```bash
docker load -i /mnt/sda/docker/rtkbase-v2.7.0.tar.gz

chmod +x /mnt/sda/docker/start-rtkbase-rutc50.sh
/mnt/sda/docker/start-rtkbase-rutc50.sh
```

The script is idempotent: it removes any pre-existing `rtkbase` container first, waits for
`dockerd`/the GNSS USB device to be ready, then (re)creates the container — see section 6 below
for why this matters and how to run it automatically at every boot. It auto-detects the GNSS
receiver's device node (defaults to the first match of `/dev/ttyUSB*`); override with
`GNSS_DEVICE_GLOB=/dev/usb_serial_*` (or another glob) as an environment variable if needed:

```bash
GNSS_DEVICE_GLOB='/dev/usb_serial_*' /mnt/sda/docker/start-rtkbase-rutc50.sh
```

The web UI is then reachable at `http://<router-ip>:8080`, and the GNSS receiver's port should
be configured there as `/dev/ttyGNSS0` (the fixed path the script always maps the detected host
device to — see `RTKBASE_DOCKER_RECIPE.md` section 3a).

## 6. Running the container automatically at every boot

Running `docker run --name rtkbase ...` a second time (after a reboot, or just by re-running the
same command) fails with:

```
docker: Error response from daemon: Conflict. The container name "/rtkbase" is already in use by
container "...". You have to remove (or rename) that container to be able to reuse that name.
```

This happens because `dockerd`'s `data_root` lives on the external USB storage
(`/mnt/sda/docker/data`, see section 3), so the `rtkbase` container's definition **survives
reboots** — it's still there, just stopped, the next time `dockerd` starts. A plain `docker run`
at boot (e.g. from a naive startup script) collides with it. `start-rtkbase-rutc50.sh` avoids
this by always removing any existing `rtkbase` container first (`docker rm -f`) before
recreating it — so it's safe to run at every boot, or manually re-run at any time (e.g. after
changing which USB port the GNSS receiver is plugged into).

To run it automatically at boot, add it as a **RutOS startup script**: in the router's web UI,
go to **System → Custom scripts**, and add the following in the "Startup script" section (runs
near the end of the boot process, after storage is mounted):

```bash
/mnt/sda/docker/start-rtkbase-rutc50.sh > /mnt/sda/docker/start-rtkbase.log 2>&1 &
```

Run it in the background (trailing `&`) so it doesn't block the rest of the router's boot
sequence while it waits for `dockerd`/the USB device to be ready. Check
`/mnt/sda/docker/start-rtkbase.log` after a reboot to confirm it started successfully.

