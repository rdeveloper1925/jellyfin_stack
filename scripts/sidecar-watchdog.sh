#!/usr/bin/env bash
# If Gluetun is up but VPN sidecars failed to join its namespace (typical after a
# Docker daemon restart), run compose up -d. Log-only when 8080/9696/8191 listen.
# Does not restart healthy containers and does not recreate on port-forward failure.

set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-/etc/dokploy/compose/plex-stack-yfy5op/code/docker-compose.yml}"
COMPOSE_DIR="$(dirname "${COMPOSE_FILE}")"
GLUETUN_CONTAINER="${GLUETUN_CONTAINER:-plex-stack-yfy5op-gluetun-1}"
QBITTORRENT_CONTAINER="${QBITTORRENT_CONTAINER:-plex-stack-yfy5op-qbittorrent-1}"
PROWLARR_CONTAINER="${PROWLARR_CONTAINER:-plex-stack-yfy5op-prowlarr-1}"
FLARESOLVERR_CONTAINER="${FLARESOLVERR_CONTAINER:-plex-stack-yfy5op-flaresolverr-1}"
INIT_DIR="${INIT_DIR:-${COMPOSE_DIR}/qbittorrent-init}"
LOG_TAG="jellyfin-sidecar-watchdog"

log() {
    logger -t "${LOG_TAG}" -- "$*" || true
    echo "$(date -Iseconds) $*"
}

container_running() {
    docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -qx true
}

port_listening() {
    local port="$1"
    docker exec "${GLUETUN_CONTAINER}" sh -c "nc -z 127.0.0.1 ${port} || nc -z ::1 ${port}" >/dev/null 2>&1
}

fix_init_ownership() {
    if [ ! -d "${INIT_DIR}" ] || [ "$(id -u)" -ne 0 ]; then
        return 0
    fi
    chown -R root:root "${INIT_DIR}"
    chmod 750 "${INIT_DIR}"
    # linuxserver runs these as executables; 640 skips them ("is not an executable file").
    find "${INIT_DIR}" -type f -exec chmod 750 {} +
}

fix_init_ownership

if ! container_running "${GLUETUN_CONTAINER}"; then
    log "Gluetun ${GLUETUN_CONTAINER} is not running; log-only"
    exit 0
fi

missing=()
if ! container_running "${QBITTORRENT_CONTAINER}"; then
    missing+=("qbittorrent-exited")
fi
if ! container_running "${PROWLARR_CONTAINER}"; then
    missing+=("prowlarr-exited")
fi
if ! container_running "${FLARESOLVERR_CONTAINER}"; then
    missing+=("flaresolverr-exited")
fi
if ! port_listening 8080; then
    missing+=("8080")
fi
if ! port_listening 9696; then
    missing+=("9696")
fi
if ! port_listening 8191; then
    missing+=("8191")
fi

if [ "${#missing[@]}" -eq 0 ]; then
    log "Sidecars healthy (8080/9696/8191 listening); log-only"
    exit 0
fi

log "Sidecars down (${missing[*]}); running docker compose up -d"
docker compose --project-directory "${COMPOSE_DIR}" -f "${COMPOSE_FILE}" up -d
log "compose up -d finished"
