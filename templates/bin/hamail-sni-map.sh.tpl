#!/usr/bin/env bash
##############################################################################
# ha-mail :: /usr/local/bin/hamail-sni-map.sh
#
# Rebuilds the per-domain TLS certificate maps for Postfix and Dovecot.
#
# WHY: this cluster is multi-tenant. A user of a second hosted domain will
# often configure their client with mail.<their-domain> rather than
# ${MAIL_HOST}. Without SNI maps the server answers with ${MAIL_HOST}'s
# certificate and the client shows a name-mismatch error - which users read as
# "the mail server is broken".
#
# Run after issuing a certificate for a new domain. Idempotent.
##############################################################################

set -Eeuo pipefail

CERT_ROOT="${CERT_ROOT}"
POSTFIX_MAP=/etc/postfix/vmail_ssl.map
DOVECOT_SNI_DIR=/etc/dovecot/sni.d

mkdir -p "$DOVECOT_SNI_DIR"
: > "$POSTFIX_MAP.new"
rm -f "$DOVECOT_SNI_DIR"/*.conf

shopt -s nullglob
for live in "$CERT_ROOT"/live/*/; do
    name="$(basename "$live")"
    [[ -f "$live/fullchain.pem" ]] || continue

    # Every SAN in the certificate becomes a map entry, so one certificate
    # covering mail.a.tld and mail.b.tld serves both without duplication.
    sans="$(openssl x509 -in "$live/fullchain.pem" -noout -ext subjectAltName 2>/dev/null \
            | tr ',' '\n' | sed -n 's/.*DNS://p' | tr -d ' ')"
    for san in $sans; do
        printf '%s %s/privkey.pem %s/fullchain.pem\n' "$san" "$live" "$live" >> "$POSTFIX_MAP.new"
        cat >> "$DOVECOT_SNI_DIR/10-$name.conf" <<CONF
local_name $san {
  ssl_cert = <$live/fullchain.pem
  ssl_key  = <$live/privkey.pem
}
CONF
    done
done
shopt -u nullglob

mv -f "$POSTFIX_MAP.new" "$POSTFIX_MAP"
postmap -F "hash:$POSTFIX_MAP"

# -F tells postmap the map values are FILE PATHS to be read at lookup time.
# Without it Postfix stores the literal path string and every SNI handshake
# fails with a confusing "cannot load certificate" - the single most common
# mistake when setting up tls_server_sni_maps.

systemctl reload postfix
systemctl reload dovecot
printf 'SNI maps rebuilt: %d entries\n' "$(wc -l < "$POSTFIX_MAP")"
