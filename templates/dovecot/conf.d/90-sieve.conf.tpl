##############################################################################
# ha-mail :: /etc/dovecot/conf.d/90-sieve.conf
##############################################################################

plugin {
  # The user's own script, editable through Roundcube's ManageSieve UI. It
  # lives in the user's home, so dsync replicates it along with their mail -
  # a filter created on Node ${SELF_ROLE} is live on Node ${PEER_ROLE} within
  # seconds, with no separate synchronisation mechanism.
  sieve = file:${VMAIL_ROOT}/%d/%n/sieve;active=${VMAIL_ROOT}/%d/%n/.dovecot.sieve

  # Compiled bytecode cache directory.
  sieve_dir = ${VMAIL_ROOT}/%d/%n/sieve

  # Runs BEFORE the user's script: files rspamd-flagged spam into Junk. Being
  # "before" means a user's own rules cannot accidentally pull spam back into
  # the INBOX, and being global means both nodes apply the identical rule to
  # the identical message and reach the identical result.
  sieve_before = /var/lib/dovecot/sieve/default.sieve

  # Resource ceilings. A runaway script on one node would otherwise generate
  # mailbox churn that the replicator then has to carry across the ocean.
  sieve_max_script_size = 1M
  sieve_max_actions = 32
  sieve_max_redirects = 4
  sieve_quota_max_scripts = 20
  sieve_quota_max_storage = 10M

  # ---------------------------------------------------------------------
  # imap_sieve: user-driven Bayes training.
  # ---------------------------------------------------------------------
  # Moving a message into Junk trains rspamd's classifier as spam; moving it
  # out trains it as ham. The training data lives in the NODE-LOCAL Redis, so
  # the two nodes' classifiers drift apart slightly over time. That is
  # accepted deliberately: replicating Bayes tokens across a 180ms link buys
  # very little accuracy and adds a stateful cross-node dependency to the spam
  # path. See docs/AUDIT.md section 6.
  sieve_plugins = sieve_imapsieve sieve_extprograms

  imapsieve_mailbox1_name = Junk
  imapsieve_mailbox1_causes = COPY
  imapsieve_mailbox1_before = file:/var/lib/dovecot/sieve/learn-spam.sieve

  imapsieve_mailbox2_name = *
  imapsieve_mailbox2_from = Junk
  imapsieve_mailbox2_causes = COPY
  imapsieve_mailbox2_before = file:/var/lib/dovecot/sieve/learn-ham.sieve

  sieve_pipe_bin_dir = /usr/lib/dovecot/sieve-pipe
  sieve_global_extensions = +vnd.dovecot.pipe +vnd.dovecot.environment
}
