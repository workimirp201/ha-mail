#!/usr/bin/env bash
##############################################################################
# ha-mail :: scripts/20-wireguard.sh
# The private inter-node tunnel that MariaDB replication, Dovecot dsync and
# the certificate sync all ride on.
#
# FIRST RUN: generates this node's keys, prints the public key, and stops if
# WG_PEER_PUBKEY is not yet set. Run it on both nodes, exchange the two public
# keys into each .env, then run it again on both.
##############################################################################

set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_env "${HAMAIL_ENV_FILE:-${HAMAIL_ROOT}/.env}"
require_root

KEYDIR=/etc/wireguard/keys
ensure_dir /etc/wireguard 0700 root:root
ensure_dir "${KEYDIR}" 0700 root:root

# ---------------------------------------------------------------------------
# Keys
# ---------------------------------------------------------------------------
if [[ ! -f "${KEYDIR}/private.key" ]]; then
    umask 077
    wg genkey > "${KEYDIR}/private.key"
    wg pubkey < "${KEYDIR}/private.key" > "${KEYDIR}/public.key"
    chmod 600 "${KEYDIR}/private.key"
    chmod 644 "${KEYDIR}/public.key"
    ok "generated WireGuard keypair"
fi

WG_PRIVKEY="$(cat "${KEYDIR}/private.key")"
WG_PUBKEY="$(cat "${KEYDIR}/public.key")"
export WG_PRIVKEY

if [[ -z "${WG_PEER_PUBKEY}" ]]; then
    cat >&2 <<NOTE

  ---------------------------------------------------------------------------
  This node's WireGuard public key:

      ${WG_PUBKEY}

  Put it into the OTHER node's .env as:

      WG_PEER_PUBKEY=${WG_PUBKEY}

  ...and put that node's key into this one's .env. Then re-run this script on
  both. The tunnel cannot be built until both sides know each other.
  ---------------------------------------------------------------------------

NOTE
    die "WG_PEER_PUBKEY is not set in ${HAMAIL_ENV_FILE}"
fi

if [[ "${WG_PEER_PUBKEY}" == "${WG_PUBKEY}" ]]; then
    die "WG_PEER_PUBKEY equals THIS node's own public key. You have copied the wrong key - a peer cannot be itself."
fi

# ---------------------------------------------------------------------------
# Interface
# ---------------------------------------------------------------------------
render "${HAMAIL_TEMPLATES}/wireguard/wg0.conf.tpl" \
       "/etc/wireguard/${WG_INTERFACE}.conf" 0600 root:root

systemctl enable "wg-quick@${WG_INTERFACE}" >/dev/null 2>&1 || true

# `wg syncconf` applies changes without dropping the interface, which matters
# on a redeploy: a full restart would bounce replication and dsync for no
# reason. Fall back to a restart when the interface does not exist yet.
if ip link show "${WG_INTERFACE}" >/dev/null 2>&1; then
    wg syncconf "${WG_INTERFACE}" <(wg-quick strip "${WG_INTERFACE}")
    ok "applied configuration to the running ${WG_INTERFACE}"
else
    systemctl restart "wg-quick@${WG_INTERFACE}"
    ok "brought up ${WG_INTERFACE}"
fi

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
log "waiting for a handshake with ${PEER_HOSTNAME} (${PEER_WG_IP})..."
for i in $(seq 1 30); do
    if ping -c 1 -W 2 -q "${PEER_WG_IP}" >/dev/null 2>&1; then
        rtt="$(ping -c 5 -W 3 -q "${PEER_WG_IP}" | awk -F'/' '/^rtt|^round-trip/ {print $5}')"
        ok "tunnel is up; RTT to ${PEER_HOSTNAME} is ${rtt} ms"
        printf '%s\n' "${rtt}" > "${STATE_DIR}/peer-rtt"

        # The measured RTT is the number every latency decision in this
        # blueprint is justified against. Record it and say so.
        if (( $(printf '%.0f' "${rtt}") > 250 )); then
            warn "RTT is ${rtt} ms - higher than the ~180 ms this configuration is tuned for."
            warn "Consider raising REPL_SYNC_TIMEOUT and lowering REPL_MAX_CONNS."
        fi
        break
    fi
    sleep 2
    (( i == 30 )) && {
        warn "no handshake after 60s. Check, on BOTH nodes:"
        warn "  * UFW allows ${WG_PORT}/udp from the peer's public IP"
        warn "  * WG_PEER_PUBKEY really is the OTHER node's key"
        warn "  * the Endpoint address is the peer's PUBLIC IP, not its tunnel IP"
        warn "  wg show ${WG_INTERFACE}"
    }
done

wg show "${WG_INTERFACE}" || true
