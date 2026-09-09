##############################################################################
# ha-mail :: /etc/dovecot/conf.d/90-quota.conf
##############################################################################

plugin {
  # ---------------------------------------------------------------------
  # BACKEND: count, not dict.
  # ---------------------------------------------------------------------
  # The `count` backend derives usage from Dovecot's own mailbox indexes. It
  # touches no database at all, which matters here for two reasons:
  #
  #   1. Quota enforcement keeps working when MariaDB is busy applying a
  #      replication backlog, or is down entirely.
  #   2. There is no shared row for the two nodes to fight over. With the
  #      `dict` backend as the authority, every delivery on either node is an
  #      UPDATE against the same primary key, and two deliveries seconds apart
  #      on opposite sides of a 180ms link race with each other.
  #
  # quota_vsizes = yes makes `count` measure RFC822 message size (what the
  # user thinks of as the message size) rather than on-disk size, so the
  # number matches what the admin portal shows.
  quota = count:User quota
  quota_vsizes = yes

  # Default rule. The real per-user value arrives from SQL as userdb_quota_rule
  # and overrides this. 0 = unlimited.
  quota_rule = *:storage=${DEFAULT_QUOTA_BYTES}B

  # Trash and Junk do not count against the quota, so a user who is over quota
  # can still delete their way out of it. Without this, an over-quota mailbox
  # is a deadlock: you cannot move mail to Trash because Trash is full.
  quota_rule2 = Trash:ignore
  quota_rule3 = Junk:ignore

  # Warn the user before they hit the wall.
  quota_warning = storage=95%% quota-warning 95 %u
  quota_warning2 = storage=80%% quota-warning 80 %u

  # ---------------------------------------------------------------------
  # quota_clone: mirror the computed value into SQL for the portal's UI.
  # ---------------------------------------------------------------------
  # Purely cosmetic. The target table (quota2) is excluded from replication;
  # each node writes its own copy. If this write fails, delivery still
  # succeeds - the clone plugin is best-effort by design.
  quota_clone_dict = proxy::quota

  # Status service replies used by Postfix's quota policy check.
  quota_status_success = DUNNO
  quota_status_nouser = DUNNO
  quota_status_overquota = "552 5.2.2 Mailbox is over quota"
}

service quota-warning {
  executable = script /usr/local/bin/hamail-quota-warning.sh
  user = ${VMAIL_USER}
  unix_listener quota-warning {
    mode = 0660
    group = ${VMAIL_GROUP}
  }
}

# Optional: lets Postfix reject over-quota recipients at RCPT TO instead of
# accepting the message and bouncing it afterwards.
service quota-status {
  executable = quota-status -p postfix
  unix_listener quota-status {
    mode = 0660
    user = postfix
    group = postfix
  }
}
