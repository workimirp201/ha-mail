# ha-mail :: /var/lib/dovecot/sieve/learn-spam.sieve
#
# Fired by imap_sieve when a user COPIES or MOVES a message into Junk.
# Trains this node's rspamd Bayes classifier that the message is spam.
#
# Node-local by design: the classifier lives in the node-local Redis. The two
# nodes' Bayes databases drift apart over time and that is accepted - see
# docs/AUDIT.md section 6.

require ["vnd.dovecot.pipe", "copy", "imapsieve", "environment", "variables"];

if environment :matches "imap.user" "*" {
    set "username" "${1}";
}

pipe :copy "hamail-learn-spam.sh" [ "${username}" ];
