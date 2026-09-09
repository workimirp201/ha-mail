#!/bin/sh
# ha-mail :: /usr/lib/dovecot/sieve-pipe/hamail-learn-ham.sh
# Invoked by learn-ham.sieve. Reads the raw message on stdin.
exec /usr/bin/rspamc -h 127.0.0.1:11334 learn_ham >/dev/null 2>&1 || exit 0
