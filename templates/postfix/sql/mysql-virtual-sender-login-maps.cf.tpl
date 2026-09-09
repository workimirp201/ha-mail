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

# smtpd_sender_login_maps
# "Which SASL logins are allowed to put this address in MAIL FROM?"
#
# Combined with reject_sender_login_mismatch this is the control that stops
# one tenant on the cluster from spoofing another. It matters far more here
# than on a single-tenant server, because a spoofed message would be signed
# with OUR DKIM key and would therefore pass DMARC at the recipient.
#
# Two sources, unioned:
#   1. the mailbox itself (alice@d.tld may send as alice@d.tld)
#   2. any alias that delivers to a mailbox (sales@d.tld -> alice@d.tld means
#      alice may send as sales@d.tld)
query = SELECT username FROM mailbox
        WHERE username = '%s' AND active = '1'
        UNION
        SELECT goto FROM alias
        WHERE address = '%s' AND active = '1'
