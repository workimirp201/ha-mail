##############################################################################
# ha-mail :: /etc/nginx/sites-available/hamail-acme.conf
# Port-80 handling and the tunnel-only peer endpoint for ACME challenges.
##############################################################################

# ---------------------------------------------------------------------------
# Public port 80: serve ACME challenges, redirect everything else to HTTPS.
# ---------------------------------------------------------------------------
server {
    listen 80;
    listen [::]:80;
    server_name ${MAIL_HOST} ${WEBMAIL_HOST} ${ADMIN_HOST} ${AUTOCONFIG_HOST}
                ${SELF_HOSTNAME} autodiscover.${DOMAIN} ${DOMAIN} www.${DOMAIN};

    include /etc/nginx/snippets/hamail-acme.conf;

    location / {
        return 301 https://$host$request_uri;
    }
}

# ---------------------------------------------------------------------------
# TUNNEL-ONLY peer endpoint (${SELF_WG_IP}:8080).
# ---------------------------------------------------------------------------
# The other node proxies here when Let's Encrypt asks it for a token that this
# node created. Deliberately minimal:
#
#   * bound to the WireGuard address, so it is unreachable from the internet
#   * serves ONLY ${ACME_WEBROOT}, nothing else
#   * has NO try_files fallback of its own, which is what caps the chain at a
#     single hop and makes a proxy loop structurally impossible
##############################################################################
server {
    listen ${SELF_WG_IP}:8080;
    server_name _;

    access_log /var/log/nginx/acme-peer.log hamail;

    location ^~ /.well-known/acme-challenge/ {
        default_type "text/plain";
        root ${ACME_WEBROOT};
        # No named-location fallback here. A miss is a 404, full stop.
    }

    location / {
        return 444;
    }
}
