#!/bin/sh
# Idempotent (re)start script for the RTKBase container on a Teltonika RUTC50 (RutOS).
# Safe to run manually, or automatically at every boot (see Teltonika-rtkbase.md section 6) --
# it always removes any pre-existing "rtkbase" container first, so it never fails with
# "Conflict. The container name ... is already in use", which happens because dockerd's
# data-root lives on external storage (/mnt/sda) and container definitions survive reboots.
#
# Configurable via environment variables (all have sane defaults for a typical RUTC50 setup):
#   IMAGE               Docker image to run (default: rtkbase:latest)
#   CONTAINER_NAME       Container name (default: rtkbase)
#   DOCKER_DATA_ROOT     dockerd --data-root (default: /mnt/sda/docker/data)
#   PERSIST_DIR          Host path mounted at /persist (default: /mnt/sda/docker/rtkbase-data)
#   WEB_PORT             Host port for the web UI (default: 8080)
#   GNSS_DEVICE_GLOB     Shell glob to find the GNSS receiver's device node
#                        (default: /dev/ttyUSB*; e.g. /dev/usb_serial_* on some RutOS setups)
#   WAIT_TIMEOUT         Seconds to wait for dockerd/the USB device at boot (default: 60)

set -eu

IMAGE="${IMAGE:-rtkbase:latest}"
CONTAINER_NAME="${CONTAINER_NAME:-rtkbase}"
DOCKER_DATA_ROOT="${DOCKER_DATA_ROOT:-/mnt/sda/docker/data}"
PERSIST_DIR="${PERSIST_DIR:-/mnt/sda/docker/rtkbase-data}"
WEB_PORT="${WEB_PORT:-8080}"

WAIT_TIMEOUT="${WAIT_TIMEOUT:-60}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# 1. Make sure the Docker daemon is up -- right after a reboot it may not have started yet
#    (or its init script may be disabled/broken, see RTKBASE_DOCKER_RECIPE.md section 3b).
if [ ! -S /var/run/docker.sock ]; then
    log "dockerd not running yet, starting it (data-root=${DOCKER_DATA_ROOT})..."
    mkdir -p "${DOCKER_DATA_ROOT}"
    dockerd --data-root="${DOCKER_DATA_ROOT}" > /mnt/sda/docker/dockerd.log 2>&1 &
fi

waited=0
while [ ! -S /var/run/docker.sock ]; do
    if [ "${waited}" -ge "${WAIT_TIMEOUT}" ]; then
        log "ERROR: dockerd did not come up after ${WAIT_TIMEOUT}s, aborting."
        exit 1
    fi
    sleep 1
    waited=$((waited + 1))
done
log "dockerd is up."

# 2. Wait for the GNSS receiver's USB device node to appear (USB enumeration can take a few
#    seconds after boot, especially if the receiver shares a hub with other devices).
waited=0
GNSS_DEVICE=""
while [ -z "${GNSS_DEVICE}" ]; do
    GNSS_DEVICE="$(ls -l /dev/usb_serial_* | awk 'NR==1 {print $NF}')"
    [ -n "${GNSS_DEVICE}" ] && break
    if [ "${waited}" -ge "${WAIT_TIMEOUT}" ]; then
        log "ERROR: no device matching '${GNSS_DEVICE_GLOB}' after ${WAIT_TIMEOUT}s, aborting."
        exit 1
    fi
    sleep 1
    waited=$((waited + 1))
done
log "Using GNSS device: ${GNSS_DEVICE}"

# 3. Remove any pre-existing container of the same name (running or stopped). This is what
#    makes the script safe to (re)run at every boot, or after changing the USB port, instead
#    of failing with "Conflict. The container name ... is already in use".
if docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    log "Removing pre-existing '${CONTAINER_NAME}' container..."
    docker rm -f "${CONTAINER_NAME}"
fi

# 4. (Re)create it. The GNSS device is always mapped to the fixed /dev/ttyGNSS0 path inside
#    the container (see RTKBASE_DOCKER_RECIPE.md section 3a/4c), so settings.conf/the web UI's
#    GNSS port configuration never has to change even if GNSS_DEVICE resolves to a different
#    host path next time (different USB port, re-enumeration order, ...).
#mkdir -p "${PERSIST_DIR}"
mkdir -p "${PERSIST_DIR}"
log "Starting '${CONTAINER_NAME}' (${GNSS_DEVICE} -> :/dev/ttyUSB0)..."
echo "CONTAINER_NAME ${CONTAINER_NAME}"
echo "PERSIST_DIR ${PERSIST_DIR}"
echo "GNSS_DEVICE ${GNSS_DEVICE}"
echo "IMAGE ${IMAGE}"



docker run -d --name "${CONTAINER_NAME}" \
    --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock \
    -p "${WEB_PORT}:80" \
    -v "${PERSIST_DIR}:/data" \
    --device="${GNSS_DEVICE}:/dev/ttyGNSS0" \
    --restart unless-stopped \
    "${IMAGE}"

log "Done. Web UI: http://<router-ip>:${WEB_PORT}"
