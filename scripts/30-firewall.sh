#!/usr/bin/env bash
##############################################################################
# ha-mail :: scripts/30-firewall.sh
#
# UFW policy. The design principle: services that the internet needs are open
# to the world; services that only the PEER needs are open only to the peer's
# tunnel address AND bound only to the tunnel interface, so there are two
# independent controls on each of them.
##############################################################################

set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_env "${HAMAIL_ENV_FILE:-${HAMAIL_ROOT}/.env}"
require_root

log "configuring UFW"

# Never lock yourself out: allow SSH before enabling anything.
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed

# ---------------------------------------------------------------------------
# Administration
# ---------------------------------------------------------------------------
ufw limit "${SSH_PORT}/tcp" comment 'SSH (rate limited)'

# ---------------------------------------------------------------------------
# Public mail services
# ---------------------------------------------------------------------------
ufw allow 25/tcp   comment 'SMTP inbound (MX)'
ufw allow 587/tcp  comment 'Submission (STARTTLS)'
ufw allow 465/tcp  comment 'Submission (implicit TLS)'
ufw allow 143/tcp  comment 'IMAP (STARTTLS)'
ufw allow 993/tcp  comment 'IMAPS'
ufw allow 4190/tcp comment 'ManageSieve'

# POP3 (110/995) is deliberately closed - the protocol is not enabled in
# Dovecot. See templates/dovecot/dovecot.conf.tpl for why.

# ---------------------------------------------------------------------------
# Web
# ---------------------------------------------------------------------------
ufw allow 80/tcp  comment 'HTTP (ACME + redirect)'
ufw allow 443/tcp comment 'HTTPS (webmail, admin, autoconfig)'

# ---------------------------------------------------------------------------
# The tunnel itself
# ---------------------------------------------------------------------------
# Only from the peer's public address. WireGuard is silent to unauthenticated
# packets anyway, but there is no reason to let anyone else even send them.
ufw allow from "${PEER_IP}" to any port "${WG_PORT}" proto udp \
    comment "WireGuard from ${PEER_HOSTNAME}"

# ---------------------------------------------------------------------------
# Replication services - PEER TUNNEL ADDRESS ONLY
# ---------------------------------------------------------------------------
# These are belt-and-braces. MariaDB binds ${SELF_WG_IP} and Dovecot's doveadm
# listener binds ${SELF_WG_IP}, so neither is reachable from the public
# interface regardless of firewall state. The rules exist so that a future
# configuration change that widens a bind address does not silently expose a
# replication endpoint to the internet.
ufw allow from "${PEER_WG_IP}" to "${SELF_WG_IP}" port 3306 proto tcp \
    comment 'MariaDB replication (tunnel only)'
ufw allow from "${PEER_WG_IP}" to "${SELF_WG_IP}" port "${DOVEADM_PORT}" proto tcp \
    comment 'Dovecot dsync (tunnel only)'
ufw allow from "${PEER_WG_IP}" to "${SELF_WG_IP}" port 8080 proto tcp \
    comment 'ACME challenge peer endpoint (tunnel only)'
ufw allow from "${PEER_WG_IP}" to "${SELF_WG_IP}" port "${SSH_PORT}" proto tcp \
    comment 'Certificate sync over the tunnel'

# ---------------------------------------------------------------------------
# Explicit denies for things that must NEVER be public, so that an audit of
# `ufw status` shows intent rather than absence.
# ---------------------------------------------------------------------------
ufw deny 3306/tcp                     comment 'MariaDB is tunnel-only'
ufw deny "${DOVEADM_PORT}/tcp"        comment 'doveadm is tunnel-only'
ufw deny 11334/tcp                    comment 'rspamd UI is loopback-only'
ufw deny 6379/tcp                     comment 'Redis is loopback-only'
ufw deny 110/tcp                      comment 'POP3 not offered'
ufw deny 995/tcp                      comment 'POP3S not offered'

ufw logging low
ufw --force enable

ok "UFW enabled"
ufw status verbose
