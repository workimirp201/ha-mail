##############################################################################
# ha-mail :: /etc/dovecot/auth-sql.conf.ext
# Wires the SQL passdb/userdb into Dovecot's auth process.
##############################################################################

passdb {
  driver = sql
  args = /etc/dovecot/dovecot-sql.conf.ext
}

# The userdb is a "prefetch" of the fields the passdb query already returned
# (home, mail, uid, gid, quota_rule), so a successful login costs exactly ONE
# database round trip instead of two. On a node whose database is local this
# is a micro-optimisation; it becomes important during a replication stall,
# when the local MariaDB may be busy applying a backlog from the peer.
userdb {
  driver = prefetch
}

# Fallback userdb for lookups that arrive without a password - LMTP delivery,
# doveadm, and the replicator all take this path. Without it, `doveadm sync`
# and every incoming message would fail with "user not found".
userdb {
  driver = sql
  args = /etc/dovecot/dovecot-sql.conf.ext
}
