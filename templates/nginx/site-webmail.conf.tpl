##############################################################################
# ha-mail :: /etc/nginx/sites-available/hamail-webmail.conf
# Roundcube - runs ACTIVE-ACTIVE on both nodes.
#
# ${WEBMAIL_HOST} resolves to both ${NODE_A_IP} and ${NODE_B_IP}. Each node's
# Roundcube talks to its OWN Dovecot on 127.0.0.1 and its OWN MariaDB replica,
# so a browser that lands on either node gets a working mailbox. Contacts and
# identities replicate; the PHP session does not (sessions are node-local
# files), so a mid-session failover means one re-login and nothing worse.
##############################################################################

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${WEBMAIL_HOST};

    root ${ROUNDCUBE_ROOT}/public_html;
    index index.php;

    include /etc/nginx/snippets/hamail-tls.conf;
    include /etc/nginx/snippets/hamail-security-headers.conf;
    include /etc/nginx/snippets/hamail-acme.conf;

    access_log /var/log/nginx/webmail-access.log hamail;
    error_log  /var/log/nginx/webmail-error.log warn;

    limit_conn hamail_conn 20;

    # ---------------------------------------------------------------------
    # Deny list. Roundcube ships plenty of things that must never be served.
    # ---------------------------------------------------------------------
    location ~ ^/(config|temp|logs|bin|SQL|installer|vendor)/ {
        deny all;
        return 404;
    }
    location ~ ^/(README|INSTALL|LICENSE|CHANGELOG|UPGRADING|composer\.json|composer\.lock)$ {
        deny all;
        return 404;
    }
    location ~ /\. {
        deny all;
        return 404;
    }

    # ---------------------------------------------------------------------
    # The login endpoint gets the strict rate limit.
    # ---------------------------------------------------------------------
    # burst=3 nodelay lets a user who fat-fingers their password twice retry
    # immediately, while a script gets throttled to the zone rate (6/min).
    location = /index.php {
        limit_req zone=hamail_login burst=3 nodelay;
        include /etc/nginx/snippets/hamail-php.conf;
        fastcgi_pass php_roundcube;
    }

    location ~ \.php$ {
        limit_req zone=hamail_app burst=50 nodelay;
        include /etc/nginx/snippets/hamail-php.conf;
        fastcgi_pass php_roundcube;
    }

    # Static assets.
    location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|woff2?|ttf|eot)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        access_log off;
        try_files $uri =404;
    }

    location / {
        try_files $uri $uri/ /index.php$is_args$args;
    }
}
