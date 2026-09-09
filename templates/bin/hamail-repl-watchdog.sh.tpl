#!/usr/bin/env bash
##############################################################################
# ha-mail :: /usr/local/bin/hamail-repl-watchdog.sh
# Node ${SELF_ROLE} - ${SELF_HOSTNAME}
#
# Runs every 5 minutes from hamail-repl-watchdog.timer.
#
# WHY A WATCHDOG IS NOT OPTIONAL HERE
# Replication failure on an active-active mail cluster is SILENT. Both nodes
# keep accepting mail, both keep authenticating users, both keep serving IMAP.
# They simply stop agreeing about what exists. Nobody notices until a user
# says "the message I read this morning is unread again", by which time the
# two databases may have diverged for days and the merge is a manual job.
#
# What this checks:
#   1. MariaDB IO and SQL threads are both running
#   2. Seconds_Behind_Master is within tolerance
#   3. No last_error (especially 1062 duplicate key - the multi-master
#      collision signature)
#   4. The Dovecot replicator queue is draining, not growing
#   5. The tunnel is up and the peer's replication ports answer
#
# It ALERTS. It deliberately does NOT auto-repair: every automatic fix for a
# diverged multi-master pair either loses data or hides the divergence.
##############################################################################

set -Eeuo pipefail

PEER_WG_IP="${PEER_WG_IP}"
PEER_HOSTNAME="${PEER_HOSTNAME}"
SELF_HOSTNAME="${SELF_HOSTNAME}"
DOVEADM_PORT="${DOVEADM_PORT}"
STATE_DIR="${STATE_DIR}"
LOG_DIR="${LOG_DIR}"
ALERT_EMAIL="${ALERT_EMAIL}"
WG_INTERFACE="${WG_INTERFACE}"

LOG="$LOG_DIR/replication.log"
ALERT_STATE="$STATE_DIR/repl-alert-state"
MAX_LAG_SECONDS=300
MAX_REPL_QUEUE=500

mkdir -p "$LOG_DIR" "$STATE_DIR"
PROBLEMS=()

log()  { printf '%s [repl-watchdog] %s\n' "$(date -Is)" "$*" >> "$LOG"; }
fail() { PROBLEMS+=("$1"); log "PROBLEM: $1"; }

# --------------------------------------------------------------------------
# 1. The tunnel
# --------------------------------------------------------------------------
if ! ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
    fail "WireGuard interface $WG_INTERFACE does not exist"
elif ! ping -c 2 -W 3 -q "$PEER_WG_IP" >/dev/null 2>&1; then
    fail "peer $PEER_HOSTNAME ($PEER_WG_IP) is unreachable over the tunnel"
else
    handshake="$(wg show "$WG_INTERFACE" latest-handshakes 2>/dev/null | awk '{print $2}' | head -n1)"
    if [[ -n "${handshake:-}" && "$handshake" != "0" ]]; then
        age=$(( $(date +%s) - handshake ))
        (( age > 300 )) && fail "no WireGuard handshake with the peer for ${age}s"
    fi
fi

# --------------------------------------------------------------------------
# 2. MariaDB replica health
# --------------------------------------------------------------------------
# --protocol=socket + unix_socket auth means no password lives in this script.
if ! status="$(mariadb --protocol=socket -uroot -e 'SHOW SLAVE STATUS\G' 2>/dev/null)"; then
    fail "cannot query MariaDB (is it running?)"
    status=""
fi

if [[ -z "$status" ]]; then
    fail "SHOW SLAVE STATUS is EMPTY - this node is not replicating from $PEER_HOSTNAME at all"
else
    io="$(sed -n 's/^\s*Slave_IO_Running:\s*//p'  <<<"$status" | head -n1)"
    sql="$(sed -n 's/^\s*Slave_SQL_Running:\s*//p' <<<"$status" | head -n1)"
    lag="$(sed -n 's/^\s*Seconds_Behind_Master:\s*//p' <<<"$status" | head -n1)"
    errno="$(sed -n 's/^\s*Last_Errno:\s*//p' <<<"$status" | head -n1)"
    errtxt="$(sed -n 's/^\s*Last_Error:\s*//p' <<<"$status" | head -n1)"
    ioerr="$(sed -n 's/^\s*Last_IO_Error:\s*//p' <<<"$status" | head -n1)"
    gtid="$(sed -n 's/^\s*Gtid_IO_Pos:\s*//p' <<<"$status" | head -n1)"

    [[ "$io"  == "Yes" ]] || fail "Slave_IO_Running=$io (last IO error: ${ioerr:-none})"
    [[ "$sql" == "Yes" ]] || fail "Slave_SQL_Running=$sql (last error: ${errtxt:-none})"

    if [[ "${errno:-0}" != "0" ]]; then
        if [[ "$errno" == "1062" ]]; then
            fail "DUPLICATE KEY (1062) on the replica - the two nodes inserted the same primary key. \
This is a multi-master WRITE COLLISION, not a transient fault. Do NOT skip it with \
sql_slave_skip_counter: that guarantees permanent divergence. Inspect the conflicting row, \
decide which side is correct, reconcile by hand, then restart the SQL thread. \
Details: $errtxt"
        else
            fail "replica SQL error $errno: $errtxt"
        fi
    fi

    if [[ "$lag" == "NULL" ]]; then
        [[ "$io" == "Yes" && "$sql" == "Yes" ]] && fail "Seconds_Behind_Master is NULL while both threads report running"
    elif [[ -n "${lag:-}" ]] && (( lag > MAX_LAG_SECONDS )); then
        fail "replication lag ${lag}s exceeds $MAX_LAG_SECONDS seconds"
    fi

    log "mariadb io=$io sql=$sql lag=${lag:-?} gtid=${gtid:-?}"
fi

# --------------------------------------------------------------------------
# 3. Confirm the auto_increment guards are actually in force.
# --------------------------------------------------------------------------
# These are the mechanism that prevents surrogate-key collisions. A package
# upgrade that reinstates a stock 50-server.cnf silently removes them, and
# nothing breaks until the first simultaneous insert. Check them every run.
inc="$(mariadb --protocol=socket -uroot -N -B -e "SELECT @@auto_increment_increment" 2>/dev/null || echo '?')"
off="$(mariadb --protocol=socket -uroot -N -B -e "SELECT @@auto_increment_offset" 2>/dev/null || echo '?')"
[[ "$inc" == "2" ]] || fail "auto_increment_increment=$inc (expected 2) - PRIMARY KEY COLLISIONS ARE NOW POSSIBLE"
[[ "$off" == "${SELF_AUTOINC_OFFSET}" ]] || fail "auto_increment_offset=$off (expected ${SELF_AUTOINC_OFFSET}) - PRIMARY KEY COLLISIONS ARE NOW POSSIBLE"

# --------------------------------------------------------------------------
# 4. Dovecot replicator queue
# --------------------------------------------------------------------------
if ! repl="$(doveadm replicator status 2>/dev/null)"; then
    fail "cannot query the Dovecot replicator (is dovecot running, and is the replication plugin loaded?)"
else
    queued="$(awk '/Queued .*requests/ {print $NF}' <<<"$repl" | head -n1)"
    queued="${queued:-0}"
    failed="$(awk '/Waiting .*failed/ {print $NF}' <<<"$repl" | head -n1)"
    failed="${failed:-0}"

    [[ "$queued" =~ ^[0-9]+$ ]] || queued=0
    [[ "$failed" =~ ^[0-9]+$ ]] || failed=0

    (( queued > MAX_REPL_QUEUE )) && fail "Dovecot replication queue is ${queued} (threshold $MAX_REPL_QUEUE) - the tunnel or the peer cannot keep up"
    (( failed > 0 )) && fail "${failed} mailbox replication request(s) have failed and are waiting to retry"

    log "dovecot replicator queued=$queued failed=$failed"
fi

# --------------------------------------------------------------------------
# 5. Peer replication endpoints answer
# --------------------------------------------------------------------------
for port in 3306 "$DOVEADM_PORT"; do
    if ! timeout 5 bash -c ">/dev/tcp/$PEER_WG_IP/$port" 2>/dev/null; then
        fail "peer port $port is not answering on $PEER_WG_IP"
    fi
done

# --------------------------------------------------------------------------
# Alerting: report on transition only, so a persistent fault does not mail
# every five minutes forever.
# --------------------------------------------------------------------------
now_state="ok"
(( ${#PROBLEMS[@]} > 0 )) && now_state="problem"
prev_state="$(cat "$ALERT_STATE" 2>/dev/null || echo ok)"
printf '%s\n' "$now_state" > "$ALERT_STATE"

if (( ${#PROBLEMS[@]} > 0 )); then
    printf 'Replication problems on %s:\n\n' "$SELF_HOSTNAME" >&2
    printf '  - %s\n' "${PROBLEMS[@]}" >&2

        # shellcheck disable=SC2157  # ALERT_EMAIL is substituted at render time and may be empty
    if [[ "$prev_state" == "ok" && -n "$ALERT_EMAIL" ]]; then
        {
            printf 'Replication health check FAILED on %s\n\n' "$SELF_HOSTNAME"
            printf 'Peer: %s (%s)\n\n' "$PEER_HOSTNAME" "$PEER_WG_IP"
            printf '  - %s\n\n' "${PROBLEMS[@]}"
            printf 'Runbook: /opt/ha-mail/docs/TESTING.md\n'
        } | mail -s "[ha-mail] replication problem on $SELF_HOSTNAME" "$ALERT_EMAIL" 2>/dev/null || true
    fi
    exit 1
fi

# shellcheck disable=SC2157  # ALERT_EMAIL is substituted at render time and may be empty
if [[ "$prev_state" == "problem" && -n "$ALERT_EMAIL" ]]; then
    printf 'Replication has recovered on %s.\n' "$SELF_HOSTNAME" \
        | mail -s "[ha-mail] replication RECOVERED on $SELF_HOSTNAME" "$ALERT_EMAIL" 2>/dev/null || true
fi

log "all replication checks passed"
exit 0
