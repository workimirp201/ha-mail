#!/usr/bin/env bash
##############################################################################
# ha-mail :: scripts/95-fail2ban.sh
##############################################################################

set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_env "${HAMAIL_ENV_FILE:-${HAMAIL_ROOT}/.env}"
require_root

log "configuring fail2ban"

render "${HAMAIL_TEMPLATES}/fail2ban/jail.d/hamail.conf.tpl" \
       /etc/fail2ban/jail.d/hamail.conf

for f in "${HAMAIL_TEMPLATES}"/fail2ban/filter.d/*.conf; do
    install -m 0644 "${f}" "/etc/fail2ban/filter.d/$(basename "${f}")"
done

# Roundcube's log file must exist before fail2ban starts, or the jail is
# disabled at load time and silently never protects anything.
ensure_dir "${ROUNDCUBE_ROOT}/logs" 0750 www-data:www-data
touch "${ROUNDCUBE_ROOT}/logs/errors.log"
chown www-data:www-data "${ROUNDCUBE_ROOT}/logs/errors.log"
touch /var/log/nginx/admin-access.log /var/log/nginx/error.log /var/log/nginx/access.log
touch /var/log/mail.log

systemctl enable --now fail2ban
systemctl restart fail2ban
sleep 3

# ---------------------------------------------------------------------------
# Verify. A jail listed in the config but not in `fail2ban-client status` is
# a jail that failed to load - usually a missing log file or a bad regex - and
# it protects nothing while looking configured.
# ---------------------------------------------------------------------------
active="$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:\s*//p')"
ok "active jails: ${active}"

for want in sshd postfix-sasl dovecot postfixadmin recidive; do
    if grep -q "${want}" <<<"${active}"; then
        ok "  ${want} loaded"
    else
        warn "  ${want} did NOT load - check: fail2ban-client status ${want}"
    fi
done

# ---------------------------------------------------------------------------
# The critical safety check.
# ---------------------------------------------------------------------------
# If the peer is not in ignoreip, the two nodes will ban each other during
# exactly the events that make them talk most: a replication catch-up, a
# certificate sync, a dsync storm after an outage.
if fail2ban-client get sshd ignoreip 2>/dev/null | grep -q "${PEER_IP}"; then
    ok "peer ${PEER_IP} is on the ignore list - the nodes cannot ban each other"
else
    err "PEER ${PEER_IP} IS NOT ON THE IGNORE LIST."
    err "The two nodes will ban each other during replication catch-up."
    die "fix ignoreip in /etc/fail2ban/jail.d/hamail.conf before continuing"
fi
