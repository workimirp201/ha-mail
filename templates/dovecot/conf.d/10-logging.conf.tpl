##############################################################################
# ha-mail :: /etc/dovecot/conf.d/10-logging.conf
##############################################################################

# Everything to syslog; journald and rsyslog both pick it up, and fail2ban
# reads /var/log/mail.log.
log_path = syslog
info_log_path = syslog
debug_log_path = syslog
syslog_facility = mail

# Per-session summary lines. These are what let you answer "which node did
# this client talk to, and did replication fire?" from the log alone.
log_timestamp = "%Y-%m-%d %H:%M:%S "

# A single line per finished IMAP session, with byte counts. Cheap, and
# invaluable during a failover drill.
login_log_format_elements = user=<%u> method=%m rip=%r lip=%l mpid=%e %c session=<%{session}>

# Include the node name so that when both nodes' logs end up in the same
# aggregator you can still tell them apart.
mail_log_prefix = "%s(%u)<%{pid}><%{session}> ${SELF_SHORTNAME}: "

# The mail_log plugin (loaded per-protocol below where relevant) is what makes
# expunges auditable. On a replicated pair, "who deleted this and on which
# node" is the first question asked after any suspected data loss.
plugin {
  mail_log_events = delete undelete expunge copy mailbox_delete mailbox_rename flag_change
  mail_log_fields = uid box msgid size from subject flags
}

# Turn these on only while debugging replication; they are extremely verbose.
#mail_debug = yes
#auth_debug = yes
#auth_verbose = yes
auth_verbose = yes
auth_verbose_passwords = no
verbose_ssl = no
