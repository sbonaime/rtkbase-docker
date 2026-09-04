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

## 4. Find the GNSS receiver's USB device path

```bash
ls /dev/ttyUSB*
```

It should show up as something like `/dev/ttyUSB4` (the exact number depends on what else is
plugged in / detection order).

## 5. Load the Docker image and run the container

RutOS has no `docker compose` plugin, so use a plain `docker run` (see section 4c of the main
recipe):

```bash
docker load -i /mnt/sda/docker/rtkbase-v2.7.0.tar.gz

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

Replace `/dev/ttyUSB4` with the actual path found in step 4. The web UI is then reachable at
`http://<router-ip>:8080`.
