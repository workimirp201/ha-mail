# ha-mail :: GENERATED - edit the matching .tpl in templates/postfix/sql/
#
# Connection is over the LOCAL UNIX socket to the LOCAL MariaDB replica.
# A node NEVER queries its peer: if the tunnel is down, mail delivery keeps
# working from the last replicated state. That is the entire point of choosing
# asynchronous multi-master over a synchronous cluster on a 180ms link.
#
# The account used here (${DB_RO_USER}) holds SELECT only on this schema, so a
# Postfix map-injection bug cannot mutate the mail database.
hosts    = unix:/run/mysqld/mysqld.sock
user     = ${DB_RO_USER}
password = ${DB_RO_PASS}
dbname   = ${DB_NAME}

# smtp_tls_policy_maps
# Per-destination outbound TLS policy, e.g. force "encrypt" to a partner that
# has promised TLS. Stored in the replicated database so both nodes enforce
# the same policy without a file you have to remember to copy.
query = SELECT TRIM(CONCAT(policy, ' ', params)) FROM tls_policy
        WHERE domain = '%s'
          AND active = '1'
