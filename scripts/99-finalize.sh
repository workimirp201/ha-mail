#!/usr/bin/env bash
##############################################################################
# ha-mail :: scripts/99-finalize.sh
# Operational tooling, timers, and the closing report.
##############################################################################

set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_env "${HAMAIL_ENV_FILE:-${HAMAIL_ROOT}/.env}"
require_root

log "installing operational tooling"

for tpl in "${HAMAIL_TEMPLATES}"/bin/*.sh.tpl; do
    base="$(basename "${tpl}" .tpl)"
    # The deploy hook lives under the certbot hook directory, not in PATH.
    [[ "${base}" == "hamail-cert-deploy-hook.sh" ]] && continue
    render "${tpl}" "/usr/local/bin/${base}" 0755 root:root
done

render "${HAMAIL_TEMPLATES}/bin/hamail-cert-deploy-hook.sh.tpl" \
       "${CERT_ROOT}/renewal-hooks/deploy/hamail-cert-deploy-hook.sh" 0755 root:root

# ---------------------------------------------------------------------------
# Timers
# ---------------------------------------------------------------------------
render  "${HAMAIL_TEMPLATES}/systemd/hamail-health.service.tpl"        /etc/systemd/system/hamail-health.service
install -m 0644 "${HAMAIL_TEMPLATES}/systemd/hamail-health.timer"      /etc/systemd/system/hamail-health.timer
render  "${HAMAIL_TEMPLATES}/systemd/hamail-repl-watchdog.service.tpl" /etc/systemd/system/hamail-repl-watchdog.service
install -m 0644 "${HAMAIL_TEMPLATES}/systemd/hamail-repl-watchdog.timer" /etc/systemd/system/hamail-repl-watchdog.timer

systemctl daemon-reload
systemctl enable --now hamail-health.timer
systemctl enable --now hamail-repl-watchdog.timer
ok "monitoring timers enabled"

printf '%s\n' "${SELF_HOSTNAME}" > "${STATE_DIR}/node-name"
if [[ "${IS_ADMIN_LEADER}" == "1" ]]; then
    printf '%s\n' "${SELF_HOSTNAME}" > "${STATE_DIR}/admin-leader"
fi

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
DKIM_PUB=""
[[ -f "${STATE_DIR}/dkim-${SELF_DKIM_SELECTOR}.txt" ]] && \
    DKIM_PUB="$(cat "${STATE_DIR}/dkim-${SELF_DKIM_SELECTOR}.txt")"

cat >&2 <<REPORT

===============================================================================
  ha-mail :: node ${SELF_ROLE} (${SELF_HOSTNAME}) deployment complete
===============================================================================

  Public IP            ${SELF_IP}
  Tunnel IP            ${SELF_WG_IP}      peer: ${PEER_WG_IP} (${PEER_HOSTNAME})
  MariaDB server_id    ${SELF_SERVER_ID}, auto_increment_offset ${SELF_AUTOINC_OFFSET}
  DKIM selector        ${SELF_DKIM_SELECTOR}
  ACME role            $( [[ "${IS_CERT_LEADER}" == "1" ]] && echo "LEADER (issues shared certs)" || echo "follower (pulls from ${PEER_HOSTNAME})" )
  Admin portal role    $( [[ "${IS_ADMIN_LEADER}" == "1" ]] && echo "WRITE LEADER" || echo "warm standby" )

  Webmail              https://${WEBMAIL_HOST}/
  Admin portal         https://${ADMIN_HOST}/      (${ADMIN_USER})
  IMAP / SMTP          ${MAIL_HOST}

  DKIM record for this node:
    ${SELF_DKIM_SELECTOR}._domainkey.${DOMAIN}  TXT  "${DKIM_PUB}"

-------------------------------------------------------------------------------
  NEXT
-------------------------------------------------------------------------------
  1. Deploy the other node if you have not already.
  2. Publish every record in docs/DNS.md, including BOTH DKIM selectors and
     the reverse DNS (PTR) entry in the Linode Cloud Manager.
  3. Run the verification playbook:      docs/TESTING.md
  4. Check node health at any time:      hamail-health.sh
  5. Check replication:                  hamail-repl-watchdog.sh

  Do not move DMARC past p=none until aggregate reports confirm that mail from
  BOTH nodes is passing. That is the single most common way a correctly built
  two-node cluster ends up with half its mail in spam folders.
===============================================================================

REPORT

/usr/local/bin/hamail-health.sh || true
