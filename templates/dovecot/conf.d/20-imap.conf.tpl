##############################################################################
# ha-mail :: /etc/dovecot/conf.d/20-imap.conf
##############################################################################

protocol imap {
  # imap_quota exposes the GETQUOTAROOT command so clients (and Roundcube)
  # can show a usage bar. imap_sieve lets a user's "mark as spam" action drive
  # a Sieve script that trains the Bayes classifier - see 90-sieve.conf.
  mail_plugins = $mail_plugins imap_quota imap_sieve mail_log

  # Some clients open a very large number of folders at once.
  mail_max_userip_connections = 30

  # Tell an idle client we are alive well before any NAT or CGNAT device on
  # the path decides the connection is dead. Mobile clients on carrier NAT are
  # the reason this is 2 minutes and not the 30-minute default.
  imap_idle_notify_interval = 2 mins

  # Workarounds for MUAs that mis-handle Maildir semantics. tb-extra-mailbox-sep
  # is for Thunderbird; delay-newmail keeps Outlook from re-fetching.
  imap_client_workarounds = delay-newmail tb-extra-mailbox-sep tb-lsub-flags

  # Advertise ID so a client can log which node it reached.
  imap_id_send = name * version *
}
