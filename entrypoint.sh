#!/bin/bash
# Bind RTKBase's persistent state to /data volume
set -e

RTKBASE_USER="${RTKBASE_USER:-basegnss}"
RTKBASE_DIR="/home/${RTKBASE_USER}/rtkbase"
PERSIST_DIR="/data"

# Créer UNIQUEMENT le répertoire parent (NE PAS créer data/ et logs/ ici)
mkdir -p "${PERSIST_DIR}"

# Initialiser settings.conf si premier démarrage
if [[ ! -f "${PERSIST_DIR}/settings.conf" ]]; then
    cp "${RTKBASE_DIR}/settings.conf.default" "${PERSIST_DIR}/settings.conf"
fi

# Nettoyer les anciens dossiers/liens
rm -rf "${RTKBASE_DIR}/data" "${RTKBASE_DIR}/logs" "${RTKBASE_DIR}/settings.conf"

# Créer les liens symboliques vers /data
ln -s "${PERSIST_DIR}/data" "${RTKBASE_DIR}/data"
ln -s "${PERSIST_DIR}/logs" "${RTKBASE_DIR}/logs"
ln -s "${PERSIST_DIR}/settings.conf" "${RTKBASE_DIR}/settings.conf"

# Donner les permissions sur les liens ET le répertoire parent
chown -h "${RTKBASE_USER}:${RTKBASE_USER}" "${RTKBASE_DIR}/data" "${RTKBASE_DIR}/logs" "${RTKBASE_DIR}/settings.conf"
chown -R "${RTKBASE_USER}:${RTKBASE_USER}" "${PERSIST_DIR}"

exec /sbin/init