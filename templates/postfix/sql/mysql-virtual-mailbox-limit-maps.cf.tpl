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

# virtual_mailbox_limit_maps (optional)
# Per-mailbox size ceiling in bytes. Dovecot is the authority on quota - this
# map only lets Postfix reject an over-quota recipient at RCPT TO instead of
# accepting and then bouncing, which is friendlier to legitimate senders.
query = SELECT quota FROM mailbox
        WHERE username = '%s'
          AND active = '1'
          AND quota > 0
