##############################################################################
# ha-mail :: /etc/dovecot/conf.d/20-lmtp.conf
# The delivery path. Postfix hands every virtual message to this service.
##############################################################################

protocol lmtp {
  # sieve runs the user's filters; mail_log records the delivery; notify +
  # replication (inherited from mail_plugins) are what cause the newly saved
  # message to be queued for dsync to ${PEER_HOSTNAME} within milliseconds.
  mail_plugins = $mail_plugins sieve mail_log

  postmaster_address = ${ADMIN_EMAIL}

  # Address extensions: mail to alice+invoices@ is filed into the "invoices"
  # folder if it exists, and falls back to INBOX if it does not. Must match
  # Postfix's recipient_delimiter setting.
  recipient_delimiter = +
  lmtp_save_to_detail_mailbox = yes

  # Rewrite the recipient to the canonical mailbox address before delivery, so
  # that an alias-delivered message is filed under the real account and both
  # nodes agree on which mailbox it belongs to.
  lmtp_rcpt_check_quota = yes

  # Do NOT enable lmtp_proxy. Proxying delivery to the peer would make every
  # inbound message depend on the tunnel being up, which is precisely the
  # single point of failure this architecture exists to remove.
}
