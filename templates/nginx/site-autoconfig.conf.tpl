##############################################################################
# ha-mail :: /etc/nginx/sites-available/hamail-autoconfig.conf
#
# Client auto-configuration. Runs active-active on both nodes; the XML it
# serves points clients at ${MAIL_HOST}, which is itself a dual-A record - so
# a client provisioned from either node is automatically configured for
# failover without knowing that two servers exist.
#
#   Thunderbird / most open clients : autoconfig.${DOMAIN}/mail/config-v1.1.xml
#   Outlook / Exchange-style clients: autodiscover.${DOMAIN}/autodiscover/autodiscover.xml
#   Apple Mail                      : uses a signed .mobileconfig (not served here)
##############################################################################

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${AUTOCONFIG_HOST} autodiscover.${DOMAIN};

    root /var/www/autoconfig;

    include /etc/nginx/snippets/hamail-tls.conf;
    include /etc/nginx/snippets/hamail-security-headers.conf;
    include /etc/nginx/snippets/hamail-acme.conf;

    access_log /var/log/nginx/autoconfig-access.log hamail;

    # Thunderbird fetches this over plain HTTP or HTTPS with no auth.
    location = /mail/config-v1.1.xml {
        default_type application/xml;
        try_files /mail/config-v1.1.xml =404;
    }

    # Outlook POSTs an XML body here; a static response is sufficient and
    # avoids running PHP on an unauthenticated endpoint.
    location = /autodiscover/autodiscover.xml {
        default_type application/xml;
        try_files /autodiscover/autodiscover.xml =404;
    }
    location = /Autodiscover/Autodiscover.xml {
        default_type application/xml;
        try_files /autodiscover/autodiscover.xml =404;
    }

    location / {
        return 404;
    }
}
