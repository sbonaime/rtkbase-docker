#!/bin/bash
# Bind RTKBase's persistent state (settings + data + logs) to /persist, which is
# the only path expected to be mounted as a volume, then hand off to systemd (PID 1).
set -e

RTKBASE_USER="${RTKBASE_USER:-basegnss}"
RTKBASE_DIR="/home/${RTKBASE_USER}/rtkbase"
PERSIST_DIR="/persist"

mkdir -p "${PERSIST_DIR}/data" "${PERSIST_DIR}/logs"

# Seed settings.conf on first run only; later runs/rebuilds reuse the persisted copy.
if [[ ! -f "${PERSIST_DIR}/settings.conf" ]]; then
    cp "${RTKBASE_DIR}/settings.conf.default" "${PERSIST_DIR}/settings.conf"
fi

rm -rf "${RTKBASE_DIR}/data" "${RTKBASE_DIR}/logs" "${RTKBASE_DIR}/settings.conf"
ln -s "${PERSIST_DIR}/data" "${RTKBASE_DIR}/data"
ln -s "${PERSIST_DIR}/logs" "${RTKBASE_DIR}/logs"
ln -s "${PERSIST_DIR}/settings.conf" "${RTKBASE_DIR}/settings.conf"

chown -R "${RTKBASE_USER}:${RTKBASE_USER}" "${PERSIST_DIR}"

exec /sbin/init
