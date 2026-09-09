#!/usr/bin/env bash
##############################################################################
# ha-mail :: scripts/60-dovecot.sh
# Dovecot: authentication, storage, LMTP, Sieve and dsync replication.
##############################################################################

set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_env "${HAMAIL_ENV_FILE:-${HAMAIL_ROOT}/.env}"
require_root

log "configuring Dovecot"

# ---------------------------------------------------------------------------
# Clear Debian's stock conf.d so that leftover files from the package cannot
# override ours. render() has already saved a .hamail-orig of anything we
# replace, and the package originals remain in /usr/share/dovecot/.
# ---------------------------------------------------------------------------
ensure_dir /etc/dovecot/conf.d 0755 root:root
ensure_dir /etc/dovecot/sni.d  0755 root:root
for f in /etc/dovecot/conf.d/*.conf; do
    [[ -f "${f}" ]] || continue
    base="$(basename "${f}")"
    if [[ ! -f "${HAMAIL_TEMPLATES}/dovecot/conf.d/${base}.tpl" ]]; then
        mv "${f}" "${f}.disabled-by-hamail"
    fi
done

render "${HAMAIL_TEMPLATES}/dovecot/dovecot.conf.tpl" /etc/dovecot/dovecot.conf
for f in "${HAMAIL_TEMPLATES}"/dovecot/conf.d/*.tpl; do
    base="$(basename "${f}" .tpl)"
    render "${f}" "/etc/dovecot/conf.d/${base}"
done

render "${HAMAIL_TEMPLATES}/dovecot/sql/auth-sql.conf.ext.tpl" \
       /etc/dovecot/auth-sql.conf.ext 0644 root:root
render "${HAMAIL_TEMPLATES}/dovecot/sql/dovecot-sql.conf.ext.tpl" \
       /etc/dovecot/dovecot-sql.conf.ext 0640 root:dovecot
render "${HAMAIL_TEMPLATES}/dovecot/sql/dovecot-dict-sql.conf.ext.tpl" \
       /etc/dovecot/dovecot-dict-sql.conf.ext 0640 root:dovecot
ok "configuration written"

# ---------------------------------------------------------------------------
# Diffie-Hellman parameters
# ---------------------------------------------------------------------------
if [[ ! -f /etc/dovecot/dh.pem ]]; then
    if [[ -f "/etc/postfix/dh${DH_BITS}.pem" ]]; then
        cp "/etc/postfix/dh${DH_BITS}.pem" /etc/dovecot/dh.pem
    else
        log "generating ${DH_BITS}-bit DH parameters"
        openssl dhparam -out /etc/dovecot/dh.pem "${DH_BITS}" 2>/dev/null
    fi
    chmod 644 /etc/dovecot/dh.pem
fi

# ---------------------------------------------------------------------------
# Sieve
# ---------------------------------------------------------------------------
ensure_dir /var/lib/dovecot/sieve 0755 root:root
ensure_dir /usr/lib/dovecot/sieve-pipe 0755 root:root

for s in default learn-spam learn-ham; do
    install -m 0644 "${HAMAIL_TEMPLATES}/dovecot/sieve/${s}.sieve" \
        "/var/lib/dovecot/sieve/${s}.sieve"
done

install -m 0755 "${HAMAIL_TEMPLATES}/helpers/hamail-learn-spam.sh" \
    /usr/lib/dovecot/sieve-pipe/hamail-learn-spam.sh
install -m 0755 "${HAMAIL_TEMPLATES}/helpers/hamail-learn-ham.sh" \
    /usr/lib/dovecot/sieve-pipe/hamail-learn-ham.sh
render "${HAMAIL_TEMPLATES}/helpers/hamail-quota-warning.sh.tpl" \
    /usr/local/bin/hamail-quota-warning.sh 0755 root:root

# Compile now rather than on first delivery: a syntax error must surface here,
# not as a bounce at 3am.
for s in /var/lib/dovecot/sieve/*.sieve; do
    sievec "${s}" || die "sieve compilation failed for ${s}"
done
chown -R "${VMAIL_USER}:${VMAIL_GROUP}" /var/lib/dovecot/sieve
ok "sieve scripts installed and compiled"

# ---------------------------------------------------------------------------
# Bootstrap certificate.
# ---------------------------------------------------------------------------
# Dovecot will not start without a certificate, and Certbot has not run yet on
# a first deploy. Drop in a self-signed placeholder so the service comes up;
# 75-certbot.sh replaces it and reloads.
if [[ ! -f "${CERT_LIVE}/fullchain.pem" ]]; then
    warn "no certificate yet - installing a temporary self-signed placeholder"
    ensure_dir "${CERT_LIVE}" 0755 root:root
    openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
        -keyout "${CERT_LIVE}/privkey.pem" \
        -out "${CERT_LIVE}/fullchain.pem" \
        -subj "/CN=${MAIL_HOST}" \
        -addext "subjectAltName=DNS:${MAIL_HOST},DNS:${WEBMAIL_HOST},DNS:${SELF_HOSTNAME}" 2>/dev/null
    cp "${CERT_LIVE}/fullchain.pem" "${CERT_LIVE}/chain.pem"
    cp "${CERT_LIVE}/fullchain.pem" "${CERT_LIVE}/cert.pem"
    chmod 640 "${CERT_LIVE}/privkey.pem"
fi
if [[ ! -f "${CERT_ROOT}/live/${SELF_HOSTNAME}/fullchain.pem" ]]; then
    ensure_dir "${CERT_ROOT}/live/${SELF_HOSTNAME}" 0755 root:root
    openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
        -keyout "${CERT_ROOT}/live/${SELF_HOSTNAME}/privkey.pem" \
        -out "${CERT_ROOT}/live/${SELF_HOSTNAME}/fullchain.pem" \
        -subj "/CN=${SELF_HOSTNAME}" 2>/dev/null
    chmod 640 "${CERT_ROOT}/live/${SELF_HOSTNAME}/privkey.pem"
fi

# ---------------------------------------------------------------------------
# Validate, then start.
# ---------------------------------------------------------------------------
if ! doveconf -n >/dev/null 2>/tmp/doveconf.err; then
    cat /tmp/doveconf.err >&2
    die "Dovecot configuration is invalid"
fi
ok "configuration parses"

systemctl enable --now dovecot
systemctl restart dovecot

wait_for_port 127.0.0.1 143 20 || die "Dovecot is not listening on 143"
wait_for_port 127.0.0.1 993 20 || die "Dovecot is not listening on 993"

# The replication endpoint must be on the TUNNEL address only.
if ss -ltn "sport = :${DOVEADM_PORT}" | grep -q "${SELF_WG_IP}"; then
    ok "doveadm is listening on ${SELF_WG_IP}:${DOVEADM_PORT} (tunnel only)"
else
    warn "doveadm is not listening on ${SELF_WG_IP}:${DOVEADM_PORT}."
    warn "If the tunnel is not up yet this is expected; re-run after 20-wireguard.sh."
fi

# Confirm the replication plugin is actually loaded. A typo in mail_plugins
# leaves everything else working perfectly while nothing ever replicates.
if doveconf -n mail_plugins | grep -q replication; then
    ok "replication plugin is loaded"
else
    die "the replication plugin is NOT loaded - check mail_plugins in 10-mail.conf"
fi

if doveadm replicator status >/dev/null 2>&1; then
    ok "replicator process is responding"
else
    warn "the replicator is not responding yet (normal until the peer is also configured)"
fi

ok "Dovecot running"
