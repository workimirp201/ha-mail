##############################################################################
# ha-mail :: /etc/rspamd/local.d/worker-controller.inc
#
# Web UI, statistics and the learn_spam/learn_ham endpoints used by the
# imap_sieve training scripts.
#
# Bound to 127.0.0.1 ONLY. Reach it through an SSH tunnel:
#     ssh -L 11334:127.0.0.1:${RSPAMD_WEB_PORT} root@${SELF_IP}
#     then open http://127.0.0.1:11334/
#
# Exposing this interface publicly - even behind HTTP basic auth - hands an
# attacker a message-injection and configuration-read surface, and the
# password below is stored as a recoverable hash by design so that rspamc can
# use it locally.
##############################################################################

bind_socket = "127.0.0.1:${RSPAMD_WEB_PORT}";

# Generated with `rspamadm pw --encrypt -p <RSPAMD_PASS>` by
# scripts/70-rspamd-dkim.sh, so the plaintext never reaches this file.
password = "${RSPAMD_PASS_HASH}";
enable_password = "${RSPAMD_PASS_HASH}";

# Loopback is trusted so that rspamc (and therefore the Sieve training hooks)
# can learn without carrying a password.
secure_ip = "127.0.0.1";
secure_ip = "::1";

