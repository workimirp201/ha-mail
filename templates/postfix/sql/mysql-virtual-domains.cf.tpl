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

# virtual_mailbox_domains #1
# Which domains is this cluster authoritative for?
#   - 'ALL' is PostfixAdmin's superadmin marker row, never a real domain.
#   - backupmx=1 domains are secondary-MX-only and must NOT be treated as
#     local virtual domains, or their mail would be delivered here instead of
#     relayed to the primary.
query = SELECT domain FROM domain
        WHERE domain = '%s'
          AND active = '1'
          AND backupmx = '0'
          AND domain <> 'ALL'
