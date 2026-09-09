#!/usr/bin/env bash
##############################################################################
# ha-mail :: /etc/letsencrypt/renewal-hooks/deploy/hamail-cert-deploy-hook.sh
# Node ${SELF_ROLE} - ${SELF_HOSTNAME}
#
# Certbot runs this after ANY successful issuance or renewal on this node.
# Two jobs:
#   1. Reload every service that holds the certificate open.
#   2. If this node is the ACME LEADER, publish the shared-name certificate
#      into an export directory that the follower pulls from.
#
# It never contacts the peer. Publishing is a local file copy; the follower
# initiates the transfer. That asymmetry is what makes a sync loop impossible
# - see docs/AUDIT.md section 2.
##############################################################################

set -Eeuo pipefail

CERT_ROOT="${CERT_ROOT}"
MAIL_HOST="${MAIL_HOST}"
EXPORT_DIR="${STATE_DIR}/cert-export"
IS_CERT_LEADER="${IS_CERT_LEADER}"
LOG="${LOG_DIR}/cert.log"

mkdir -p "$(dirname "$LOG")"
log() { printf '%s [deploy-hook] %s\n' "$(date -Is)" "$*" >> "$LOG"; }

# RENEWED_LINEAGE is set by certbot to /etc/letsencrypt/live/<name>
LINEAGE="${RENEWED_LINEAGE:-}"
log "invoked for lineage=${LINEAGE:-<none>} domains=${RENEWED_DOMAINS:-<none>}"

# ---------------------------------------------------------------------------
# 1. Publish, but ONLY on the leader and ONLY for the shared lineage.
# ---------------------------------------------------------------------------
# The node's own certificate (for ${SELF_HOSTNAME}) is issued independently on
# each node and must never be exported: pushing it would overwrite the peer's
# certificate for its own hostname with one that does not match its name.
# shellcheck disable=SC2050  # baked in at render time from NODE_ROLE - the constant IS the guarantee
if [[ "$IS_CERT_LEADER" == "1" && "$LINEAGE" == "$CERT_ROOT/live/$MAIL_HOST" ]]; then
    dest="$EXPORT_DIR/$MAIL_HOST"
    tmp="$(mktemp -d "${dest}.XXXXXX")"

    # Dereference the symlinks so the follower receives real files and never
    # has to reconstruct certbot's archive/ layout.
    for f in cert.pem chain.pem fullchain.pem privkey.pem; do
        cp -L "$LINEAGE/$f" "$tmp/$f"
    done

    # A manifest the follower verifies before installing anything. This is the
    # difference between "a truncated transfer broke TLS on the second node"
    # and "the sync refused to install and said why".
    ( cd "$tmp" && sha256sum ./*.pem > SHA256SUMS )

    # Record the certificate's own validity window so the follower can refuse
    # to install something OLDER than what it already has.
    openssl x509 -in "$tmp/fullchain.pem" -noout -enddate \
        | cut -d= -f2 > "$tmp/NOTAFTER"
    openssl x509 -in "$tmp/fullchain.pem" -noout -serial \
        | cut -d= -f2 > "$tmp/SERIAL"

    chmod 0755 "$tmp"
    chmod 0644 "$tmp"/*.pem "$tmp/SHA256SUMS" "$tmp/NOTAFTER" "$tmp/SERIAL"
    chmod 0640 "$tmp/privkey.pem"

    mkdir -p "$EXPORT_DIR"
    rm -rf "$dest.old"
    [[ -d "$dest" ]] && mv "$dest" "$dest.old"
    mv "$tmp" "$dest"
    rm -rf "$dest.old"

    log "published $MAIL_HOST to $dest (serial $(cat "$dest/SERIAL"))"
fi

# ---------------------------------------------------------------------------
# 2. Reload consumers.
# ---------------------------------------------------------------------------
# reload, not restart: an in-flight IMAP session or SMTP transaction must not
# be dropped just because a certificate rotated.
for unit in postfix dovecot nginx; do
    if systemctl is-active --quiet "$unit"; then
        systemctl reload "$unit" && log "reloaded $unit" || log "RELOAD FAILED: $unit"
    fi
done

exit 0
