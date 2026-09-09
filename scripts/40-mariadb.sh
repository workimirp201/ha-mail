#!/usr/bin/env bash
##############################################################################
# ha-mail :: scripts/40-mariadb.sh
# MariaDB server configuration, TLS material and the root account.
##############################################################################

set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_env "${HAMAIL_ENV_FILE:-${HAMAIL_ROOT}/.env}"
require_root

log "configuring MariaDB on node ${SELF_ROLE} (server_id=${SELF_SERVER_ID}, auto_increment_offset=${SELF_AUTOINC_OFFSET})"

# ---------------------------------------------------------------------------
# Internal TLS for the replication channel (defence in depth behind WireGuard)
# ---------------------------------------------------------------------------
SSLDIR=/etc/mysql/ssl
if [[ ! -f "${SSLDIR}/server-cert.pem" ]]; then
    ensure_dir "${SSLDIR}" 0750 mysql:mysql

    # A tiny private CA, valid for 10 years. It signs only these two nodes'
    # server certificates and is never used for anything a browser sees.
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -keyout "${SSLDIR}/ca-key.pem" -out "${SSLDIR}/ca-cert.pem" \
        -subj "/CN=ha-mail internal CA/O=${DOMAIN}" 2>/dev/null

    openssl req -newkey rsa:2048 -nodes \
        -keyout "${SSLDIR}/server-key.pem" -out "${SSLDIR}/server-req.pem" \
        -subj "/CN=${SELF_HOSTNAME}/O=${DOMAIN}" 2>/dev/null

    openssl x509 -req -in "${SSLDIR}/server-req.pem" -days 3650 \
        -CA "${SSLDIR}/ca-cert.pem" -CAkey "${SSLDIR}/ca-key.pem" \
        -set_serial 01 -out "${SSLDIR}/server-cert.pem" 2>/dev/null

    rm -f "${SSLDIR}/server-req.pem"
    chown -R mysql:mysql "${SSLDIR}"
    chmod 0600 "${SSLDIR}"/*-key.pem
    chmod 0644 "${SSLDIR}"/*-cert.pem
    ok "generated internal TLS material"
fi

# ---------------------------------------------------------------------------
# Server configuration
# ---------------------------------------------------------------------------
# Debian's own 50-server.cnf is replaced wholesale; render() keeps a
# .hamail-orig copy the first time.
render "${HAMAIL_TEMPLATES}/mariadb/50-server.cnf.tpl" \
       /etc/mysql/mariadb.conf.d/50-server.cnf

ensure_dir /var/log/mysql 0750 mysql:adm

systemctl restart mariadb
wait_for_port 127.0.0.1 3306 30 || \
    wait_for_port "${SELF_WG_IP}" 3306 30 || \
    die "MariaDB did not come up. Check /var/log/mysql/error.log - the usual cause on a first run is that ${SELF_WG_IP} does not exist yet (bring up WireGuard first)."

ok "MariaDB restarted with the cluster configuration"

# ---------------------------------------------------------------------------
# Verify the invariants that make multi-master safe.
# ---------------------------------------------------------------------------
# Checking rather than assuming: these three values ARE the collision-avoidance
# mechanism, and a typo in the template would otherwise stay invisible until
# two nodes are written to simultaneously.
inc="$(mysql_root -N -B -e 'SELECT @@auto_increment_increment')"
off="$(mysql_root -N -B -e 'SELECT @@auto_increment_offset')"
sid="$(mysql_root -N -B -e 'SELECT @@server_id')"
gid="$(mysql_root -N -B -e 'SELECT @@gtid_domain_id')"

[[ "${inc}" == "2" ]] || die "auto_increment_increment=${inc}, expected 2"
[[ "${off}" == "${SELF_AUTOINC_OFFSET}" ]] || die "auto_increment_offset=${off}, expected ${SELF_AUTOINC_OFFSET}"
[[ "${sid}" == "${SELF_SERVER_ID}" ]] || die "server_id=${sid}, expected ${SELF_SERVER_ID}"
[[ "${gid}" == "${SELF_SERVER_ID}" ]] || die "gtid_domain_id=${gid}, expected ${SELF_SERVER_ID}"

ok "collision guards verified: increment=${inc} offset=${off} server_id=${sid} gtid_domain=${gid}"

# ---------------------------------------------------------------------------
# Root account
# ---------------------------------------------------------------------------
# unix_socket authentication is kept as the PRIMARY method for root: it means
# no root password exists on the wire or in any script, and `sudo mariadb`
# just works. The password is set as a secondary credential so that tooling
# which insists on one can still connect over the socket.
mysql_root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('${DB_ROOT_PASS}');
DELETE FROM mysql.global_priv WHERE User='';
DELETE FROM mysql.global_priv WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL
ok "root account secured, anonymous users and test database removed"

# A root credentials file so scripts and mysqldump work non-interactively.
cat > /root/.my.cnf <<CNF
[client]
user=root
password=${DB_ROOT_PASS}
socket=/run/mysqld/mysqld.sock
CNF
chmod 600 /root/.my.cnf

ok "MariaDB configured"
