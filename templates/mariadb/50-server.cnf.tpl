##############################################################################
# ha-mail :: /etc/mysql/mariadb.conf.d/50-server.cnf
# Node ${SELF_ROLE} (${SELF_HOSTNAME}) - MariaDB 10.11 active-active pair
#
# THIS FILE IS GENERATED. Edit templates/mariadb/50-server.cnf.tpl instead.
#
# Replication topology: circular master-master over the WireGuard tunnel.
#   ${NODE_A_HOSTNAME} (${NODE_A_WG_IP}, server_id ${NODE_A_SERVER_ID}, offset 1)
#     <--> ${NODE_B_HOSTNAME} (${NODE_B_WG_IP}, server_id ${NODE_B_SERVER_ID}, offset 2)
##############################################################################

[server]

[mysqld]

# ---------------------------------------------------------------------------
# Paths and identity
# ---------------------------------------------------------------------------
user                            = mysql
pid-file                        = /run/mysqld/mysqld.pid
socket                          = /run/mysqld/mysqld.sock
basedir                         = /usr
datadir                         = /var/lib/mysql
tmpdir                          = /tmp
lc-messages-dir                 = /usr/share/mysql
lc_messages                     = en_US

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------
# MariaDB listens ONLY on the private WireGuard address. Every local consumer
# (Postfix, Dovecot, PHP-FPM) connects over the UNIX socket, so nothing but the
# peer node can even open a TCP session to the database.
#
# EDGE CASE: wg0 does not exist at boot until wg-quick has run, and binding to
# a non-existent address is a hard startup failure. Two defences are in place:
#   1. /etc/systemd/system/mariadb.service.d/10-hamail-wireguard.conf orders
#      mariadb after wg-quick@${WG_INTERFACE}.service
#   2. net.ipv4.ip_nonlocal_bind=1 (see /etc/sysctl.d/99-hamail.conf) lets the
#      bind succeed even in the race where the interface is a moment late.
bind-address                    = ${SELF_WG_IP}
port                            = 3306
skip-name-resolve                                  # never let DNS gate a login
max_connections                 = 300
max_connect_errors              = 100000           # WAN blips must not host-block the peer
back_log                        = 128
connect_timeout                 = 20               # generous: ~180ms RTT link
wait_timeout                    = 600
interactive_timeout             = 600
net_read_timeout                = 120
net_write_timeout               = 120
max_allowed_packet              = 64M

# ---------------------------------------------------------------------------
# Character set - utf8mb4 everywhere so that international display names and
# emoji in mailbox "name" fields do not truncate rows mid-replication.
# ---------------------------------------------------------------------------
character-set-server            = utf8mb4
collation-server                = utf8mb4_unicode_ci
init_connect                    = 'SET NAMES utf8mb4'

# ---------------------------------------------------------------------------
# Storage engine
# ---------------------------------------------------------------------------
default_storage_engine          = InnoDB
innodb_buffer_pool_size         = 512M             # tune to ~50% RAM on the node
innodb_buffer_pool_instances    = 1
innodb_log_file_size            = 256M
innodb_flush_method             = O_DIRECT
innodb_file_per_table           = ON

# Durability. Both must be at their safest settings: a master-master pair that
# loses a committed transaction on one side has silently forked.
innodb_flush_log_at_trx_commit  = 1
sync_binlog                     = 1

# READ-COMMITTED, not REPEATABLE-READ.
#   - Shorter gap locks => the admin portal cannot hold a range lock across a
#     150ms round trip while another admin inserts an adjacent alias.
#   - Safe with binlog_format=ROW (it is unsafe only with STATEMENT).
# See docs/AUDIT.md section 5 (web UI database lockups).
transaction_isolation           = READ-COMMITTED

# A blocked web request must fail fast and be retried by the app, not hang the
# PHP-FPM worker pool until it exhausts.
innodb_lock_wait_timeout        = 15
lock_wait_timeout               = 30

# ---------------------------------------------------------------------------
# BINARY LOG
# ---------------------------------------------------------------------------
log_bin                         = /var/log/mysql/mariadb-bin
log_bin_index                   = /var/log/mysql/mariadb-bin.index
binlog_format                   = ROW
binlog_row_image                = FULL
expire_logs_days                = 7
max_binlog_size                 = 256M
binlog_cache_size               = 1M

# STATEMENT format would be catastrophic here: NOW(), UUID(), LAST_INSERT_ID()
# and any statement whose result depends on auto_increment settings would
# diverge between the two nodes. ROW ships the resulting row images, so both
# databases converge byte-for-byte.

# ---------------------------------------------------------------------------
# SERVER IDENTITY AND AUTO_INCREMENT COLLISION AVOIDANCE
# ---------------------------------------------------------------------------
server_id                       = ${SELF_SERVER_ID}

# Every AUTO_INCREMENT column on this node yields values congruent to
# ${SELF_AUTOINC_OFFSET} (mod 2). Node A produces 1,3,5,7,... and Node B
# produces 2,4,6,8,... so two simultaneous inserts on opposite nodes can never
# be handed the same primary key.
#
#   auto_increment_increment = number of nodes in the ring (2)
#   auto_increment_offset    = this node's index within the ring (1 or 2)
#
# These are SESSION-inheriting GLOBAL variables and apply to every table in
# every schema on the server, which is why they are set here rather than
# per-application.
auto_increment_increment        = 2
auto_increment_offset           = ${SELF_AUTOINC_OFFSET}

# MariaDB GTIDs. gtid_domain_id must ALSO be unique per node, otherwise the
# two nodes' independent write streams are interleaved into one domain and
# parallel replication cannot order them.
gtid_domain_id                  = ${SELF_SERVER_ID}
gtid_strict_mode                = ON

# Mandatory in a ring: without it, writes Node A receives from Node B are not
# written to Node A's own binlog and a third node (or a rebuilt peer) could
# never catch up. It also makes point-in-time recovery complete.
log_slave_updates               = ON

# Both nodes are writable. Stated explicitly so that a package upgrade that
# ships a different default cannot silently demote a node to read-only.
read_only                       = OFF

# ---------------------------------------------------------------------------
# RELAY LOG AND SLAVE (this node acting as replica of its peer)
# ---------------------------------------------------------------------------
relay_log                       = /var/log/mysql/relay-bin
relay_log_index                 = /var/log/mysql/relay-bin.index
relay_log_recovery              = ON
relay_log_purge                 = ON

# Crash safety for replication position metadata.
sync_master_info                = 1
sync_relay_log                  = 1
sync_relay_log_info             = 1

# WAN tuning. The heartbeat is set on the CHANGE MASTER statement
# (MASTER_HEARTBEAT_PERIOD=10); slave_net_timeout must be comfortably larger
# than 2x that or the IO thread will reconnect in a loop across the ocean.
slave_net_timeout               = 60

# Compression pays for itself on a 150-200ms intercontinental link.
slave_compressed_protocol       = ON

# Conservative parallel replication preserves commit order semantics while
# still overlapping the network latency of independent transactions.
slave_parallel_threads          = 4
slave_parallel_mode             = conservative
slave_domain_parallel_threads   = 2

# Loop prevention: MariaDB already drops any event whose server_id matches its
# own, which is what stops a circular topology from replaying forever. This is
# stated for the reader's benefit - do NOT set replicate_same_server_id=1.
replicate_same_server_id        = 0

# --- DO NOT ADD slave_skip_errors ---------------------------------------
# It is tempting to set slave_skip_errors=1062 (duplicate key) to "fix"
# replication stalls. Do not. A skipped 1062 means the two databases now
# disagree about a row and will silently diverge forever. The correct response
# to a 1062 is to look at the conflicting row. bin/repl-watchdog.sh alerts on
# it rather than papering over it.

# ---------------------------------------------------------------------------
# REPLICATION FILTERS
# ---------------------------------------------------------------------------
# Tables deliberately kept node-local. Each entry is a table whose rows are
# *derived* state - correct to recompute locally, harmful to have two writers
# fight over. See docs/AUDIT.md section 6.
#
#   quota / quota2  : Dovecot's per-mailbox byte counters. Both nodes hold the
#                     same mail (dsync), so each node's locally computed count
#                     is already correct. Replicating them turns every message
#                     delivery into a cross-node write conflict.
#   session         : Roundcube PHP sessions. Node-local by design; we also
#                     set session_storage=php so this table stays near-empty.
#   cache*          : Roundcube message/index caches, tied to that node's
#                     Dovecot index state. Replicating them serves stale data.
replicate_ignore_table          = ${DB_NAME}.quota
replicate_ignore_table          = ${DB_NAME}.quota2
replicate_ignore_table          = ${RC_DB_NAME}.session
replicate_ignore_table          = ${RC_DB_NAME}.cache
replicate_ignore_table          = ${RC_DB_NAME}.cache_shared
replicate_ignore_table          = ${RC_DB_NAME}.cache_index
replicate_ignore_table          = ${RC_DB_NAME}.cache_messages
replicate_ignore_table          = ${RC_DB_NAME}.cache_thread

# Everything else in these two schemas replicates. Explicitly listing the
# schemas keeps mysql.* system tables (which legitimately differ per node,
# e.g. the replication user's own host grants) out of the stream.
replicate_do_db                 = ${DB_NAME}
replicate_do_db                 = ${RC_DB_NAME}
binlog_do_db                    = ${DB_NAME}
binlog_do_db                    = ${RC_DB_NAME}

# NOTE ON binlog_do_db: it filters on the session's *default* database. Every
# script in this blueprint issues `USE ${DB_NAME};` before DDL/DML, and both
# PostfixAdmin and Roundcube connect with a default database set, so this is
# safe. If you ever run a cross-schema statement by hand, prefix it with the
# matching USE or it will not replicate.

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log_error                       = /var/log/mysql/error.log
slow_query_log                  = ON
slow_query_log_file             = /var/log/mysql/mariadb-slow.log
long_query_time                 = 2
log_slow_verbosity              = query_plan,explain
log_warnings                    = 2

# ---------------------------------------------------------------------------
# SQL mode. STRICT_TRANS_TABLES is essential: a silently truncated value on one
# node and a rejection on the other is a divergence generator.
# NO_AUTO_CREATE_USER is not a valid mode in MariaDB 10.11 and is omitted.
# ---------------------------------------------------------------------------
sql_mode                        = STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION
innodb_strict_mode              = ON

# ---------------------------------------------------------------------------
# TLS for the replication channel.
# The link already runs inside WireGuard (ChaCha20-Poly1305), so this is
# defence in depth against a mis-scoped firewall rule, not the primary control.
# Certificates are generated by scripts/40-mariadb.sh into /etc/mysql/ssl/.
# ---------------------------------------------------------------------------
ssl_ca                          = /etc/mysql/ssl/ca-cert.pem
ssl_cert                        = /etc/mysql/ssl/server-cert.pem
ssl_key                         = /etc/mysql/ssl/server-key.pem
tls_version                     = TLSv1.2,TLSv1.3

[mysqldump]
quick
quote-names
max_allowed_packet              = 64M
single-transaction
routines
triggers

[mysql]
default-character-set           = utf8mb4

[client]
default-character-set           = utf8mb4
socket                          = /run/mysqld/mysqld.sock

[mariadb]
# Nothing node-specific. Present so that packaged includes have a section.
