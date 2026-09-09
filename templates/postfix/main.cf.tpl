##############################################################################
# ha-mail :: /etc/postfix/main.cf
# Node ${SELF_ROLE} - ${SELF_HOSTNAME} (${SELF_IP}, ${SELF_REGION})
#
# GENERATED FILE. Edit templates/postfix/main.cf.tpl instead.
#
# Both nodes are full peers: each is an authoritative MX for every hosted
# domain, each accepts submission, each delivers into its own Dovecot over
# LMTP, and Dovecot replication carries the resulting message to the other
# side. No message is ever relayed node-to-node, which means a dead peer costs
# nothing at delivery time.
##############################################################################

# ---------------------------------------------------------------------------
# Compatibility level. Pinning this stops a future Postfix upgrade from
# silently changing defaults underneath a working mail cluster.
# ---------------------------------------------------------------------------
compatibility_level = 3.6

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------
myhostname = ${SELF_HOSTNAME}
mydomain = ${DOMAIN}

# Locally generated mail (cron, logwatch) is from the node itself, never from
# the virtual domain - otherwise system noise gets DKIM-signed as a real user.
myorigin = $myhostname

# mydestination MUST NOT contain any virtual domain. If ${DOMAIN} appeared
# here Postfix would treat it as a local UNIX-account domain and every virtual
# lookup would be bypassed ("User unknown in local recipient table").
mydestination = $myhostname, localhost.$mydomain, localhost

# Deliver root/postmaster system mail to a real person.
alias_maps = hash:/etc/aliases
alias_database = hash:/etc/aliases
local_recipient_maps = proxy:unix:passwd.byname $alias_maps

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------
inet_interfaces = all
inet_protocols = ipv4

# Pin the outbound source address. This is the single most important line for
# SPF and PTR alignment on a multi-homed node: without it Postfix may source
# outbound SMTP from the WireGuard address or a secondary IP, and every
# recipient sees an IP that is neither in the SPF record nor has the right
# reverse DNS. See docs/AUDIT.md section 3.
smtp_bind_address = ${SELF_IP}

# mynetworks is deliberately minimal. The peer's tunnel address is NOT trusted
# for relaying - the two nodes never relay for each other, they each accept
# from the internet independently. Trusting the peer here would turn a single
# compromised node into an open relay for the pair.
mynetworks_style = host
mynetworks = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128

# ---------------------------------------------------------------------------
# Limits
# ---------------------------------------------------------------------------
message_size_limit = 52428800
mailbox_size_limit = 0
virtual_mailbox_limit = 0
recipient_delimiter = +
smtputf8_enable = yes
biff = no
append_dot_mydomain = no
readme_directory = no
html_directory = no
sample_directory = no
setgid_group = postdrop
command_directory = /usr/sbin
daemon_directory = /usr/lib/postfix/sbin
data_directory = /var/lib/postfix
mail_owner = postfix
queue_directory = /var/spool/postfix
manpage_directory = /usr/share/man
newaliases_path = /usr/bin/newaliases
mailq_path = /usr/bin/mailq
sendmail_path = /usr/sbin/sendmail

# ---------------------------------------------------------------------------
# Queue behaviour on a two-node cluster
# ---------------------------------------------------------------------------
# Retry quickly at first (a peer node reboot should not delay mail by an hour)
# but give up after 3 days as per RFC 5321 guidance.
maximal_queue_lifetime = 3d
bounce_queue_lifetime = 3d
minimal_backoff_time = 120s
maximal_backoff_time = 1800s
queue_run_delay = 120s
# Warn the sender if a message is still queued after 4 hours.
delay_warning_time = 4h

# ---------------------------------------------------------------------------
# VIRTUAL DOMAINS / MAILBOXES / ALIASES
# ---------------------------------------------------------------------------
# Every map below points at the LOCAL MariaDB replica over the UNIX socket.
# A node never queries its peer's database: if the tunnel is down, mail keeps
# flowing using the last replicated state. This is the whole point of async
# multi-master over a WAN link.
# ---------------------------------------------------------------------------
virtual_mailbox_domains =
    proxy:mysql:/etc/postfix/sql/mysql-virtual-domains.cf
    proxy:mysql:/etc/postfix/sql/mysql-virtual-alias-domains.cf

virtual_mailbox_maps =
    proxy:mysql:/etc/postfix/sql/mysql-virtual-mailbox-maps.cf
    proxy:mysql:/etc/postfix/sql/mysql-virtual-alias-domain-mailbox-maps.cf

virtual_alias_maps =
    proxy:mysql:/etc/postfix/sql/mysql-virtual-alias-maps.cf
    proxy:mysql:/etc/postfix/sql/mysql-virtual-alias-domain-maps.cf
    proxy:mysql:/etc/postfix/sql/mysql-virtual-alias-domain-catchall-maps.cf

# Delivery is handed to Dovecot's LMTP over a UNIX socket. Dovecot then owns
# quota enforcement, Sieve filtering, and - critically - it is Dovecot that
# emits the replication notification for the new message.
virtual_transport = lmtp:unix:private/dovecot-lmtp
virtual_mailbox_base = ${VMAIL_ROOT}
virtual_uid_maps = static:${VMAIL_UID}
virtual_gid_maps = static:${VMAIL_GID}
virtual_minimum_uid = 100

# LMTP tuning: quota-exceeded and 5xx from Dovecot must be reported honestly.
lmtp_destination_recipient_limit = 50
virtual_destination_recipient_limit = 50
# proxymap keeps the number of open MySQL connections bounded regardless of
# how many smtpd processes are running. Without it a burst of connections
# opens one MySQL handle per process per map - roughly 100 x 8 handles.
proxy_read_maps =
    $canonical_maps $lmtp_generic_maps $local_recipient_maps
    $mydestination $recipient_bcc_maps $recipient_canonical_maps
    $relay_domains $relay_recipient_maps $relocated_maps
    $sender_bcc_maps $sender_canonical_maps $smtp_generic_maps
    $smtpd_sender_login_maps $transport_maps $virtual_alias_domains
    $virtual_alias_maps $virtual_mailbox_domains $virtual_mailbox_maps
    $smtpd_sender_restrictions

# ---------------------------------------------------------------------------
# TLS - INBOUND (smtpd)
# ---------------------------------------------------------------------------
smtpd_tls_cert_file = ${CERT_LIVE}/fullchain.pem
smtpd_tls_key_file = ${CERT_LIVE}/privkey.pem
smtpd_tls_CAfile = ${CERT_LIVE}/chain.pem

# Opportunistic on port 25 (mandatory TLS on 25 would silently drop mail from
# the many senders that still cannot do it). Enforced on 587/465 in master.cf.
smtpd_tls_security_level = may
smtpd_tls_auth_only = yes

smtpd_tls_mandatory_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtpd_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtpd_tls_mandatory_ciphers = high
smtpd_tls_ciphers = high
tls_high_cipherlist = ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256
tls_preempt_cipherlist = no
smtpd_tls_dh1024_param_file = /etc/postfix/dh${DH_BITS}.pem
smtpd_tls_eecdh_grade = auto
smtpd_tls_session_cache_database = btree:${data_directory}/smtpd_scache
smtpd_tls_loglevel = 1
smtpd_tls_received_header = yes

# SNI map: lets a node present the correct certificate when a user of a second
# hosted domain connects to mail.<their-domain> instead of ${MAIL_HOST}.
# Regenerate with bin/sni-map.sh after issuing a certificate for a new domain.
tls_server_sni_maps = hash:/etc/postfix/vmail_ssl.map

# ---------------------------------------------------------------------------
# TLS - OUTBOUND (smtp)
# ---------------------------------------------------------------------------
# "may" = opportunistic TLS: use it whenever the remote offers it, never bounce
# when it does not. DANE ("dane") is strictly better but REQUIRES a local
# DNSSEC-validating resolver; with Linode's default resolvers Postfix silently
# degrades to "may" anyway and fills the log with warnings. To enable DANE
# properly: apt install unbound, point /etc/resolv.conf at 127.0.0.1, then set
#     smtp_tls_security_level = dane
#     smtp_dns_support_level = dnssec
smtp_tls_security_level = may
smtp_tls_mandatory_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtp_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtp_tls_mandatory_ciphers = high
smtp_tls_CApath = /etc/ssl/certs
smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt
smtp_tls_session_cache_database = btree:${data_directory}/smtp_scache
smtp_tls_loglevel = 1
smtp_tls_note_starttls_offer = yes
# Per-destination overrides (e.g. forcing "encrypt" for a partner domain) live
# in the database so they replicate with everything else.
smtp_tls_policy_maps = proxy:mysql:/etc/postfix/sql/mysql-tls-policy.cf

# ---------------------------------------------------------------------------
# SASL - authentication is delegated entirely to Dovecot.
# ---------------------------------------------------------------------------
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_auth_enable = yes
smtpd_sasl_security_options = noanonymous
smtpd_sasl_tls_security_options = noanonymous
smtpd_sasl_local_domain = $mydomain
broken_sasl_auth_clients = yes
smtpd_sasl_authenticated_header = no

# An authenticated user may only send as an address they actually own. Without
# this, any mailbox on the cluster can spoof the CEO, and because the message
# would then be legitimately DKIM-signed by us it would sail through DMARC.
smtpd_sender_login_maps =
    proxy:mysql:/etc/postfix/sql/mysql-virtual-sender-login-maps.cf

# ---------------------------------------------------------------------------
# RESTRICTIONS
# ---------------------------------------------------------------------------
# Evaluated at the point Postfix first has enough information; smtpd_delay_reject
# keeps everything until RCPT TO so rejections carry a useful recipient.
smtpd_delay_reject = yes
smtpd_helo_required = yes
disable_vrfy_command = yes
strict_rfc821_envelopes = yes

smtpd_client_restrictions =
    permit_mynetworks
    permit_sasl_authenticated
    reject_unknown_client_hostname
    permit

smtpd_helo_restrictions =
    permit_mynetworks
    permit_sasl_authenticated
    reject_invalid_helo_hostname
    reject_non_fqdn_helo_hostname
    permit

smtpd_sender_restrictions =
    permit_mynetworks
    reject_sender_login_mismatch
    permit_sasl_authenticated
    reject_non_fqdn_sender
    reject_unknown_sender_domain
    permit

# relay_restrictions is the anti-open-relay gate and is evaluated BEFORE
# recipient_restrictions. Keeping reject_unauth_destination here (and not
# buried at the end of recipient_restrictions) is what makes an accidental
# "permit" later in the list harmless.
smtpd_relay_restrictions =
    permit_mynetworks
    permit_sasl_authenticated
    reject_unauth_destination

smtpd_recipient_restrictions =
    permit_mynetworks
    permit_sasl_authenticated
    reject_non_fqdn_recipient
    reject_unknown_recipient_domain
    reject_unlisted_recipient
    check_policy_service unix:private/policyd-spf
    permit

smtpd_data_restrictions =
    reject_unauth_pipelining

# SPF policy daemon timeout - it must never hold an smtpd process hostage.
policyd-spf_time_limit = 3600

# ---------------------------------------------------------------------------
# MILTERS - rspamd does spam scoring, DKIM signing and ARC sealing.
# ---------------------------------------------------------------------------
# _accept_ on failure is deliberate: if rspamd dies, mail must keep flowing
# unsigned rather than bouncing. A cluster that refuses mail because its spam
# filter crashed has converted a nuisance into an outage.
milter_protocol = 6
milter_default_action = accept
milter_mail_macros = i {mail_addr} {client_addr} {client_name} {auth_authen}
smtpd_milters = inet:127.0.0.1:11332
non_smtpd_milters = inet:127.0.0.1:11332
milter_connect_timeout = 20s
milter_command_timeout = 30s
milter_content_timeout = 120s

# ---------------------------------------------------------------------------
# HEADER HYGIENE
# ---------------------------------------------------------------------------
# Strip internal Received: headers and the client's private IP from mail our
# own users submit, so that ${SELF_IP} is the only hop a recipient sees. This
# also stops a laptop's RFC1918 address leaking into every outgoing message.
smtp_header_checks = regexp:/etc/postfix/header_checks

# ---------------------------------------------------------------------------
# POSTSCREEN - cheap pre-filter on port 25 only. It never applies to
# submission (587/465), so a legitimate user on a blacklisted hotel IP can
# still send mail.
# ---------------------------------------------------------------------------
postscreen_access_list = permit_mynetworks
postscreen_greet_action = enforce
postscreen_dnsbl_action = enforce
postscreen_dnsbl_threshold = 3
postscreen_dnsbl_sites =
    zen.spamhaus.org*3
    bl.spamcop.net*2
    b.barracudacentral.org*2
    list.dnswl.org=127.0.[0..255].0*-2
    list.dnswl.org=127.0.[0..255].1*-4
    list.dnswl.org=127.0.[0..255].2*-6
    list.dnswl.org=127.0.[0..255].3*-8
postscreen_dnsbl_whitelist_threshold = -2
postscreen_greet_banner = $smtpd_banner
postscreen_cache_map = btree:$data_directory/postscreen_cache
# Deep protocol tests are disabled: they defer the first delivery from every
# new sender, and on a two-MX setup that just pushes the sender to the other
# node where it starts over.
postscreen_pipelining_enable = no
postscreen_non_smtp_command_enable = no
postscreen_bare_newline_enable = no

# NOTE: zen.spamhaus.org requires a free Data Query Service key above ~100k
# queries/day. If you exceed the free tier, replace the hostname with
# <your-key>.zen.dq.spamhaus.net or remove the line; leaving an unauthorised
# query in place returns 127.255.255.x which postscreen treats as a hit and
# you will reject legitimate mail.

# ---------------------------------------------------------------------------
# Banner and misc
# ---------------------------------------------------------------------------
smtpd_banner = $myhostname ESMTP
smtpd_client_connection_count_limit = 50
smtpd_client_connection_rate_limit = 100
smtpd_client_message_rate_limit = 200
smtpd_error_sleep_time = 5s
smtpd_soft_error_limit = 10
smtpd_hard_error_limit = 20
anvil_rate_time_unit = 60s

# Address verification cache lives on local disk, not in the replicated DB.
address_verify_map = btree:$data_directory/verify_cache

# Reject codes
unknown_local_recipient_reject_code = 550
unverified_recipient_reject_code = 550
