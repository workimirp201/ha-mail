#!/bin/sh
# ha-mail :: /usr/lib/dovecot/sieve-pipe/hamail-learn-spam.sh
# Invoked by learn-spam.sieve. Reads the raw message on stdin.
#
# exec is important: it replaces this shell rather than forking, so the
# message is streamed straight into rspamc without an extra copy. rspamc
# talks to the NODE-LOCAL controller on 127.0.0.1.
#
# A training failure must never fail the IMAP operation the user performed,
# so stderr is discarded and the exit status is forced to 0.
exec /usr/bin/rspamc -h 127.0.0.1:11334 learn_spam >/dev/null 2>&1 || exit 0
