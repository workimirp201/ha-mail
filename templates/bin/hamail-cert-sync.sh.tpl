#!/usr/bin/env bash
##############################################################################
# ha-mail :: /usr/local/bin/hamail-cert-sync.sh
# Node ${SELF_ROLE} - ${SELF_HOSTNAME}
#
#        *** ONE-WAY BY CONSTRUCTION: FOLLOWER PULLS, LEADER NEVER PUSHES ***
#
# THE BUG THIS DESIGN ELIMINATES
# The obvious implementation of "keep certificates in sync" is a bidirectional
# rsync on both nodes. It fails like this:
#
#   1. A pushes cert -> B. B's files change.
#   2. B's inotify/timer sees a change and pushes back to A.
#   3. rsync updates A's mtimes.
#   4. A sees a change and pushes to B...
#
# ...and the pair sits in a loop reloading Postfix and Dovecot every few
# seconds until someone notices. If the two nodes ever hold DIFFERENT valid
# certificates (both ran certbot), the loop also flip-flops which one is live,
# so half of all TLS handshakes get the wrong certificate.
#
# THIS SCRIPT CANNOT DO THAT, FOR FOUR INDEPENDENT REASONS:
#
#   1. DIRECTION IS A COMPILE-TIME CONSTANT. IS_CERT_LEADER is baked in at
#      render time from NODE_ROLE. On the leader this script exits
#      immediately. There is no code path in which the leader writes to the
#      follower, or in which the follower writes to the leader.
#
#   2. ONLY THE LEADER RUNS CERTBOT FOR THE SHARED NAMES. The follower has no
#      renewal configuration for ${MAIL_HOST} at all, so it can never generate
#      a competing certificate that would need pushing back.
#
#   3. CONTENT-ADDRESSED CHANGE DETECTION. The trigger to install is a change
#      in the certificate's SERIAL NUMBER, not a file mtime. rsync touching a
#      file, a filesystem restore, or a clock skew cannot make this script
#      believe something changed.
#
#   4. MONOTONICITY CHECK. The incoming certificate must expire LATER than the
#      one currently installed. An older certificate is refused, so even a
#      restored-from-backup export directory cannot roll the follower back.
#
# Run manually with --force to reinstall regardless of the serial check.
##############################################################################

set -Eeuo pipefail

IS_CERT_LEADER="${IS_CERT_LEADER}"
PEER_WG_IP="${PEER_WG_IP}"
PEER_HOSTNAME="${PEER_HOSTNAME}"
MAIL_HOST="${MAIL_HOST}"
CERT_ROOT="${CERT_ROOT}"
STATE_DIR="${STATE_DIR}"
LOG_DIR="${LOG_DIR}"
SSH_PORT="${SSH_PORT}"

LIVE_DIR="$CERT_ROOT/live/$MAIL_HOST"
STAGE_DIR="$STATE_DIR/cert-staging/$MAIL_HOST"
EXPORT_DIR="$STATE_DIR/cert-export/$MAIL_HOST"
LOG="$LOG_DIR/cert.log"
FORCE=0

[[ "${1:-}" == "--force" ]] && FORCE=1

mkdir -p "$LOG_DIR" "$STATE_DIR/cert-staging"
log() { printf '%s [cert-sync] %s\n' "$(date -Is)" "$*" | tee -a "$LOG" >&2; }

# --------------------------------------------------------------------------
# Single instance. Two overlapping runs could interleave file installs.
# --------------------------------------------------------------------------
exec 9>"/run/hamail-cert-sync.lock"
if ! flock -n 9; then
    log "another run is in progress; exiting"
    exit 0
fi

# --------------------------------------------------------------------------
# GUARD 1: the leader has nothing to pull.
# --------------------------------------------------------------------------
# shellcheck disable=SC2050  # baked in at render time from NODE_ROLE - the constant IS the guarantee
if [[ "$IS_CERT_LEADER" == "1" ]]; then
    log "this node is the ACME leader; nothing to pull (by design)"
    # Sanity check only: warn if the export the follower depends on is stale.
    if [[ -f "$EXPORT_DIR/NOTAFTER" ]]; then
        exp="$(cat "$EXPORT_DIR/NOTAFTER")"
        exp_s="$(date -d "$exp" +%s 2>/dev/null || echo 0)"
        now_s="$(date +%s)"
        days=$(( (exp_s - now_s) / 86400 ))
        (( days < 10 )) && log "WARNING: exported certificate expires in ${days}d - is certbot renewing?"
    else
        log "WARNING: no export at $EXPORT_DIR - the follower has nothing to pull"
    fi
    exit 0
fi

# --------------------------------------------------------------------------
# FOLLOWER PATH
# --------------------------------------------------------------------------
log "pulling $MAIL_HOST certificate from leader $PEER_HOSTNAME ($PEER_WG_IP)"

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new
          -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=3
          -p "$SSH_PORT" -i /root/.ssh/id_ed25519_hamail)

# Fail fast on a dead tunnel rather than letting rsync hang for minutes.
if ! timeout 12 ssh "${SSH_OPTS[@]}" "root@$PEER_WG_IP" true 2>/dev/null; then
    log "ERROR: cannot reach leader over the tunnel; leaving current certificate in place"
    exit 1
fi

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

# --archive preserves modes; --checksum ignores mtime entirely, which matters
# because mtime is exactly the signal a naive implementation loops on.
if ! rsync -a --checksum --timeout=60 \
        -e "ssh ${SSH_OPTS[*]}" \
        "root@$PEER_WG_IP:$EXPORT_DIR/" "$STAGE_DIR/" 2>>"$LOG"; then
    log "ERROR: rsync failed; leaving current certificate in place"
    exit 1
fi

# --------------------------------------------------------------------------
# GUARD 2: integrity. A truncated transfer must never reach the live path.
# --------------------------------------------------------------------------
if [[ ! -f "$STAGE_DIR/SHA256SUMS" ]]; then
    log "ERROR: no manifest in the pulled bundle; refusing to install"
    exit 1
fi
if ! ( cd "$STAGE_DIR" && sha256sum -c --quiet SHA256SUMS ); then
    log "ERROR: checksum mismatch in the pulled bundle; refusing to install"
    exit 1
fi

# --------------------------------------------------------------------------
# GUARD 3: the private key must actually match the certificate.
# --------------------------------------------------------------------------
new_mod="$(openssl x509 -noout -modulus -in "$STAGE_DIR/fullchain.pem" | sha256sum)"
key_mod="$(openssl rsa  -noout -modulus -in "$STAGE_DIR/privkey.pem" 2>/dev/null | sha256sum || true)"
if [[ "$key_mod" != "$new_mod" ]]; then
    # ECDSA keys do not answer to `openssl rsa`; try the generic pkey path.
    key_mod="$(openssl pkey -in "$STAGE_DIR/privkey.pem" -pubout 2>/dev/null \
               | openssl pkey -pubin -noout -text 2>/dev/null | sha256sum || true)"
    cert_pub="$(openssl x509 -in "$STAGE_DIR/fullchain.pem" -noout -pubkey 2>/dev/null \
               | openssl pkey -pubin -noout -text 2>/dev/null | sha256sum || true)"
    if [[ -z "$cert_pub" || "$key_mod" != "$cert_pub" ]]; then
        log "ERROR: private key does not match certificate; refusing to install"
        exit 1
    fi
fi

# --------------------------------------------------------------------------
# GUARD 4: content-addressed change detection + monotonicity.
# --------------------------------------------------------------------------
new_serial="$(openssl x509 -in "$STAGE_DIR/fullchain.pem" -noout -serial | cut -d= -f2)"
new_end="$(openssl x509 -in "$STAGE_DIR/fullchain.pem" -noout -enddate | cut -d= -f2)"
new_end_s="$(date -d "$new_end" +%s)"

cur_serial=""
cur_end_s=0
if [[ -f "$LIVE_DIR/fullchain.pem" ]]; then
    cur_serial="$(openssl x509 -in "$LIVE_DIR/fullchain.pem" -noout -serial | cut -d= -f2)"
    cur_end="$(openssl x509 -in "$LIVE_DIR/fullchain.pem" -noout -enddate | cut -d= -f2)"
    cur_end_s="$(date -d "$cur_end" +%s)"
fi

if [[ "$new_serial" == "$cur_serial" && "$FORCE" != "1" ]]; then
    log "already current (serial $cur_serial); no reload"
    exit 0
fi

if (( new_end_s < cur_end_s )) && [[ "$FORCE" != "1" ]]; then
    log "ERROR: pulled certificate expires EARLIER than the installed one"
    log "       installed: $(date -d "@$cur_end_s" -Is)  pulled: $(date -d "@$new_end_s" -Is)"
    log "       refusing to roll back. Re-run with --force if this is deliberate."
    exit 1
fi

# --------------------------------------------------------------------------
# Install atomically.
# --------------------------------------------------------------------------
mkdir -p "$LIVE_DIR"
for f in cert.pem chain.pem fullchain.pem privkey.pem; do
    install -m 0644 "$STAGE_DIR/$f" "$LIVE_DIR/.$f.new"
    mv -f "$LIVE_DIR/.$f.new" "$LIVE_DIR/$f"
done
chmod 0640 "$LIVE_DIR/privkey.pem"
chgrp root "$LIVE_DIR/privkey.pem"

printf '%s\n' "$new_serial" > "$STATE_DIR/cert-serial"
log "installed serial $new_serial (expires $new_end)"

# --------------------------------------------------------------------------
# Reload consumers. reload, never restart.
# --------------------------------------------------------------------------
for unit in postfix dovecot nginx; do
    if systemctl is-active --quiet "$unit"; then
        if systemctl reload "$unit"; then
            log "reloaded $unit"
        else
            log "ERROR: reload failed for $unit"
        fi
    fi
done

log "sync complete"
exit 0
