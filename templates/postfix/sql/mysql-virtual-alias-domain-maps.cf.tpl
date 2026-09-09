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

# virtual_alias_maps #2
# Resolve user@alias-domain -> whatever user@target-domain resolves to.
# %u = local part, %d = domain part of the lookup key.
query = SELECT alias.goto FROM alias
        JOIN alias_domain ON alias.address = CONCAT('%u', '@', alias_domain.target_domain)
        WHERE alias_domain.alias_domain = '%d'
          AND alias.active = '1'
          AND alias_domain.active = '1'
