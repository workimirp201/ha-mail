#!/usr/bin/env bash
##############################################################################
# ha-mail :: scripts/50-replication.sh
#
# Wires this node up as a replica of its peer. Run on BOTH nodes - the result
# is a two-node ring in which each is simultaneously master and replica.
#
# ORDER MATTERS:
#   1. Node A: 40-mariadb.sh, 45-db-schema.sh
#   2. Node B: 40-mariadb.sh          (no schema - it arrives by replication)
#   3. Node A: 50-replication.sh      (A starts following B)
#   4. Node B: 50-replication.sh      (B seeds from A, then follows A)
#
# Step 4 does the initial data seed with mariadb-dump --master-data, which is
# why Node B must not have run the schema script.
##############################################################################

set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_env "${HAMAIL_ENV_FILE:-${HAMAIL_ROOT}/.env}"
require_root

log "configuring replication: ${SELF_HOSTNAME} <- ${PEER_HOSTNAME} (${PEER_WG_IP})"

# ---------------------------------------------------------------------------
# The tunnel must be up. Replication over the public internet is not an
# option this blueprint supports.
# ---------------------------------------------------------------------------
ping -c 2 -W 3 -q "${PEER_WG_IP}" >/dev/null 2>&1 \
    || die "peer is unreachable over the tunnel. Run 20-wireguard.sh on both nodes first."

wait_for_port "${PEER_WG_IP}" 3306 30 \
    || die "peer MariaDB is not listening on ${PEER_WG_IP}:3306. Run 40-mariadb.sh there first."

# ---------------------------------------------------------------------------
# Node B first-run seeding.
# ---------------------------------------------------------------------------
# If this node has no schema yet, take a consistent snapshot of the peer and
# load it. --gtid records the peer's GTID position inside the dump, so the
# CHANGE MASTER below starts from exactly the right place with no gap and no
# replay of already-applied rows.
if ! mysql_root -N -B -e "SHOW DATABASES LIKE '${DB_NAME}'" | grep -q "${DB_NAME}"; then
    log "no local ${DB_NAME} yet - seeding from ${PEER_HOSTNAME}"
    log "(this locks the peer's tables briefly; on a fresh cluster that is instantaneous)"

    DUMP="$(mktemp /tmp/hamail-seed.XXXXXX.sql)"
    trap 'rm -f "${DUMP}"' EXIT

    mariadb-dump \
        --host="${PEER_WG_IP}" \
        --user="${DB_REPL_USER}" \
        --password="${DB_REPL_PASS}" \
        --single-transaction \
        --gtid \
        --master-data=2 \
        --routines --triggers --events \
        --databases "${DB_NAME}" "${RC_DB_NAME}" \
        > "${DUMP}" \
        || die "seed dump failed. Does ${DB_REPL_USER}@${SELF_WG_IP} exist on the peer with REPLICATION SLAVE?"

    gtid_pos="$(grep -m1 -oP "(?<=SET GLOBAL gtid_slave_pos=')[^']*" "${DUMP}" || true)"

    mysql_root < "${DUMP}"
    ok "seeded $(du -h "${DUMP}" | cut -f1) from ${PEER_HOSTNAME}"

    if [[ -n "${gtid_pos}" ]]; then
        mysql_root -e "SET GLOBAL gtid_slave_pos='${gtid_pos}';"
        ok "gtid_slave_pos set to ${gtid_pos}"
    else
        warn "no GTID position found in the dump; falling back to current_pos"
    fi
    rm -f "${DUMP}"
    trap - EXIT
fi

# ---------------------------------------------------------------------------
# Point this node at its peer.
# ---------------------------------------------------------------------------
mysql_root -e "STOP SLAVE;" 2>/dev/null || true

mysql_root <<SQL
CHANGE MASTER TO
    MASTER_HOST             = '${PEER_WG_IP}',
    MASTER_PORT             = 3306,
    MASTER_USER             = '${DB_REPL_USER}',
    MASTER_PASSWORD         = '${DB_REPL_PASS}',

    -- GTID-based positioning. slave_pos (not current_pos) means the replica
    -- tracks what it has APPLIED, so it resumes correctly after a crash
    -- without anyone reading a binlog filename and offset off a screen.
    MASTER_USE_GTID         = slave_pos,

    -- WAN settings. A 10s heartbeat lets the replica distinguish "the master
    -- is idle" from "the connection is dead" without waiting for
    -- slave_net_timeout (60s) on every quiet period.
    MASTER_HEARTBEAT_PERIOD = 10,
    MASTER_CONNECT_RETRY    = 10,
    MASTER_RETRY_COUNT      = 86400,

    -- TLS on top of WireGuard. MASTER_SSL_VERIFY_SERVER_CERT is OFF because
    -- the internal certificates carry hostnames, while the connection is made
    -- to a tunnel IP; enabling it would fail the name check. The transport is
    -- already authenticated by WireGuard's static keys, which is a stronger
    -- guarantee than a self-signed name check would add.
    MASTER_SSL              = 1,
    MASTER_SSL_CA           = '/etc/mysql/ssl/ca-cert.pem',
    MASTER_SSL_VERIFY_SERVER_CERT = 0;
SQL

mysql_root -e "START SLAVE;"
ok "replication started"

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
sleep 5
status="$(mysql_root -e 'SHOW SLAVE STATUS\G')"
io="$(sed -n 's/^\s*Slave_IO_Running:\s*//p'  <<<"${status}" | head -n1)"
sql="$(sed -n 's/^\s*Slave_SQL_Running:\s*//p' <<<"${status}" | head -n1)"
lag="$(sed -n 's/^\s*Seconds_Behind_Master:\s*//p' <<<"${status}" | head -n1)"
ioerr="$(sed -n 's/^\s*Last_IO_Error:\s*//p' <<<"${status}" | head -n1)"
sqlerr="$(sed -n 's/^\s*Last_SQL_Error:\s*//p' <<<"${status}" | head -n1)"

printf '\n' >&2
if [[ "${io}" == "Yes" && "${sql}" == "Yes" ]]; then
    ok "Slave_IO_Running=${io}  Slave_SQL_Running=${sql}  lag=${lag}s"
else
    err "Slave_IO_Running=${io}  Slave_SQL_Running=${sql}"
    [[ -n "${ioerr}"  ]] && err "IO error:  ${ioerr}"
    [[ -n "${sqlerr}" ]] && err "SQL error: ${sqlerr}"
    err ""
    err "Common causes:"
    err "  * ${DB_REPL_USER}@${SELF_WG_IP} does not exist on the peer (run 45-db-schema.sh on Node A)"
    err "  * DB_REPL_PASS differs between the two .env files"
    err "  * UFW on the peer is not allowing ${SELF_WG_IP} to reach port 3306"
    die "replication did not start cleanly"
fi

# ---------------------------------------------------------------------------
# End-to-end proof. Write a row here, read it on the peer.
# ---------------------------------------------------------------------------
# This is the only check that proves the whole path works, including the
# binlog_do_db filter (which silently drops statements issued without a
# default database).
marker="hamail-repl-test-$(date +%s)-${SELF_ROLE}"
mysql_root -e "USE ${DB_NAME}; INSERT INTO log (timestamp, username, domain, action, data) VALUES (NOW(), 'deploy', '${DOMAIN}', 'repl-test', '${marker}');"

log "waiting for the marker to appear on ${PEER_HOSTNAME}..."
found=0
for i in $(seq 1 20); do
    if mariadb -h "${PEER_WG_IP}" -u"${DB_REPL_USER}" -p"${DB_REPL_PASS}" -N -B \
            -e "SELECT COUNT(*) FROM ${DB_NAME}.log WHERE data='${marker}'" 2>/dev/null | grep -q '^1$'; then
        found=1
        ok "marker replicated to ${PEER_HOSTNAME} in ~$((i))s"
        break
    fi
    sleep 1
done

if (( found == 0 )); then
    warn "the marker did not appear on the peer within 20s."
    warn "If the peer has not yet run 50-replication.sh this is EXPECTED - it is not"
    warn "reading our binlog yet. Re-run this check after configuring both sides:"
    warn "  mariadb -h ${PEER_WG_IP} -u${DB_REPL_USER} -p -e \"SELECT * FROM ${DB_NAME}.log WHERE data='${marker}'\""
fi

mysql_root -e "USE ${DB_NAME}; DELETE FROM log WHERE data='${marker}';"
