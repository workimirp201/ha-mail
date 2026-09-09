#!/usr/bin/env bash
##############################################################################
# ha-mail :: scripts/00-preflight.sh
#
# Refuses to start a deploy that is going to fail halfway through. Every check
# here exists because getting it wrong produces a broken cluster that looks
# like it worked.
##############################################################################

set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_env "${HAMAIL_ENV_FILE:-${HAMAIL_ROOT}/.env}"
require_root

log "preflight checks for node ${SELF_ROLE} (${SELF_HOSTNAME})"

FATAL=0
problem() { err "$1"; FATAL=1; }

# ---------------------------------------------------------------------------
# OS
# ---------------------------------------------------------------------------
. /etc/os-release
if [[ "${ID}" != "ubuntu" ]]; then
    problem "this blueprint targets Ubuntu; found ${ID} ${VERSION_ID}"
elif [[ "${VERSION_ID}" != "24.04" ]]; then
    warn "tested on Ubuntu 24.04; found ${VERSION_ID}. Package names (php8.3-*, dovecot 2.3) may differ."
else
    ok "Ubuntu ${VERSION_ID}"
fi

# ---------------------------------------------------------------------------
# THIS is the check that catches the most damaging mistake: running the deploy
# with the wrong NODE_ROLE. Every auto_increment offset, every DKIM selector
# and the ACME leader election derive from it. Getting it backwards produces
# two nodes that both believe they are Node A - which is a guaranteed
# primary-key collision the first time both are written to.
# ---------------------------------------------------------------------------
declare -a my_ips
mapfile -t my_ips < <(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1)
if printf '%s\n' "${my_ips[@]}" | grep -qx "${SELF_IP}"; then
    ok "NODE_ROLE=${SELF_ROLE} matches a local address (${SELF_IP})"
elif printf '%s\n' "${my_ips[@]}" | grep -qx "${PEER_IP}"; then
    problem "NODE_ROLE IS WRONG. This machine holds ${PEER_IP}, which the .env calls node ${PEER_ROLE}."
    problem "Set NODE_ROLE=${PEER_ROLE} in ${HAMAIL_ENV_FILE} and re-run."
else
    warn "neither ${SELF_IP} nor ${PEER_IP} is configured on this host."
    warn "  local addresses: ${my_ips[*]}"
    warn "  This is normal behind a cloud NAT, but verify it is not a typo."
fi

# ---------------------------------------------------------------------------
# Hostname
# ---------------------------------------------------------------------------
current_fqdn="$(hostname -f 2>/dev/null || hostname)"
if [[ "${current_fqdn}" != "${SELF_HOSTNAME}" ]]; then
    warn "hostname is '${current_fqdn}', expected '${SELF_HOSTNAME}' - 10-base-system.sh will set it"
else
    ok "hostname is ${SELF_HOSTNAME}"
fi

# ---------------------------------------------------------------------------
# Resources
# ---------------------------------------------------------------------------
mem_mb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 ))
if (( mem_mb < 1800 )); then
    problem "only ${mem_mb} MiB RAM. MariaDB + Dovecot + rspamd + PHP-FPM need 2 GiB as an absolute floor."
elif (( mem_mb < 3800 )); then
    warn "${mem_mb} MiB RAM. Workable, but lower innodb_buffer_pool_size in 50-server.cnf."
else
    ok "${mem_mb} MiB RAM"
fi

disk_gb=$(( $(df --output=avail -k /var | tail -n1) / 1024 / 1024 ))
if (( disk_gb < 10 )); then
    problem "only ${disk_gb} GiB free on /var - mail storage and binlogs both live there"
else
    ok "${disk_gb} GiB free on /var"
fi

# ---------------------------------------------------------------------------
# Outbound port 25. Most cloud providers block it by default, including
# Linode on new accounts. Discovering this AFTER the build is a miserable
# afternoon: everything looks healthy and no mail ever leaves.
# ---------------------------------------------------------------------------
if timeout 8 bash -c '>/dev/tcp/gmail-smtp-in.l.google.com/25' 2>/dev/null; then
    ok "outbound port 25 is open"
else
    problem "OUTBOUND PORT 25 IS BLOCKED."
    problem "  Linode blocks SMTP on new accounts. Open a support ticket to have it unblocked"
    problem "  BEFORE going further, or this cluster will accept mail and never deliver any."
fi

# ---------------------------------------------------------------------------
# DNS that must already exist for ACME to succeed
# ---------------------------------------------------------------------------
for name in "${SELF_HOSTNAME}" "${MAIL_HOST}"; do
    if [[ -z "$(dig +short A "${name}" 2>/dev/null)" ]]; then
        problem "no A record for ${name} - Let's Encrypt HTTP-01 validation will fail"
    else
        ok "${name} resolves"
    fi
done

# The peer must be reachable on the WireGuard port before we can build a
# tunnel; a UFW rule on the other side is the usual culprit.
if [[ -n "${WG_PEER_PUBKEY}" ]]; then
    ok "peer WireGuard public key is configured"
else
    warn "WG_PEER_PUBKEY is empty - 20-wireguard.sh will generate this node's keys and stop"
    warn "  so you can exchange them. That is expected on a first run."
fi

# ---------------------------------------------------------------------------
# Clock. Replication, TOTP, TLS validity and DKIM all care.
# ---------------------------------------------------------------------------
if timedatectl show -p NTPSynchronized --value | grep -q yes; then
    ok "clock is NTP-synchronised"
else
    warn "clock is not NTP-synchronised - 10-base-system.sh enables systemd-timesyncd"
fi

# ---------------------------------------------------------------------------
# Conflicting packages
# ---------------------------------------------------------------------------
for pkg in exim4 sendmail apache2 mysql-server bind9; do
    if dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q "ok installed"; then
        problem "${pkg} is installed and will conflict. Remove it first: apt purge ${pkg}"
    fi
done

((FATAL == 0)) || die "preflight failed - fix the problems above before deploying"
ok "preflight passed"
