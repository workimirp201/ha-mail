# ha-mail :: /var/lib/dovecot/sieve/default.sieve
#
# Global "sieve_before" script. Runs on EVERY delivery, on BOTH nodes, before
# the user's own rules.
#
# DETERMINISM IS THE REQUIREMENT HERE.
# Whatever this script does must depend only on the message itself, never on
# node-local state, the clock, or randomness. Both nodes may end up processing
# the same message (for example after a resync), and if they reach different
# conclusions you get two different folder placements for one message and a
# dsync conflict that resolves as a duplicate.
#
# Compile after editing:  sievec /var/lib/dovecot/sieve/default.sieve

require ["fileinto", "mailbox", "imap4flags"];

# rspamd adds X-Spam: Yes above the configured threshold (see
# /etc/rspamd/local.d/milter_headers.conf). File it into Junk rather than
# rejecting at SMTP time: a false positive the user can find beats a false
# positive that bounced.
if header :contains "X-Spam" "Yes" {
    setflag "\\Seen";
    fileinto :create "Junk";
    stop;
}

# Very high scores are quarantined the same way. Nothing is silently
# discarded anywhere in this configuration - a mail server that deletes mail
# without telling anyone is unauditable.
if header :contains "X-Spam-Level" "**********" {
    setflag "\\Seen";
    fileinto :create "Junk";
    stop;
}

# Automated bounce/report traffic out of the INBOX. Optional; comment out if
# your users want to see DMARC reports.
if anyof (
    header :contains "Auto-Submitted" "auto-generated",
    header :is "X-Report-Type" "disposition-notification"
) {
    fileinto :create "Reports";
    stop;
}

# Fall through to the user's own script, then to INBOX.
