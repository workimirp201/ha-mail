##############################################################################
# ha-mail :: /etc/nginx/snippets/hamail-tls.conf
# Shared-name certificate: issued on Node A, pulled by Node B.
##############################################################################

ssl_certificate     ${CERT_LIVE}/fullchain.pem;
ssl_certificate_key ${CERT_LIVE}/privkey.pem;
ssl_trusted_certificate ${CERT_LIVE}/chain.pem;

# HSTS. Two years, subdomains included, preload-eligible.
#
# Think before you deploy this: it is effectively irreversible for the life of
# the max-age, and it applies to every subdomain of ${DOMAIN}. If any
# subdomain must remain HTTP-only, drop includeSubDomains here.
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;

# OCSP stapling is intentionally absent: Let's Encrypt has retired its OCSP
# responders, and leaving ssl_stapling on just adds a failed lookup and a
# warning to every reload.
