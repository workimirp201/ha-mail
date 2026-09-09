##############################################################################
# ha-mail :: /etc/dovecot/dovecot-sql.conf.ext
# Node ${SELF_ROLE} - queries the LOCAL MariaDB replica over the UNIX socket.
#
# Mode 0640 root:dovecot. It contains a password; it must never be world
# readable, and the auth process runs as root before dropping privileges.
##############################################################################

driver = mysql

# host=/run/mysqld/mysqld.sock selects the UNIX socket. The database is not
# reachable over TCP from this host at all (bind-address = ${SELF_WG_IP}), so
# there is no fallback path a misconfiguration could take.
connect = host=/run/mysqld/mysqld.sock dbname=${DB_NAME} user=${DB_RO_USER} password=${DB_RO_PASS}

# Stored hashes carry their own {SCHEME} prefix, written by PostfixAdmin via
# `doveadm pw`. This value is only the fallback for a hash that somehow lacks
# one; ARGON2ID is the correct modern choice and is what the portal produces.
default_pass_scheme = ARGON2ID

# ---------------------------------------------------------------------------
# password_query
# ---------------------------------------------------------------------------
# Returns the hash AND, via the userdb_ prefix, every userdb field - so the
# prefetch userdb needs no second query.
#
#   userdb_home        where mail_attribute_dict and Sieve scripts live
#   userdb_mail        the full mail_location for THIS user
#   userdb_quota_rule  per-mailbox quota from the portal, in bytes
#
# `quota = 0` in the database means unlimited; CASE turns that into the
# literal Dovecot rule "*:bytes=0" which Dovecot reads as no limit.
#
# NOTE ON %u/%d/%n: Dovecot escapes these for the SQL driver before
# substitution. Do not add your own quoting around them.
password_query = \
  SELECT username AS user, \
         password, \
         '${VMAIL_ROOT}/%d/%n' AS userdb_home, \
         'maildir:${VMAIL_ROOT}/%d/%n/Maildir:INDEX=${VMAIL_INDEX_ROOT}/%d/%n/index:CONTROL=${VMAIL_INDEX_ROOT}/%d/%n/control' AS userdb_mail, \
         ${VMAIL_UID} AS userdb_uid, \
         ${VMAIL_GID} AS userdb_gid, \
         CONCAT('*:bytes=', quota) AS userdb_quota_rule \
  FROM mailbox \
  WHERE username = '%u' \
    AND active = '1' \
    AND (password_expiry = '2000-01-01 00:00:00' OR password_expiry > NOW())

# ---------------------------------------------------------------------------
# user_query
# ---------------------------------------------------------------------------
# Used by LMTP, doveadm and the replicator - every path that needs a user's
# storage layout without a password.
user_query = \
  SELECT '${VMAIL_ROOT}/%d/%n' AS home, \
         'maildir:${VMAIL_ROOT}/%d/%n/Maildir:INDEX=${VMAIL_INDEX_ROOT}/%d/%n/index:CONTROL=${VMAIL_INDEX_ROOT}/%d/%n/control' AS mail, \
         ${VMAIL_UID} AS uid, \
         ${VMAIL_GID} AS gid, \
         CONCAT('*:bytes=', quota) AS quota_rule \
  FROM mailbox \
  WHERE username = '%u' \
    AND active = '1'

# ---------------------------------------------------------------------------
# iterate_query
# ---------------------------------------------------------------------------
# REQUIRED FOR REPLICATION. `doveadm sync -A`, `doveadm replicator replicate
# '*'` and the nightly full-sync all enumerate users through this query. If it
# is missing, per-user replication still works but you can never run a
# cluster-wide resync - which is exactly the operation you need after a node
# has been offline. Omitting it is one of the most common ways a "working"
# Dovecot replication setup turns out to be unrecoverable.
iterate_query = \
  SELECT username AS user \
  FROM mailbox \
  WHERE active = '1'
