##############################################################################
# ha-mail :: /etc/fail2ban/jail.d/hamail.conf
# Node ${SELF_ROLE} - ${SELF_HOSTNAME}
#
# Layer 2 of the brute-force defence (layer 1 = nginx limit_req, layer 3 = the
# applications' own throttles).
#
# THE ONE RULE YOU MUST NOT BREAK ON A TWO-NODE CLUSTER
# ---------------------------------------------------
# ignoreip MUST contain the peer's public address, the peer's tunnel address
# and the whole tunnel subnet. Without it:
#   * cert-sync's SSH connections look like an SSH brute force
#   * MariaDB replication reconnects look like a login flood
#   * a dsync storm after an outage looks like an IMAP attack
# ...and the surviving node bans its partner at the exact moment the cluster is
# trying to heal. This is the single most common self-inflicted outage in an
# HA mail pair.
##############################################################################

[DEFAULT]
# Ban at the firewall, not in the application.
banaction = ufw
banaction_allports = ufw

# The peer, loopback, and the tunnel. NEVER remove these.
ignoreip = 127.0.0.1/8 ::1 ${NODE_A_IP} ${NODE_B_IP} ${WG_SUBNET}

# Progressive: 1 hour for a first offence, escalating via the recidive jail.
bantime = 1h
findtime = 10m
maxretry = 5

# Report bans to the operator, not to the (usually forged) abuse contact.
destemail = ${ALERT_EMAIL}
sender = fail2ban@${SELF_HOSTNAME}
action = %(action_)s

# ---------------------------------------------------------------------------
# BACKEND: `auto`, NOT `systemd`.
# ---------------------------------------------------------------------------
# A global `backend = systemd` makes fail2ban IGNORE every `logpath` and read
# the journal instead. The jails below that watch FILES - the nginx access and
# error logs, Roundcube's errors.log, fail2ban's own log - then have no log
# source at all. They still appear in `fail2ban-client status` as active
# jails, and they never see a single line.
#
# Verify with:   fail2ban-client -d | grep addlogpath
# If that prints nothing, every file-based jail on this host is decorative.
#
# So: `auto` here, and `backend = systemd` set explicitly on the jails whose
# services log through syslog/journald (Postfix, Dovecot, sshd).
backend = auto

[sshd]
enabled = true
backend = systemd
port = ${SSH_PORT}
mode = aggressive
maxretry = 4
bantime = 4h

# ---------------------------------------------------------------------------
# SMTP
# ---------------------------------------------------------------------------
[postfix]
enabled = true
backend = systemd
mode = aggressive
port = smtp,465,submission

[postfix-sasl]
enabled = true
backend = systemd
port = smtp,465,submission
maxretry = 4
bantime = 6h

[postfix-rbl]
enabled = false
# Off by default: postscreen already enforces the DNSBLs, and banning on an
# RBL hit means a shared-IP sender that gets listed once is locked out for
# hours after the listing clears.

# ---------------------------------------------------------------------------
# IMAP / submission auth
# ---------------------------------------------------------------------------
[dovecot]
enabled = true
backend = systemd
port = imap,imaps,submission,465,sieve
maxretry = 5
bantime = 4h

# Custom filter that also catches the dsync/doveadm auth failures a
# misconfigured peer produces - so you find out from a ban log instead of from
# silently stalled replication.
[dovecot-hamail]
enabled = true
filter = dovecot-hamail
backend = systemd
port = imap,imaps,submission,465,sieve,${DOVEADM_PORT}
maxretry = 8
findtime = 20m
bantime = 2h

# ---------------------------------------------------------------------------
# Web
# ---------------------------------------------------------------------------
[postfixadmin]
enabled = true
backend = auto
filter = postfixadmin
port = http,https
logpath = /var/log/nginx/admin-access.log
maxretry = 4
findtime = 10m
bantime = 12h

[roundcube-auth]
enabled = true
backend = auto
filter = roundcube-auth
port = http,https
logpath = ${ROUNDCUBE_ROOT}/logs/errors.log
maxretry = 6
findtime = 10m
bantime = 4h

[nginx-limit-req]
enabled = true
backend = auto
port = http,https
logpath = /var/log/nginx/error.log
          /var/log/nginx/webmail-error.log
          /var/log/nginx/admin-error.log
maxretry = 20
findtime = 5m
bantime = 1h

[nginx-bad-request]
enabled = true
backend = auto
port = http,https
logpath = /var/log/nginx/access.log
maxretry = 20

# ---------------------------------------------------------------------------
# recidive: bans repeat offenders across every jail above.
# ---------------------------------------------------------------------------
[recidive]
enabled = true
backend = auto
logpath = /var/log/fail2ban.log
banaction = ufw
bantime = 7d
findtime = 1d
maxretry = 4
