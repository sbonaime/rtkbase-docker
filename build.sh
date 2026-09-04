#!/usr/bin/env bash
# Build (and load locally) the RTKBase image for a given ref.
# Usage: ./build.sh [ref]
#   ref: a rtkbase git tag/branch/commit (default: latest GitHub release)
#
# Besides loading the image into the local Docker Desktop, this also exports it as a single
# .tar.gz file at the repo root (EXPORT_TAR=0 to skip). Since the image is already built for
# linux/arm64, that file can be copied as-is (scp/USB key/...) to an arm64 Linux device with no
# registry access -- such as a Teltonika RUTC50 -- and loaded there directly with `docker load`.
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-rtkbase}"
EXPORT_TAR="${EXPORT_TAR:-1}"
REF="${1:-}"

if [[ -z "${REF}" ]]; then
    echo "No ref given, looking up the latest RTKBase release on GitHub..."
    REF=$(curl -fsSL https://api.github.com/repos/Stefal/rtkbase/releases/latest \
          | grep -m1 '"tag_name"' | cut -d '"' -f4)
    if [[ -z "${REF}" ]]; then
        echo "Could not determine the latest release, defaulting to 'master'"
        REF="master"
    fi
fi

echo "Building ${IMAGE_NAME} for rtkbase ref: ${REF} (linux/arm64, for Apple Silicon)"

docker buildx build \
    --platform linux/arm64 \
    --build-arg RTKBASE_REF="${REF}" \
    -t "${IMAGE_NAME}:${REF}" \
    -t "${IMAGE_NAME}:latest" \
    --load \
    .

echo "Done. Built images: ${IMAGE_NAME}:${REF} and ${IMAGE_NAME}:latest"

if [[ "${EXPORT_TAR}" == "1" ]]; then
    SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
    EXPORT_FILE="${SCRIPT_DIR}/${IMAGE_NAME}-${REF}.tar.gz"
    echo "Exporting ${IMAGE_NAME}:${REF} to ${EXPORT_FILE} (arm64 image, ready for RUTC50/router transfer)..."
    docker save "${IMAGE_NAME}:${REF}" "${IMAGE_NAME}:latest" | gzip > "${EXPORT_FILE}"
    echo "Done. Size: $(du -h "${EXPORT_FILE}" | cut -f1)"
    echo ""
    echo "To deploy on an arm64 Linux device (e.g. a Teltonika RUTC50) with no registry access:"
    echo "  1. Copy the file there: scp ${EXPORT_FILE} <user>@<router>:/tmp/"
    echo "  2. On the device: docker load -i /tmp/$(basename "${EXPORT_FILE}")"
    echo "  3. Then run it there as usual, e.g.:"
    echo "     RTKBASE_USB_DEVICE=/dev/ttyACM0 docker compose -f docker-compose.yml -f docker-compose.usb.yml up -d"
fi
