# ha-mail :: /var/lib/dovecot/sieve/learn-ham.sieve
#
# Fired by imap_sieve when a user moves a message OUT of Junk - the signal
# that the classifier got it wrong. Trains it as ham.

require ["vnd.dovecot.pipe", "copy", "imapsieve", "environment", "variables"];

if environment :matches "imap.mailbox" "*" {
    set "mailbox" "${1}";
}

# Moving into Trash is not an endorsement - the user is deleting spam, not
# telling us it was legitimate. Training on it would poison the classifier.
if string "${mailbox}" "Trash" {
    stop;
}

if environment :matches "imap.user" "*" {
    set "username" "${1}";
}

pipe :copy "hamail-learn-ham.sh" [ "${username}" ];
