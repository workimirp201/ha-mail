##############################################################################
# ha-mail :: /etc/dovecot/conf.d/10-master.conf
# Service and listener definitions. Replication services live in
# 95-replication.conf so that the whole HA mechanism is in one file.
##############################################################################

service imap-login {
  inet_listener imap {
    port = 143
  }
  inet_listener imaps {
    port = 993
    ssl = yes
  }
  # Pre-forked login processes. Sized for a small node; raise process_limit
  # before service_count if you see "imap-login: Warning: service(...) is
  # waiting for client connections to be freed".
  service_count = 1
  process_min_avail = 4
  process_limit = 512
  vsz_limit = 128M
}

service imap {
  process_limit = 1024
}

# ---------------------------------------------------------------------------
# LMTP - how Postfix hands mail to Dovecot.
# ---------------------------------------------------------------------------
# The socket is created INSIDE the Postfix queue directory. Postfix runs
# chrooted for most services, so a socket anywhere else is invisible to it.
# Mode 0600 with user=postfix means only Postfix can inject mail - nothing
# else on the box can deliver into a mailbox behind Dovecot's back.
service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
  process_min_avail = 2
  # An LMTP process that also runs Sieve and the replication notify needs
  # more address space than the default.
  vsz_limit = 512M
}

# ---------------------------------------------------------------------------
# AUTH - shared with Postfix.
# ---------------------------------------------------------------------------
service auth {
  # Postfix's SASL socket. Same chroot reasoning as LMTP above.
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }

  # Dovecot's own userdb socket. The vmail user needs it so that doveadm and
  # the replicator can resolve users while running unprivileged.
  unix_listener auth-userdb {
    mode = 0660
    user = ${VMAIL_USER}
    group = ${VMAIL_GROUP}
  }

  # The auth process starts as root only long enough to open the SQL
  # connection and read the config, then drops to this user.
  user = dovecot
}

service auth-worker {
  # ARGON2ID verification is deliberately expensive; workers run it off the
  # main auth process so one slow login cannot stall every other login.
  user = ${VMAIL_USER}
  process_limit = 30
}

service dict {
  unix_listener dict {
    mode = 0660
    user = ${VMAIL_USER}
    group = ${VMAIL_GROUP}
  }
}

service stats {
  unix_listener stats-reader {
    mode = 0660
    user = ${VMAIL_USER}
    group = ${VMAIL_GROUP}
  }
  unix_listener stats-writer {
    mode = 0660
    user = ${VMAIL_USER}
    group = ${VMAIL_GROUP}
  }
}

# Anonymous/POP3 login services are absent because the protocols are not
# enabled in dovecot.conf. Dovecot would simply ignore them, but leaving them
# out keeps `doveconf -n` honest about what this server actually does.
