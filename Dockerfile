# syntax=docker/dockerfile:1

# Debian bookworm is what upstream RTKBase targets (README: "Debian base distro >= 12").
#
# --- Multi-stage build ---
# RTKBase's installer (tools/install.sh) needs a full build toolchain (gcc, make, python3-dev,
# libxml2-dev, libxslt-dev, libssl-dev, libffi-dev...) to compile RTKLIB and the Python C
# extensions (lxml, pystemd, gevent...) used by the web app, plus git/wget to fetch sources.
# None of that is needed once str2str/rtkrcv/convbin are built and the venv's wheels are
# installed, so it's confined to a throwaway "builder" stage. The final stage only installs
# the runtime packages/shared libs and copies over the build output. Measured result on arm64:
# ~1.4GB -> ~460MB (~67% smaller), which matters on space-constrained devices such as a
# Teltonika RUTC50 router (see section 2a/3b of RTKBASE_DOCKER_RECIPE.md).
FROM debian:bookworm AS builder

# Git ref of https://github.com/Stefal/rtkbase to build: a release tag (vX.Y.Z),
# a branch (master, dev...) or a commit SHA.
ARG RTKBASE_REF=v2.7.0
ARG RTKBASE_USER=basegnss

# Build-only toolchain (compiler, dev headers, git/wget to fetch sources), plus udev/dbus
# since install.sh's own steps below need /etc/udev/rules.d and a polkit install to exist
# (rtkbase_requirements() copies udev rules there; install_polkit_rules.sh apt-get installs
# polkitd itself if missing). Discarded with this whole stage either way.
RUN apt-get update && apt-get install -y --no-install-recommends \
        systemd systemd-sysv udev dbus git wget ca-certificates sudo \
    && rm -rf /var/lib/apt/lists/*

# install.sh refuses to run as a "real" login user detection when there is none
# (docker build has no logname); it must be told explicitly which user to use.
RUN useradd -m -s /bin/bash "${RTKBASE_USER}" \
    && echo "${RTKBASE_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${RTKBASE_USER}"

WORKDIR /home/${RTKBASE_USER}

# Reuse RTKBase's own installer step by step (this is exactly what
# tools/install.sh --all repo --rtkbase-repo <ref> does, split so we can skip
# the steps that don't make sense in a container: gpsd/chrony/PPS time sync,
# avahi/zeroconf discovery, GNSS receiver auto-detection at build time).
RUN wget -q "https://raw.githubusercontent.com/Stefal/rtkbase/${RTKBASE_REF}/tools/install.sh" -O install.sh \
    && chmod +x install.sh \
    && ./install.sh --user "${RTKBASE_USER}" --dependencies \
    && ./install.sh --user "${RTKBASE_USER}" --rtklib \
    && ./install.sh --user "${RTKBASE_USER}" --rtkbase-repo "${RTKBASE_REF}" \
    && ./install.sh --user "${RTKBASE_USER}" --rtkbase-requirements \
    && ./install.sh --user "${RTKBASE_USER}" --unit-files \
    && systemctl enable str2str_tcp.service \
    && rm install.sh \
    # --- Strip build-only weight that would otherwise ship in the final image ---
    # Full .git history of the cloned rtkbase repo (~250-300MB): never read at runtime.
    && rm -rf "/home/${RTKBASE_USER}/rtkbase/.git" \
    # Prebuilt RTKLIB binaries for other SBC architectures (armv6l/armv7l, and an aarch64
    # copy): install.sh only uses these when /sys/firmware/devicetree/base/model matches a
    # short list of Raspberry Pi / Orange Pi models, which a generic container never does
    # (it always compiles from source instead, see install_rtklib() in install.sh), so this
    # directory is always dead weight here. The binary actually used is already installed
    # to /usr/local/bin below.
    && rm -rf "/home/${RTKBASE_USER}/rtkbase/tools/bin" \
    # pip/apt caches left behind by install.sh's own internal `pip install`/`apt-get install`.
    && rm -rf "/home/${RTKBASE_USER}/.cache" /root/.cache /var/lib/apt/lists/*

# --- Final, runtime-only stage ---
FROM debian:bookworm-slim AS final

ARG RTKBASE_USER=basegnss
# Make the build-time user choice available at runtime too (entrypoint.sh reads it).
ENV RTKBASE_USER=${RTKBASE_USER}

# RTKBase manages its own services (str2str, web server...) through systemd units,
# and web_app/server.py controls/reads them at runtime via pystemd (D-Bus) and
# `systemctl`/`journalctl` (see ServiceController.py and the /diagnostic route).
# To keep that behavior working unmodified, systemd runs as PID 1 in this image
# instead of reimplementing a custom process supervisor.
#
# Runtime-only packages: systemd/udev/dbus (service management), sudo, the Python interpreter
# (the venv copied from the builder stage points back at this same system python3), the
# shared libraries the venv's compiled wheels (lxml, pystemd, cryptography-adjacent deps) are
# dynamically linked against, and the small CLI tools RTKBase's web UI/tools scripts shell out
# to (pps-tools, bc, dos2unix, socat, zip/unzip, psmisc, proj-bin, nftables) — everything
# install.sh's install_dependencies()/rtkbase_requirements() installed, minus the build-only
# compiler/dev headers/git/wget/pip that only the builder stage needs. (polkitd is
# deliberately not installed: install.sh's install_polkit_rules.sh never actually manages to
# install/use it on this base image either, see the user/group RUN step below.)
RUN apt-get update && apt-get install -y --no-install-recommends \
        systemd systemd-sysv udev dbus sudo ca-certificates \
        python3 python3-serial \
        pps-tools bc dos2unix socat zip unzip psmisc proj-bin nftables \
        libxml2 libxslt1.1 libssl3 libffi8 \
    && rm -rf /var/lib/apt/lists/* \
    && systemctl mask \
        systemd-udevd.service systemd-udevd-kernel.socket systemd-udevd-control.socket \
        getty.target getty-static.service console-getty.service \
        systemd-timesyncd.service || true

# Recreate the same user/groups install.sh set up in the builder stage (dialout for serial
# port access). Note: install.sh's install_polkit_rules.sh (meant to let rtkbase_web control
# services without root, via a "rtkbase" group + polkit rules) silently no-ops on this base
# image regardless of this refactor (dpkg-query already reports polkitd as "known" so its
# `apt-get install polkitd` guard never fires, confirmed by /etc/polkit-1 also being absent in
# the previous single-stage image) — services already run fine as root here, so nothing to
# reproduce for it.
RUN useradd -m -s /bin/bash "${RTKBASE_USER}" \
    && echo "${RTKBASE_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${RTKBASE_USER}" \
    && usermod -a -G dialout "${RTKBASE_USER}"

WORKDIR /home/${RTKBASE_USER}

# The rtkbase repo checkout + its venv (compiled wheels, str2str/rtkrcv/convbin's Python
# glue) — this is the actual application, everything else above is just its runtime.
COPY --from=builder --chown=${RTKBASE_USER}:${RTKBASE_USER} \
    /home/${RTKBASE_USER}/rtkbase /home/${RTKBASE_USER}/rtkbase
COPY --from=builder /usr/local/bin/str2str /usr/local/bin/rtkrcv /usr/local/bin/convbin /usr/local/bin/
# systemd units (+ the enablement symlinks install.sh's `systemctl enable` created), udev
# rules, and the rtkbase_path entry install.sh adds to /etc/environment.
COPY --from=builder /etc/systemd/system/ /etc/systemd/system/
COPY --from=builder /etc/udev/rules.d/ /etc/udev/rules.d/
COPY --from=builder /etc/environment /etc/environment

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Default RTKBase web port (settings.conf -> [general] web_port).
EXPOSE 80

# Everything that must survive an image rebuild (settings.conf, raw gnss data, logs).
VOLUME ["/persist"]

ENTRYPOINT ["/entrypoint.sh"]
