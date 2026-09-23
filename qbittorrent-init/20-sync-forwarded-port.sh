#!/usr/bin/with-contenv bash
# Retry syncing Gluetun's forwarded port into qBittorrent after both services are up.
# Gluetun may assign the port before the Web UI is ready; this closes that race.

set -e

PORT_FILE="/gluetun-runtime/forwarded_port"
WEBUI="http://127.0.0.1:${WEBUI_PORT:-8080}"
CONF="/config/qBittorrent/qBittorrent.conf"

sync_forwarded_port() {
    local port="$1"
    local api_key

    [ -n "${port}" ] && [ "${port}" != "0" ] || return 1
    [ -f "${CONF}" ] || return 1

    api_key=$(grep -m1 '^WebUI\\APIKey=' "${CONF}" | cut -d= -f2-)
    [ -n "${api_key}" ] || return 1

    curl -sf -X POST "${WEBUI}/api/v2/app/setPreferences" \
        -H "Authorization: Bearer ${api_key}" \
        -H "Referer: ${WEBUI}" \
        -H "Origin: ${WEBUI}" \
        --data-urlencode "json={\"listen_port\":${port},\"random_port\":false,\"upnp\":false}" \
        >/dev/null
}

(
    api_key=""
    for _ in $(seq 1 60); do
        if [ -f "${CONF}" ]; then
            api_key=$(grep -m1 '^WebUI\\APIKey=' "${CONF}" | cut -d= -f2-)
        fi
        [ -n "${api_key}" ] || { sleep 2; continue; }
        curl -sf -H "Authorization: Bearer ${api_key}" \
            -H "Referer: ${WEBUI}" -H "Origin: ${WEBUI}" \
            "${WEBUI}/api/v2/app/version" >/dev/null 2>&1 && break
        sleep 2
    done

    for _ in $(seq 1 120); do
        if [ -f "${PORT_FILE}" ]; then
            port=$(tr -d '[:space:]' < "${PORT_FILE}")
            if sync_forwarded_port "${port}"; then
                echo "Synced qBittorrent listen port to ${port}"
                exit 0
            fi
        fi
        sleep 5
    done

    echo "WARNING: forwarded port not synced to qBittorrent after 10 minutes"
) &
