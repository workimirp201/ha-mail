#!/usr/bin/env bash
##############################################################################
# ha-mail :: scripts/10-base-system.sh
# Hostname, timezone, packages, users, directories, sysctl, SSH key for the
# inter-node channel.
##############################################################################

set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_env "${HAMAIL_ENV_FILE:-${HAMAIL_ROOT}/.env}"
require_root

log "configuring base system for node ${SELF_ROLE}"

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------
hostnamectl set-hostname "${SELF_HOSTNAME}"
timedatectl set-timezone "${TIMEZONE}"
systemctl enable --now systemd-timesyncd 2>/dev/null || true

# /etc/hosts must map the FQDN to the PUBLIC address, not to 127.0.1.1.
# Postfix derives $myhostname and its HELO name from this; a loopback mapping
# makes the node HELO as something unroutable and a meaningful share of
# receivers reject that outright.
cat > /etc/hosts <<HOSTS
127.0.0.1       localhost
${SELF_IP}      ${SELF_HOSTNAME} ${SELF_SHORTNAME}

# The peer, by BOTH its public and tunnel addresses. Having these here means
# the cluster's own tooling keeps working during a DNS outage.
${PEER_IP}      ${PEER_HOSTNAME} ${PEER_SHORTNAME}
${PEER_WG_IP}   ${PEER_SHORTNAME}.wg

::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
HOSTS
ok "hostname and /etc/hosts set"

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -q

# Postfix asks interactive questions unless it is pre-seeded.
debconf-set-selections <<SEED
postfix postfix/main_mailer_type select Internet Site
postfix postfix/mailname string ${SELF_HOSTNAME}
SEED

apt_install \
    ca-certificates curl wget gnupg lsb-release apt-transport-https \
    software-properties-common rsync jq git unzip bzip2 \
    dnsutils net-tools iproute2 telnet swaks \
    openssl ssl-cert \
    wireguard wireguard-tools \
    ufw fail2ban \
    mariadb-server mariadb-client \
    postfix postfix-mysql postfix-pcre \
    dovecot-core dovecot-imapd dovecot-lmtpd dovecot-mysql \
    dovecot-sieve dovecot-managesieved \
    rspamd redis-server \
    nginx \
    php8.3-fpm php8.3-cli php8.3-mysql php8.3-mbstring php8.3-xml \
    php8.3-curl php8.3-zip php8.3-intl php8.3-gd php8.3-imap \
    php8.3-ldap php8.3-bcmath php8.3-opcache \
    certbot \
    postfix-policyd-spf-python \
    bsd-mailx logrotate cron gettext-base

ok "packages installed"

# ---------------------------------------------------------------------------
# Mail storage user
# ---------------------------------------------------------------------------
# A fixed UID/GID on BOTH nodes is not cosmetic: dsync transfers file metadata,
# and a restore or an rsync-based recovery between nodes with different UIDs
# produces a mail store that Dovecot refuses to open.
if ! getent group "${VMAIL_GROUP}" >/dev/null; then
    groupadd -g "${VMAIL_GID}" "${VMAIL_GROUP}"
fi
if ! getent passwd "${VMAIL_USER}" >/dev/null; then
    useradd -r -g "${VMAIL_GROUP}" -u "${VMAIL_UID}" \
            -d "${VMAIL_ROOT}" -s /usr/sbin/nologin \
            -c "Virtual mail store" "${VMAIL_USER}"
fi

actual_uid="$(id -u "${VMAIL_USER}")"
[[ "${actual_uid}" == "${VMAIL_UID}" ]] \
    || die "${VMAIL_USER} has UID ${actual_uid}, expected ${VMAIL_UID}. Both nodes MUST match."

ensure_dir "${VMAIL_ROOT}"        0770 "${VMAIL_USER}:${VMAIL_GROUP}"
ensure_dir "${VMAIL_INDEX_ROOT}"  0770 "${VMAIL_USER}:${VMAIL_GROUP}"
ensure_dir "${STATE_DIR}"         0750 root:root
ensure_dir "${LOG_DIR}"           0750 root:root
ensure_dir "${ACME_WEBROOT}"      0755 www-data:www-data
ensure_dir /var/lib/php/sessions-postfixadmin 0700 www-data:www-data
ensure_dir /var/lib/php/sessions-roundcube    0700 www-data:www-data
ensure_dir /var/www/autoconfig    0755 www-data:www-data
ok "users and directories created"

# ---------------------------------------------------------------------------
# sysctl
# ---------------------------------------------------------------------------
cat > /etc/sysctl.d/99-hamail.conf <<SYSCTL
# ha-mail :: kernel tuning

# THE IMPORTANT ONE.
# MariaDB, Dovecot's doveadm listener and nginx's ACME peer endpoint all bind
# to ${SELF_WG_IP}, which does not exist until wg-quick has run. Without this,
# a boot where a service starts a fraction of a second before the tunnel dies
# with EADDRNOTAVAIL - intermittently, and never when you try to reproduce it.
# The systemd drop-ins order the units correctly; this closes the residual race.
net.ipv4.ip_nonlocal_bind = 1

# Connection handling for a public-facing MTA.
net.core.somaxconn = 1024
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# BBR: measurably better throughput on a long fat pipe, which is exactly what
# a Singapore-to-US replication link is.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Buffers sized for a ~180ms RTT. The bandwidth-delay product on this path is
# large enough that the stock 6 MiB ceiling caps a single dsync stream.
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Anti-spoofing and ICMP hygiene.
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Maildir means a lot of small files and a lot of inotify watches.
fs.inotify.max_user_watches = 524288
fs.file-max = 2097152

# Mail servers must not swap. Latency here becomes SMTP timeouts.
vm.swappiness = 10
SYSCTL
sysctl -q --system
ok "sysctl applied"

# ---------------------------------------------------------------------------
# systemd ordering drop-ins for every service that binds the tunnel address
# ---------------------------------------------------------------------------
for unit in mariadb dovecot nginx; do
    ensure_dir "/etc/systemd/system/${unit}.service.d" 0755 root:root
    render "${HAMAIL_TEMPLATES}/systemd/10-hamail-wireguard.conf.tpl" \
           "/etc/systemd/system/${unit}.service.d/10-hamail-wireguard.conf"
done
systemctl daemon-reload
ok "systemd ordering drop-ins installed"

# ---------------------------------------------------------------------------
# SSH key for the inter-node channel (certificate sync, operator jumps)
# ---------------------------------------------------------------------------
# A dedicated key, not the operator's. It is restricted in authorized_keys on
# the peer to the tunnel source address, so it is useless from anywhere else.
if [[ ! -f /root/.ssh/id_ed25519_hamail ]]; then
    ensure_dir /root/.ssh 0700 root:root
    ssh-keygen -t ed25519 -N '' -C "ha-mail ${SELF_HOSTNAME}" \
               -f /root/.ssh/id_ed25519_hamail
    ok "generated /root/.ssh/id_ed25519_hamail"
fi

cat <<NOTE >&2

  ---------------------------------------------------------------------------
  ACTION REQUIRED (once per pair): authorise this node's key on the peer.

  Public key for ${SELF_HOSTNAME}:

$(sed 's/^/    /' /root/.ssh/id_ed25519_hamail.pub)

  On ${PEER_HOSTNAME}, append it to /root/.ssh/authorized_keys with a
  from= restriction so it is only usable across the tunnel:

    from="${SELF_WG_IP}",restrict,pty $(cat /root/.ssh/id_ed25519_hamail.pub)

  'restrict' disables port forwarding, agent forwarding and X11; 'pty' is
  re-enabled because rsync needs a usable channel.
  ---------------------------------------------------------------------------

NOTE

# ---------------------------------------------------------------------------
# Log rotation for this project's own logs
# ---------------------------------------------------------------------------
cat > /etc/logrotate.d/ha-mail <<ROTATE
${LOG_DIR}/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
}
ROTATE

ok "base system configured"
