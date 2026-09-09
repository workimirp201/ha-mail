#!/usr/bin/env bash
##############################################################################
# ha-mail :: /usr/local/bin/hamail-health.sh
# Node ${SELF_ROLE} - ${SELF_HOSTNAME}
#
# Whole-node health. Run it by hand after any change, and every 15 minutes
# from hamail-health.timer.
#
#   hamail-health.sh            human-readable report
#   hamail-health.sh --quiet    only print problems (for the timer)
#   hamail-health.sh --json     machine-readable, for external monitoring
#
# Exit codes:  0 = healthy   1 = degraded   2 = failed
##############################################################################

set -Eeuo pipefail

DOMAIN="${DOMAIN}"
MAIL_HOST="${MAIL_HOST}"
WEBMAIL_HOST="${WEBMAIL_HOST}"
ADMIN_HOST="${ADMIN_HOST}"
SELF_ROLE="${SELF_ROLE}"
SELF_IP="${SELF_IP}"
SELF_HOSTNAME="${SELF_HOSTNAME}"
PEER_IP="${PEER_IP}"
PEER_WG_IP="${PEER_WG_IP}"
PEER_HOSTNAME="${PEER_HOSTNAME}"
CERT_LIVE="${CERT_LIVE}"
CERT_ROOT="${CERT_ROOT}"
VMAIL_ROOT="${VMAIL_ROOT}"
DOVEADM_PORT="${DOVEADM_PORT}"
SELF_DKIM_SELECTOR="${SELF_DKIM_SELECTOR}"
DKIM_PATH="${DKIM_PATH}"
STATE_DIR="${STATE_DIR}"

QUIET=0; JSON=0
for a in "$@"; do
    case "$a" in
        --quiet) QUIET=1 ;;
        --json)  JSON=1; QUIET=1 ;;
    esac
done

OK=(); WARN=(); ERR=()
pass() { OK+=("$1");   (( QUIET )) || printf '  [ ok ] %s\n' "$1"; }
warn() { WARN+=("$1"); printf '  [warn] %s\n' "$1" >&2; }
fail() { ERR+=("$1");  printf '  [FAIL] %s\n' "$1" >&2; }

(( QUIET )) || printf '\n=== ha-mail health :: node %s (%s) ===\n\n' "$SELF_ROLE" "$SELF_HOSTNAME"

# --------------------------------------------------------------------------
# Services
# --------------------------------------------------------------------------
(( QUIET )) || printf 'Services\n'
for unit in mariadb postfix dovecot nginx rspamd redis-server php8.3-fpm fail2ban "wg-quick@wg0"; do
    if systemctl is-active --quiet "$unit"; then
        pass "$unit is running"
    else
        fail "$unit is NOT running"
    fi
done

# --------------------------------------------------------------------------
# Listening ports
# --------------------------------------------------------------------------
(( QUIET )) || printf '\nListeners\n'
check_port() {
    local host="$1" port="$2" label="$3"
    if timeout 4 bash -c ">/dev/tcp/$host/$port" 2>/dev/null; then
        pass "$label ($host:$port)"
    else
        fail "$label is not listening ($host:$port)"
    fi
}
check_port 127.0.0.1 25   "SMTP"
check_port 127.0.0.1 587  "submission"
check_port 127.0.0.1 465  "smtps"
check_port 127.0.0.1 143  "IMAP"
check_port 127.0.0.1 993  "IMAPS"
check_port 127.0.0.1 4190 "ManageSieve"
check_port 127.0.0.1 443  "HTTPS"
check_port 127.0.0.1 11332 "rspamd milter"

# The replication endpoints must be on the TUNNEL address and nowhere else.
if timeout 4 bash -c ">/dev/tcp/$SELF_IP/$DOVEADM_PORT" 2>/dev/null; then
    fail "SECURITY: doveadm ($DOVEADM_PORT) is reachable on the PUBLIC address $SELF_IP - it must bind the tunnel only"
else
    pass "doveadm is not exposed on the public address"
fi
if timeout 4 bash -c ">/dev/tcp/$SELF_IP/3306" 2>/dev/null; then
    fail "SECURITY: MariaDB (3306) is reachable on the PUBLIC address $SELF_IP - it must bind the tunnel only"
else
    pass "MariaDB is not exposed on the public address"
fi

# --------------------------------------------------------------------------
# Peer reachability
# --------------------------------------------------------------------------
(( QUIET )) || printf '\nPeer\n'
if ping -c 2 -W 3 -q "$PEER_WG_IP" >/dev/null 2>&1; then
    rtt="$(ping -c 3 -W 3 -q "$PEER_WG_IP" 2>/dev/null | awk -F'/' '/^rtt|^round-trip/ {print $5}')"
    pass "tunnel to $PEER_HOSTNAME is up (avg ${rtt:-?} ms)"
    check_port "$PEER_WG_IP" 3306 "peer MariaDB"
    check_port "$PEER_WG_IP" "$DOVEADM_PORT" "peer doveadm"
else
    fail "tunnel to $PEER_HOSTNAME ($PEER_WG_IP) is DOWN - replication is stalled"
fi

# --------------------------------------------------------------------------
# Certificates
# --------------------------------------------------------------------------
(( QUIET )) || printf '\nCertificates\n'
check_cert() {
    local path="$1" label="$2"
    if [[ ! -f "$path" ]]; then
        fail "$label: missing ($path)"
        return
    fi
    local end end_s days
    end="$(openssl x509 -in "$path" -noout -enddate | cut -d= -f2)"
    end_s="$(date -d "$end" +%s)"
    days=$(( (end_s - $(date +%s)) / 86400 ))
    if   (( days < 0 ));  then fail "$label: EXPIRED ${days#-} days ago"
    elif (( days < 10 )); then fail "$label: expires in ${days}d - renewal is not working"
    elif (( days < 21 )); then warn "$label: expires in ${days}d"
    else                       pass "$label: valid for ${days}d"
    fi
}
check_cert "$CERT_LIVE/fullchain.pem" "shared cert ($MAIL_HOST)"
check_cert "$CERT_ROOT/live/$SELF_HOSTNAME/fullchain.pem" "node cert ($SELF_HOSTNAME)"

# The private key must match the certificate. A mismatched pair after a
# botched sync makes every TLS handshake fail while every file still exists.
if [[ -f "$CERT_LIVE/fullchain.pem" && -f "$CERT_LIVE/privkey.pem" ]]; then
    c="$(openssl x509 -in "$CERT_LIVE/fullchain.pem" -noout -pubkey 2>/dev/null | sha256sum)"
    k="$(openssl pkey -in "$CERT_LIVE/privkey.pem" -pubout 2>/dev/null | sha256sum)"
    if [[ "$c" == "$k" ]]; then
        pass "shared cert and private key match"
    else
        fail "shared cert and private key DO NOT MATCH - TLS will fail on every connection"
    fi
fi

# --------------------------------------------------------------------------
# DKIM
# --------------------------------------------------------------------------
(( QUIET )) || printf '\nDKIM\n'
key="$DKIM_PATH/$SELF_DKIM_SELECTOR.$DOMAIN.key"
if [[ -f "$key" ]]; then
    pass "private key present for selector $SELF_DKIM_SELECTOR"
    pub="$(openssl rsa -in "$key" -pubout -outform PEM 2>/dev/null \
           | sed '1d;$d' | tr -d '\n')"
    dns="$(dig +short TXT "$SELF_DKIM_SELECTOR._domainkey.$DOMAIN" 2>/dev/null \
           | tr -d '"' | tr -d ' ' | sed 's/.*p=//')"
    if [[ -z "$dns" ]]; then
        fail "no DKIM TXT record published at $SELF_DKIM_SELECTOR._domainkey.$DOMAIN - outbound mail from THIS node is unverifiable"
    elif [[ "$dns" == "$pub" ]]; then
        pass "published DKIM record matches the local key"
    else
        fail "published DKIM record does NOT match the local key for selector $SELF_DKIM_SELECTOR"
    fi
else
    fail "DKIM private key missing: $key"
fi

# --------------------------------------------------------------------------
# DNS that this architecture depends on
# --------------------------------------------------------------------------
(( QUIET )) || printf '\nDNS\n'
mx="$(dig +short MX "$DOMAIN" 2>/dev/null | awk '{print $2}' | sed 's/\.$//' | sort)"
if grep -q "$SELF_HOSTNAME" <<<"$mx" && grep -q "$PEER_HOSTNAME" <<<"$mx"; then
    pass "both nodes are published as MX for $DOMAIN"
else
    warn "MX records for $DOMAIN do not list both nodes (found: $(tr '\n' ' ' <<<"$mx"))"
fi

a_records="$(dig +short A "$MAIL_HOST" 2>/dev/null | sort)"
if grep -qx "$SELF_IP" <<<"$a_records" && grep -qx "$PEER_IP" <<<"$a_records"; then
    pass "$MAIL_HOST resolves to both nodes"
else
    warn "$MAIL_HOST does not resolve to both nodes (found: $(tr '\n' ' ' <<<"$a_records"))"
fi

# Forward-confirmed reverse DNS. Without it a large fraction of receivers
# defer or reject, and the failure is invisible from this side.
ptr="$(dig +short -x "$SELF_IP" 2>/dev/null | sed 's/\.$//')"
if [[ -z "$ptr" ]]; then
    fail "no PTR record for $SELF_IP - set reverse DNS in the Linode Cloud Manager (see docs/DNS.md)"
elif [[ "$ptr" == "$SELF_HOSTNAME" ]]; then
    fwd="$(dig +short A "$ptr" 2>/dev/null | head -n1)"
    if [[ "$fwd" == "$SELF_IP" ]]; then
        pass "FCrDNS is correct ($SELF_IP <-> $ptr)"
    else
        fail "PTR is $ptr but its A record is $fwd, not $SELF_IP - forward-confirmed reverse DNS is broken"
    fi
else
    fail "PTR for $SELF_IP is '$ptr', expected '$SELF_HOSTNAME'"
fi

spf="$(dig +short TXT "$DOMAIN" 2>/dev/null | tr -d '"' | grep -m1 '^v=spf1' || true)"
if [[ -z "$spf" ]]; then
    fail "no SPF record for $DOMAIN"
elif grep -q "$SELF_IP" <<<"$spf" && grep -q "$PEER_IP" <<<"$spf"; then
    pass "SPF authorises both nodes"
else
    fail "SPF record does not authorise both node IPs: $spf"
fi

dmarc="$(dig +short TXT "_dmarc.$DOMAIN" 2>/dev/null | tr -d '"' | grep -m1 '^v=DMARC1' || true)"
[[ -n "$dmarc" ]] && pass "DMARC published" || warn "no DMARC record for $DOMAIN"

# --------------------------------------------------------------------------
# Mail queue and storage
# --------------------------------------------------------------------------
(( QUIET )) || printf '\nQueue and storage\n'
qlen="$(find /var/spool/postfix/deferred -type f 2>/dev/null | wc -l)"
if   (( qlen > 500 )); then fail "deferred queue is ${qlen} messages"
elif (( qlen > 100 )); then warn "deferred queue is ${qlen} messages"
else                        pass "deferred queue: ${qlen}"
fi

for path in "$VMAIL_ROOT" /var; do
    use="$(df --output=pcent "$path" 2>/dev/null | tail -n1 | tr -dc '0-9')"
    [[ -z "${use:-}" ]] && continue
    if   (( use > 92 )); then fail "$path is ${use}% full"
    elif (( use > 85 )); then warn "$path is ${use}% full"
    else                      pass "$path is ${use}% full"
    fi
done

# --------------------------------------------------------------------------
# Multi-master invariants
# --------------------------------------------------------------------------
(( QUIET )) || printf '\nCluster invariants\n'
inc="$(mariadb --protocol=socket -uroot -N -B -e 'SELECT @@auto_increment_increment' 2>/dev/null || echo '?')"
off="$(mariadb --protocol=socket -uroot -N -B -e 'SELECT @@auto_increment_offset' 2>/dev/null || echo '?')"
if [[ "$inc" == "2" && "$off" == "${SELF_AUTOINC_OFFSET}" ]]; then
    pass "auto_increment increment=$inc offset=$off"
else
    fail "auto_increment increment=$inc offset=$off (expected 2/${SELF_AUTOINC_OFFSET}) - key collisions are possible"
fi

# The destructive-command tripwire. `doveadm backup` is one-way and deletes
# anything on the destination that is not on the source; running it against a
# live peer is a data-loss event. Warn if anyone has typed it here.
if grep -rslE '(^|[[:space:];&|])doveadm[[:space:]]+backup' /root/.bash_history /home/*/.bash_history 2>/dev/null | head -n1 | grep -q .; then
    warn "'doveadm backup' appears in shell history on this node - it is DESTRUCTIVE on a live pair; the safe command is 'doveadm sync'"
fi

if [[ -f "$STATE_DIR/admin-leader" ]]; then
    pass "admin write leader: $(cat "$STATE_DIR/admin-leader")"
fi

# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------
if (( JSON )); then
    printf '{"node":"%s","hostname":"%s","ok":%d,"warn":%d,"error":%d,"problems":[' \
        "$SELF_ROLE" "$SELF_HOSTNAME" "${#OK[@]}" "${#WARN[@]}" "${#ERR[@]}"
    sep=""
    for p in "${ERR[@]}" "${WARN[@]}"; do
        printf '%s"%s"' "$sep" "${p//\"/\\\"}"
        sep=","
    done
    printf ']}\n'
fi

(( QUIET )) || printf '\n%d ok, %d warning(s), %d error(s)\n\n' "${#OK[@]}" "${#WARN[@]}" "${#ERR[@]}"

(( ${#ERR[@]}  > 0 )) && exit 2
(( ${#WARN[@]} > 0 )) && exit 1
exit 0
