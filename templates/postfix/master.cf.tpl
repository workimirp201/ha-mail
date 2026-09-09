##############################################################################
# ha-mail :: /etc/postfix/master.cf
# Node ${SELF_ROLE} - ${SELF_HOSTNAME}
#
# GENERATED FILE. Edit templates/postfix/master.cf.tpl instead.
#
# Column meaning:
# service type  private unpriv  chroot  wakeup  maxproc command + args
#               (yes)   (yes)   (no)    (never) (100)
##############################################################################

# ===========================================================================
# PORT 25 - inbound mail from the internet, fronted by postscreen.
# ===========================================================================
# postscreen holds the socket, runs the cheap tests (greeting delay, DNSBL),
# and only then hands the connection to a real smtpd via the "smtpd pass"
# service below. This keeps zombie traffic away from the expensive processes.
smtp       inet  n       -       y       -       1       postscreen

smtpd      pass  -       -       y       -       -       smtpd
    -o syslog_name=postfix/25
    -o cleanup_service_name=cleanup

dnsblog    unix  -       -       y       -       0       dnsblog
tlsproxy   unix  -       -       y       -       0       tlsproxy

# ===========================================================================
# PORT 587 - SUBMISSION (STARTTLS, authentication mandatory)
# ===========================================================================
# Every restriction is overridden here rather than inherited, because the rules
# that make sense for anonymous internet mail are wrong for a known user:
#   - TLS is mandatory, not opportunistic
#   - SASL is mandatory
#   - postscreen/DNSBL never applies (a user on a blacklisted cafe IP must
#     still be able to send)
#   - the sender/login map is enforced so nobody can spoof a colleague
submission inet  n       -       y       -       -       smtpd
    -o syslog_name=postfix/submission
    -o smtpd_tls_security_level=encrypt
    -o smtpd_tls_auth_only=yes
    -o smtpd_sasl_auth_enable=yes
    -o smtpd_sasl_type=dovecot
    -o smtpd_sasl_path=private/auth
    -o smtpd_sasl_security_options=noanonymous
    -o smtpd_sasl_tls_security_options=noanonymous
    -o smtpd_client_restrictions=permit_sasl_authenticated,reject
    -o smtpd_helo_restrictions=
    -o smtpd_sender_restrictions=reject_sender_login_mismatch,permit_sasl_authenticated,reject
    -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
    -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
    -o smtpd_data_restrictions=reject_unauth_pipelining
    -o milter_macro_daemon_name=ORIGINATING
    -o cleanup_service_name=submission-cleanup
    -o smtpd_client_connection_count_limit=20
    -o smtpd_client_message_rate_limit=100

# ===========================================================================
# PORT 465 - SMTPS (implicit TLS). Identical policy to 587.
# ===========================================================================
smtps      inet  n       -       y       -       -       smtpd
    -o syslog_name=postfix/smtps
    -o smtpd_tls_wrappermode=yes
    -o smtpd_tls_security_level=encrypt
    -o smtpd_sasl_auth_enable=yes
    -o smtpd_sasl_type=dovecot
    -o smtpd_sasl_path=private/auth
    -o smtpd_sasl_security_options=noanonymous
    -o smtpd_sasl_tls_security_options=noanonymous
    -o smtpd_client_restrictions=permit_sasl_authenticated,reject
    -o smtpd_helo_restrictions=
    -o smtpd_sender_restrictions=reject_sender_login_mismatch,permit_sasl_authenticated,reject
    -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
    -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
    -o smtpd_data_restrictions=reject_unauth_pipelining
    -o milter_macro_daemon_name=ORIGINATING
    -o cleanup_service_name=submission-cleanup
    -o smtpd_client_connection_count_limit=20
    -o smtpd_client_message_rate_limit=100

# ===========================================================================
# Core Postfix plumbing
# ===========================================================================
pickup     unix  n       -       y       60      1       pickup
cleanup    unix  n       -       y       -       0       cleanup
qmgr       unix  n       -       n       300     1       qmgr
tlsmgr     unix  -       -       y       1000?   1       tlsmgr
rewrite    unix  -       -       y       -       -       trivial-rewrite
bounce     unix  -       -       y       -       0       bounce
defer      unix  -       -       y       -       0       bounce
trace      unix  -       -       y       -       0       bounce
verify     unix  -       -       y       -       1       verify
flush      unix  n       -       y       1000?   0       flush
proxymap   unix  -       -       n       -       -       proxymap
proxywrite unix  -       -       n       -       1       proxymap
smtp       unix  -       -       y       -       -       smtp
relay      unix  -       -       y       -       -       smtp
    -o syslog_name=postfix/relay
showq      unix  n       -       y       -       -       showq
error      unix  -       -       y       -       -       error
retry      unix  -       -       y       -       -       error
discard    unix  -       -       y       -       -       discard
local      unix  -       n       n       -       -       local
virtual    unix  -       n       n       -       -       virtual
lmtp       unix  -       -       y       -       -       lmtp
anvil      unix  -       -       y       -       1       anvil
scache     unix  -       -       y       -       1       scache
postlog    unix-dgram n  -       n       -       1       postlogd

# ===========================================================================
# submission-cleanup
# ===========================================================================
# A dedicated cleanup instance for user-submitted mail. It is the ONLY place
# header_checks that strip the client's IP are applied, so that inbound mail
# keeps its full Received: chain (needed for abuse investigation) while
# outbound mail does not leak a user's home/hotel IP address.
submission-cleanup unix n -       y       -       0       cleanup
    -o syslog_name=postfix/sub-cleanup
    -o header_checks=regexp:/etc/postfix/submission_header_cleanup

# ===========================================================================
# policyd-spf - SPF checking for INBOUND mail.
# ===========================================================================
# max_idle/max_use keep the python process from accumulating state; the
# 3600s time limit is the documented requirement for this policy daemon.
policyd-spf unix -       n       n       -       0       spawn
    user=policyd-spf argv=/usr/bin/policyd-spf

# ===========================================================================
# Dovecot LMTP is reached over a UNIX socket that Dovecot creates inside the
# Postfix queue (see 20-lmtp.conf), so no service definition is needed here.
# Kept for reference / debugging with a TCP LMTP fallback:
#
# dovecot   unix  -       n       n       -       -       lmtp
#     -o flags=DRhu user=${VMAIL_USER}:${VMAIL_GROUP}
# ===========================================================================

# ===========================================================================
# maildrop / uucp / ifmail / bsmtp / scalemail / mailman
# Deliberately NOT enabled. Every one of them is a local-delivery agent this
# cluster does not use, and each is a historic source of command injection in
# a virtual-domain setup.
# ===========================================================================
