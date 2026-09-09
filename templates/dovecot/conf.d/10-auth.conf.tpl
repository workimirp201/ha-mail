##############################################################################
# ha-mail :: /etc/dovecot/conf.d/10-auth.conf
##############################################################################

# Refuse plaintext authentication unless the connection is already encrypted.
# localhost is exempted by Dovecot automatically, which is what lets Postfix
# use the SASL socket without TLS.
disable_plaintext_auth = yes

# PLAIN and LOGIN only. Both send the password in the clear inside the TLS
# tunnel, which is exactly what we want: CRAM-MD5 and DIGEST-MD5 would force
# us to store recoverable passwords in the database, and a database that
# replicates across two continents is the last place to keep those.
auth_mechanisms = plain login

# Usernames are full email addresses, lowercased. %Lu normalises
# "Alice@Example.COM" to "alice@example.com" BEFORE the SQL lookup, so a
# case-varying login cannot create a second home directory - which on a
# replicated pair would show up as a mailbox that exists on one node only.
auth_username_format = %Lu

# Characters permitted in a username. Anything else is rejected before it
# reaches SQL. This is a hard boundary against quote-breaking in the auth
# queries, independent of the driver's own escaping.
auth_username_chars = abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_@+

# Brute-force friction inside Dovecot itself. fail2ban (see
# /etc/fail2ban/jail.d/hamail.conf) does the banning; this makes each attempt
# expensive so that even an unbanned attacker gets very few tries per minute.
auth_failure_delay = 4s
auth_cache_size = 10M
auth_cache_ttl = 1h
auth_cache_negative_ttl = 1m

# Do not fall through to system users. There are none, and a fallback here is
# how a misconfigured server ends up letting "root" authenticate to IMAP.
#!include auth-system.conf.ext
!include auth-sql.conf.ext
