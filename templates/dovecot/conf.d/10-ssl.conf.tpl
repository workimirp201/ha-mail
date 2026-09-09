##############################################################################
# ha-mail :: /etc/dovecot/conf.d/10-ssl.conf
##############################################################################

# "required" - never negotiate an unencrypted IMAP session. Port 143 still
# exists but only as a STARTTLS entry point; a client that refuses STARTTLS is
# refused service.
ssl = required

# Certificate for ${MAIL_HOST}. On Node A this is issued locally by Certbot;
# on Node B it arrives through bin/cert-sync.sh (a strictly one-way pull - see
# docs/AUDIT.md section 2 for why the sync is not bidirectional).
#
# The < prefix is Dovecot syntax meaning "read the file", not a shell redirect.
ssl_cert = <${CERT_LIVE}/fullchain.pem
ssl_key  = <${CERT_LIVE}/privkey.pem

# Node-local certificate for ${SELF_HOSTNAME} itself, used when an operator or
# a monitoring probe connects by node name rather than by service name. Issued
# and renewed independently on each node, so it is never part of the sync.
local_name ${SELF_HOSTNAME} {
  ssl_cert = <${CERT_ROOT}/live/${SELF_HOSTNAME}/fullchain.pem
  ssl_key  = <${CERT_ROOT}/live/${SELF_HOSTNAME}/privkey.pem
}

ssl_min_protocol = TLSv1.2
ssl_cipher_list = ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256

# Let the client pick. Modern clients choose sensibly, and forcing server
# preference mainly serves to keep an obsolete ordering alive.
ssl_prefer_server_ciphers = no

ssl_dh = </etc/dovecot/dh.pem

# Not requesting client certificates: IMAP clients do not have them, and
# leaving this on generates a confusing prompt in some MUAs.
ssl_verify_client_cert = no

# OCSP stapling would go here (ssl_ca / ssl_ocsp_*), but Let's Encrypt has
# retired its OCSP responders, so stapling is deliberately not configured.
