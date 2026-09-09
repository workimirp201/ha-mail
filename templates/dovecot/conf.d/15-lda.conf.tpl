##############################################################################
# ha-mail :: /etc/dovecot/conf.d/15-lda.conf
# Settings shared by the LDA and LMTP delivery paths.
##############################################################################

# Appears as the envelope sender of quota warnings, vacation replies and
# rejection notices. It must be a real, deliverable address.
postmaster_address = ${ADMIN_EMAIL}

# Identifies this node in delivery-related headers and in bounces.
hostname = ${SELF_HOSTNAME}

# Never let Dovecot generate an autoreply/bounce to a message it received
# without a valid envelope sender - that is how a mail server becomes a
# backscatter source.
quota_full_tempfail = yes

# A rejection is emitted by Postfix at SMTP time, not by Dovecot afterwards.
# This keeps every 5xx synchronous and therefore attributable.
lda_mailbox_autocreate = yes
lda_mailbox_autosubscribe = yes

# Deliver through the same binary path Postfix expects.
sendmail_path = /usr/sbin/sendmail
submission_host =

protocol lda {
  mail_plugins = $mail_plugins sieve
}
