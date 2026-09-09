#!/usr/bin/env bash
##############################################################################
# ha-mail :: scripts/75-certbot.sh
#
# TLS certificates.
#
#   SHARED NAMES (${MAIL_HOST}, ${WEBMAIL_HOST}, ${ADMIN_HOST}, autoconfig)
#     Issued on the ACME LEADER only (node A). The follower pulls the result
#     with hamail-cert-sync.sh. One issuer, one direction, no loop.
#
#   NODE NAME (${SELF_HOSTNAME})
#     Issued locally on EVERY node. It is unique to the node, so there is
#     nothing to share and nothing to synchronise.
#
# Prerequisite: nginx must already be serving ${ACME_WEBROOT} on port 80,
# which 80-nginx-php.sh arranges. Run that first.
##############################################################################

set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_env "${HAMAIL_ENV_FILE:-${HAMAIL_ROOT}/.env}"
require_root

ensure_dir "${ACME_WEBROOT}/.well-known/acme-challenge" 0755 www-data:www-data
ensure_dir "${STATE_DIR}/cert-export" 0755 root:root
ensure_dir "${CERT_ROOT}/renewal-hooks/deploy" 0755 root:root

render "${HAMAIL_TEMPLATES}/bin/hamail-cert-deploy-hook.sh.tpl" \
       "${CERT_ROOT}/renewal-hooks/deploy/hamail-cert-deploy-hook.sh" 0755 root:root
render "${HAMAIL_TEMPLATES}/bin/hamail-cert-sync.sh.tpl" \
       /usr/local/bin/hamail-cert-sync.sh 0755 root:root
render "${HAMAIL_TEMPLATES}/bin/hamail-sni-map.sh.tpl" \
       /usr/local/bin/hamail-sni-map.sh 0755 root:root

STAGING=()
if [[ "${ACME_STAGING}" == "1" ]]; then
    STAGING=(--staging)
    warn "using the Let's Encrypt STAGING CA - the resulting certificates are NOT trusted"
fi

# ---------------------------------------------------------------------------
# Prove the webroot is actually reachable before asking a CA to look at it.
# ---------------------------------------------------------------------------
# A failed ACME attempt counts against the rate limit (5 per account per
# hostname per week); an unnecessary failure is expensive.
probe="hamail-probe-$(date +%s)"
printf 'ok\n' > "${ACME_WEBROOT}/.well-known/acme-challenge/${probe}"
for name in "${SELF_HOSTNAME}" "${MAIL_HOST}"; do
    if curl -fsS --max-time 15 "http://${name}/.well-known/acme-challenge/${probe}" 2>/dev/null | grep -q '^ok$'; then
        ok "webroot is reachable at http://${name}/"
    else
        warn "could not fetch the probe through http://${name}/"
        warn "  Check: DNS points at this node, UFW allows 80, nginx is running."
        warn "  For a shared name this can also mean the request landed on the PEER;"
        warn "  that is handled by the ACME proxy snippet, but the peer must be up."
    fi
done
rm -f "${ACME_WEBROOT}/.well-known/acme-challenge/${probe}"

# ---------------------------------------------------------------------------
# 1. This node's own certificate - always issued locally.
# ---------------------------------------------------------------------------
if [[ ! -d "${CERT_ROOT}/renewal" ]] || ! grep -qrl "^\[renewalparams\]" "${CERT_ROOT}/renewal/${SELF_HOSTNAME}.conf" 2>/dev/null; then
    log "issuing a certificate for ${SELF_HOSTNAME}"
    certbot certonly --webroot -w "${ACME_WEBROOT}" \
        --non-interactive --agree-tos --email "${ADMIN_EMAIL}" \
        --cert-name "${SELF_HOSTNAME}" -d "${SELF_HOSTNAME}" \
        --key-type rsa --rsa-key-size 2048 \
        "${STAGING[@]}" \
        || warn "issuance for ${SELF_HOSTNAME} failed - the self-signed placeholder stays in place"
else
    ok "certificate for ${SELF_HOSTNAME} already exists"
fi

# ---------------------------------------------------------------------------
# 2. Shared names - LEADER ONLY.
# ---------------------------------------------------------------------------
if [[ "${IS_CERT_LEADER}" == "1" ]]; then
    log "this node is the ACME leader; issuing the shared certificate"
    certbot certonly --webroot -w "${ACME_WEBROOT}" \
        --non-interactive --agree-tos --email "${ADMIN_EMAIL}" \
        --cert-name "${MAIL_HOST}" \
        -d "${MAIL_HOST}" \
        -d "${WEBMAIL_HOST}" \
        -d "${ADMIN_HOST}" \
        -d "${AUTOCONFIG_HOST}" \
        -d "autodiscover.${DOMAIN}" \
        --key-type rsa --rsa-key-size 2048 \
        "${STAGING[@]}" \
        || warn "issuance for the shared names failed - see /var/log/letsencrypt/letsencrypt.log"

    # Publish for the follower.
    RENEWED_LINEAGE="${CERT_LIVE}" \
        "${CERT_ROOT}/renewal-hooks/deploy/hamail-cert-deploy-hook.sh" || true
    ok "shared certificate published to ${STATE_DIR}/cert-export"
else
    log "this node is the ACME follower; pulling the shared certificate from ${PEER_HOSTNAME}"
    /usr/local/bin/hamail-cert-sync.sh || \
        warn "pull failed. Issue the certificate on Node A first, then re-run: hamail-cert-sync.sh"
fi

# ---------------------------------------------------------------------------
# 3. Timers
# ---------------------------------------------------------------------------
# Certbot's own packaged timer handles renewal on the leader. The cert-sync
# timer runs on both nodes; on the leader it is a no-op that only warns if the
# export goes stale.
systemctl enable --now certbot.timer 2>/dev/null || true

render "${HAMAIL_TEMPLATES}/systemd/hamail-cert-sync.service.tpl" \
       /etc/systemd/system/hamail-cert-sync.service
install -m 0644 "${HAMAIL_TEMPLATES}/systemd/hamail-cert-sync.timer" \
       /etc/systemd/system/hamail-cert-sync.timer
systemctl daemon-reload
systemctl enable --now hamail-cert-sync.timer
ok "certificate sync timer enabled"

# ---------------------------------------------------------------------------
# 4. SNI maps and reloads
# ---------------------------------------------------------------------------
/usr/local/bin/hamail-sni-map.sh || warn "SNI map generation failed (harmless on a first run with no certificates yet)"

for unit in postfix dovecot nginx; do
    systemctl is-active --quiet "${unit}" && systemctl reload "${unit}" || true
done

ok "TLS configured"
