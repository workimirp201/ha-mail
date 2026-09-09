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

# virtual_alias_maps #1
# Forwards, distribution lists AND catch-alls all live in this one table.
# Postfix looks up 'user@domain' first and, on a miss, automatically retries
# '@domain' - which is exactly how a catch-all row is stored. No second table
# and no special case is needed.
query = SELECT goto FROM alias
        WHERE address = '%s'
          AND active = '1'
