#!/bin/sh
# ha-mail :: /usr/local/bin/hamail-quota-warning.sh
#
# Called by Dovecot's quota-warning service when a mailbox crosses 80% or 95%.
#   $1 = percentage
#   $2 = username (full email address)
#
# The message is injected with dovecot-lda rather than sent through Postfix.
# That keeps the warning entirely inside Dovecot, which means:
#   * it works even if Postfix is stopped
#   * it is written into the user's INBOX on THIS node and then replicated to
#     ${PEER_HOSTNAME} by dsync like any other message, so the user sees
#     exactly one warning regardless of which node they connect to
#   * it can never loop, because it never re-enters the SMTP path
#
# The plugin/quota override disables enforcement for this one delivery.
# Without it, the 95% warning to a mailbox that is already at 100% would
# itself be rejected for being over quota - a genuinely infuriating bug.

set -eu

PCT="$1"
ACCOUNT="$2"

cat <<MESSAGE | /usr/lib/dovecot/dovecot-lda -d "$ACCOUNT" -o "plugin/quota=count:User quota:noenforcing"
From: ${ADMIN_EMAIL}
To: $ACCOUNT
Subject: Mailbox is $PCT% full
Content-Type: text/plain; charset=UTF-8
Auto-Submitted: auto-generated

Your mailbox $ACCOUNT is now $PCT% full.

When it reaches 100% new mail will be rejected and senders will receive a
delivery failure notice.

To free space, permanently delete large messages from Trash and Junk. Messages
in those folders do not count towards your quota, but they do occupy disk.

Webmail: https://${WEBMAIL_HOST}/

--
${DOMAIN} mail system (${SELF_SHORTNAME})
MESSAGE
