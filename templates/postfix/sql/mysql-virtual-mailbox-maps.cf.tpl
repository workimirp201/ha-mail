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

# virtual_mailbox_maps
# Does this exact recipient have a mailbox? The returned maildir value is not
# used for delivery (Dovecot LMTP owns that) - Postfix only needs a non-empty
# result to decide the recipient exists. Returning a value keeps the map
# compatible with a virtual(8) fallback should you ever disable LMTP.
query = SELECT maildir FROM mailbox
        WHERE username = '%s'
          AND active = '1'
