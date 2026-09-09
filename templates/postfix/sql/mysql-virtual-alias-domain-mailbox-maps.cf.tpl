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

# virtual_mailbox_maps #2
# A real mailbox reached through a domain alias. Without this map, mail to
# user@alias-domain is rejected as an unknown recipient whenever there is no
# explicit alias row for it.
query = SELECT mailbox.maildir FROM mailbox
        JOIN alias_domain ON mailbox.username = CONCAT('%u', '@', alias_domain.target_domain)
        WHERE alias_domain.alias_domain = '%d'
          AND mailbox.active = '1'
          AND alias_domain.active = '1'
