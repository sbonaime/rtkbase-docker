#!/bin/bash
# Bind RTKBase's persistent state to /data volume
set -e

RTKBASE_USER="${RTKBASE_USER:-basegnss}"
RTKBASE_DIR="/home/${RTKBASE_USER}/rtkbase"
PERSIST_DIR="/data"

# Créer les répertoires nécessaires sur le volume persistant
mkdir -p "${PERSIST_DIR}/data" "${PERSIST_DIR}/logs"

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

# Fixer check_timesync.sh pour Docker (en conteneur, timedatectl ne synchronise pas et boucle indéfiniment)
cat << 'EOF' > "${RTKBASE_DIR}/check_timesync.sh"
#!/bin/bash
while [ "$(date +%Y)" -lt 2024 ]; do
    sleep 2
done
exit 0
EOF
chmod +x "${RTKBASE_DIR}/check_timesync.sh"

# Relâcher ProtectSystem/ProtectHome de systemd qui empêchent l'écriture sur /data
for unit in /etc/systemd/system/str2str_*.service /etc/systemd/system/rtkbase_*.service; do
    if [[ -f "$unit" ]]; then
        sed -i 's/^ProtectSystem=strict/#ProtectSystem=strict/' "$unit"
        sed -i 's/^ProtectHome=read-only/#ProtectHome=read-only/' "$unit"
        sed -i 's|^ReadWritePaths=.*|& /data|' "$unit"
    fi
done

# Donner les permissions sur les liens ET le répertoire persistant
chown -h "${RTKBASE_USER}:${RTKBASE_USER}" "${RTKBASE_DIR}/data" "${RTKBASE_DIR}/logs" "${RTKBASE_DIR}/settings.conf"
chown -R "${RTKBASE_USER}:${RTKBASE_USER}" "${PERSIST_DIR}"
chmod -R 775 "${PERSIST_DIR}"

exec /sbin/init