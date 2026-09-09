#!/usr/bin/env bash
##############################################################################
# ha-mail :: /usr/local/bin/hamail-dns-failover.sh
#
# OPTIONAL. Only runs if LINODE_API_TOKEN is set in the environment file.
#
# WHAT FAILOVER LOOKS LIKE WITHOUT THIS SCRIPT (the default, and it is fine)
# -------------------------------------------------------------------------
#   INBOUND MAIL      Two equal-priority MX records. If one node is down the
#                     sending MTA retries the other within seconds. This is
#                     built into SMTP and needs nothing from us. It is the
#                     most reliable failover mechanism in the whole stack.
#
#   IMAP / SUBMISSION ${MAIL_HOST} has two A records. A client that cannot
#                     connect to the first address tries the second - every
#                     mainstream MUA and OS resolver does this. Recovery is a
#                     connection timeout, typically 5-20 seconds.
#
#   WEBMAIL           Same dual-A behaviour. Browsers do "Happy Eyeballs"
#                     style retries, so a dead node is usually invisible.
#
#   ADMIN PORTAL      Single A record, pointed at the write leader. This is
#                     the one thing that genuinely needs a DNS change, and it
#                     is deliberately manual-by-default (see docs/AUDIT.md
#                     section 5).
#
# WHAT THIS SCRIPT ADDS
# It withdraws a dead node's A records so users stop hitting a timeout on
# every other connection attempt, and moves ${ADMIN_HOST} to the survivor.
#
# WHY IT IS NOT AUTOMATIC BY DEFAULT
# A node that is unreachable FROM HERE is not necessarily down. If the tunnel
# breaks but both nodes remain reachable from the internet, both will conclude
# the other is dead and both will try to withdraw the other's records. Run
# with --auto only if you have a third-party health check; otherwise call it
# by hand, or with --from-monitor <verdict> from an external monitor.
#
# Usage:
#   hamail-dns-failover.sh --status
#   hamail-dns-failover.sh --promote-self       # take over admin + full service
#   hamail-dns-failover.sh --restore            # publish both nodes again
##############################################################################

set -Eeuo pipefail

LINODE_API_TOKEN="${LINODE_API_TOKEN}"
LINODE_DOMAIN_ID="${LINODE_DOMAIN_ID}"
DOMAIN="${DOMAIN}"
MAIL_HOST="${MAIL_HOST}"
WEBMAIL_HOST="${WEBMAIL_HOST}"
ADMIN_HOST="${ADMIN_HOST}"
SELF_IP="${SELF_IP}"
PEER_IP="${PEER_IP}"
SELF_HOSTNAME="${SELF_HOSTNAME}"
PEER_HOSTNAME="${PEER_HOSTNAME}"
PEER_WG_IP="${PEER_WG_IP}"
DNS_TTL="${DNS_TTL}"
STATE_DIR="${STATE_DIR}"
LOG_DIR="${LOG_DIR}"

API="https://api.linode.com/v4"
LOG="$LOG_DIR/failover.log"
mkdir -p "$LOG_DIR" "$STATE_DIR"
log() { printf '%s [dns-failover] %s\n' "$(date -Is)" "$*" | tee -a "$LOG" >&2; }

if [[ -z "$LINODE_API_TOKEN" || -z "$LINODE_DOMAIN_ID" ]]; then
    log "LINODE_API_TOKEN / LINODE_DOMAIN_ID are not set - DNS automation is disabled."
    log "Static dual-MX and dual-A failover is still fully in effect; see docs/DNS.md."
    exit 0
fi

api() {
    local method="$1" path="$2" body="${3:-}"
    if [[ -n "$body" ]]; then
        curl -sS -X "$method" \
             -H "Authorization: Bearer $LINODE_API_TOKEN" \
             -H "Content-Type: application/json" \
             -d "$body" "$API$path"
    else
        curl -sS -X "$method" \
             -H "Authorization: Bearer $LINODE_API_TOKEN" \
             "$API$path"
    fi
}

records() { api GET "/domains/$LINODE_DOMAIN_ID/records?page_size=500"; }

# name is the record's label relative to the zone, e.g. "mail" for mail.example.com
rel() { printf '%s' "${1%.$DOMAIN}"; }

record_ids_for() {
    local name="$1" target="$2"
    records | jq -r --arg n "$(rel "$name")" --arg t "$target" \
        '.data[] | select(.type=="A" and .name==$n and .target==$t) | .id'
}

peer_is_reachable() {
    # Two independent signals. Both must fail before we call the peer dead:
    #   * the tunnel (tells us about the private path)
    #   * public SMTP (tells us whether the INTERNET can still reach it)
    # Requiring both to fail is what prevents a tunnel-only outage from
    # triggering a split-brain DNS fight.
    ping -c 2 -W 3 -q "$PEER_WG_IP" >/dev/null 2>&1 && return 0
    timeout 8 bash -c ">/dev/tcp/$PEER_IP/25" 2>/dev/null && return 0
    return 1
}

cmd_status() {
    printf 'Zone %s (Linode domain %s)\n\n' "$DOMAIN" "$LINODE_DOMAIN_ID"
    records | jq -r '.data[] | select(.type=="A" or .type=="MX") |
        "  \(.type)\t\(if .name == "" then "@" else .name end)\t\(.target)\tttl=\(.ttl_sec)"'
    printf '\nPeer %s: ' "$PEER_HOSTNAME"
    if peer_is_reachable; then printf 'REACHABLE\n'; else printf 'UNREACHABLE\n'; fi
}

cmd_promote_self() {
    log "promoting $SELF_HOSTNAME: withdrawing $PEER_IP, steering $ADMIN_HOST here"

    if peer_is_reachable; then
        log "REFUSING: the peer is still reachable. Withdrawing a live node's records"
        log "          would cut capacity, not restore it. Use --force to override."
        [[ "${FORCE:-0}" == "1" ]] || exit 1
    fi

    local id
    for host in "$MAIL_HOST" "$WEBMAIL_HOST"; do
        while read -r id; do
            [[ -n "$id" ]] || continue
            api DELETE "/domains/$LINODE_DOMAIN_ID/records/$id" >/dev/null
            log "removed A $host -> $PEER_IP (record $id)"
        done < <(record_ids_for "$host" "$PEER_IP")
    done

    # Point the admin portal at this node.
    while read -r id; do
        [[ -n "$id" ]] || continue
        api PUT "/domains/$LINODE_DOMAIN_ID/records/$id" \
            "{\"target\":\"$SELF_IP\",\"ttl_sec\":$DNS_TTL}" >/dev/null
        log "repointed $ADMIN_HOST -> $SELF_IP (record $id)"
    done < <(records | jq -r --arg n "$(rel "$ADMIN_HOST")" \
             '.data[] | select(.type=="A" and .name==$n) | .id')

    printf 'promoted\n' > "$STATE_DIR/failover-state"
    printf '%s\n' "$SELF_HOSTNAME" > "$STATE_DIR/admin-leader"
    log "promotion complete. MX records are UNCHANGED - a dead MX costs a sender one retry, and removing it risks losing mail if the node returns."
}

cmd_restore() {
    log "restoring both nodes to DNS"
    for host in "$MAIL_HOST" "$WEBMAIL_HOST"; do
        if [[ -z "$(record_ids_for "$host" "$PEER_IP")" ]]; then
            api POST "/domains/$LINODE_DOMAIN_ID/records" \
                "{\"type\":\"A\",\"name\":\"$(rel "$host")\",\"target\":\"$PEER_IP\",\"ttl_sec\":$DNS_TTL}" >/dev/null
            log "restored A $host -> $PEER_IP"
        fi
        if [[ -z "$(record_ids_for "$host" "$SELF_IP")" ]]; then
            api POST "/domains/$LINODE_DOMAIN_ID/records" \
                "{\"type\":\"A\",\"name\":\"$(rel "$host")\",\"target\":\"$SELF_IP\",\"ttl_sec\":$DNS_TTL}" >/dev/null
            log "restored A $host -> $SELF_IP"
        fi
    done
    printf 'normal\n' > "$STATE_DIR/failover-state"
    log "restore complete"
}

case "${1:---status}" in
    --status)       cmd_status ;;
    --promote-self) cmd_promote_self ;;
    --force-promote) FORCE=1 cmd_promote_self ;;
    --restore)      cmd_restore ;;
    *) printf 'usage: %s [--status|--promote-self|--force-promote|--restore]\n' "$0" >&2; exit 64 ;;
esac
