##############################################################################
# ha-mail :: /etc/dovecot/dovecot-dict-sql.conf.ext
#
# The quota dictionary. Used ONLY by the quota_clone plugin, which mirrors the
# authoritative (index-derived) quota value into SQL so PostfixAdmin can show
# a usage bar.
#
# CRITICAL ARCHITECTURAL POINT
# ---------------------------
# `quota2` is in replicate_ignore_table on BOTH nodes (see 50-server.cnf).
# Each node writes its own copy of these counters and never receives the
# peer's. That is correct, not a bug:
#
#   * both nodes hold the same messages (dsync), so both independently compute
#     the same number - there is nothing to gain by shipping it across an
#     ocean
#   * if the table DID replicate, every single message delivery on either node
#     would become a cross-node UPDATE on the same row, and two deliveries to
#     the same mailbox seconds apart on opposite nodes would race. On a 180ms
#     link that race is not theoretical, it is the common case for a busy
#     mailbox.
#
# The quota that actually gates delivery is the `count` backend in
# 90-quota.conf, which reads Dovecot's own indexes and never touches SQL.
# If MariaDB is down, quota enforcement keeps working; only the portal's
# usage display goes stale.
##############################################################################

connect = host=/run/mysqld/mysqld.sock dbname=${DB_NAME} user=${DB_RO_USER} password=${DB_RO_PASS}

map {
  pattern = priv/quota/storage
  table = quota2
  username_field = username
  value_field = bytes
}

map {
  pattern = priv/quota/messages
  table = quota2
  username_field = username
  value_field = messages
}
