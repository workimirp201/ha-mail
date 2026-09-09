##############################################################################
# ha-mail :: /etc/nginx/sites-available/hamail-admin.conf
# PostfixAdmin.
#
#          *** THIS VHOST IS ACTIVE-PASSIVE ON PURPOSE ***
#
# The application is INSTALLED and RUNNING on both nodes - so a failover is
# instant and needs no deployment step - but ${ADMIN_HOST} is published in DNS
# pointing at ONE node at a time (Node A by default; bin/dns-failover.sh moves
# it).
#
# WHY NOT ACTIVE-ACTIVE
# Asynchronous multi-master gives you eventual consistency, not mutual
# exclusion. Two admins creating alice@${DOMAIN} at the same moment on
# opposite nodes both succeed locally, and ~180ms later each node receives the
# other's INSERT for a primary key it already has. Replication stops with
# error 1062 and stays stopped until a human intervenes. Auto-increment
# offsets do NOT help here, because the collision is on a natural key (the
# email address), not a surrogate one.
#
# Steering admin WRITES to a single node removes the possibility entirely, at
# a cost of nothing that matters: administration is low-volume, and the standby
# node is one DNS change (or one `--force-local` flag) away.
#
# See docs/AUDIT.md section 5 for the full argument and the conflict detector
# that alerts if someone bypasses the steering.
##############################################################################

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${ADMIN_HOST};

    root ${POSTFIXADMIN_ROOT}/public;
    index index.php;

    include /etc/nginx/snippets/hamail-tls.conf;
    include /etc/nginx/snippets/hamail-security-headers.conf;
    include /etc/nginx/snippets/hamail-acme.conf;

    access_log /var/log/nginx/admin-access.log hamail;
    error_log  /var/log/nginx/admin-error.log warn;

    limit_conn hamail_conn 10;

    # ---------------------------------------------------------------------
    # setup.php is the installer. It is reachable exactly once, from the
    # operator's own address, and is then disabled outright by
    # scripts/85-postfixadmin.sh (which rewrites this block to `deny all`).
    # Leaving it exposed is the single most exploited PostfixAdmin
    # misconfiguration.
    # ---------------------------------------------------------------------
    location = /setup.php {
        # Replaced with `deny all; return 404;` once setup has been completed.
        allow 127.0.0.1;
        deny all;
        include /etc/nginx/snippets/hamail-php.conf;
        fastcgi_pass php_postfixadmin;
    }

    # Login POST target - strictest limit on the whole cluster.
    location = /login.php {
        limit_req zone=hamail_login burst=2 nodelay;
        include /etc/nginx/snippets/hamail-php.conf;
        fastcgi_pass php_postfixadmin;
    }

    # Password reset must be rate limited too: it is an unauthenticated
    # endpoint that sends mail, i.e. a free outbound-spam lever.
    location = /users/password-recover.php {
        limit_req zone=hamail_login burst=2 nodelay;
        include /etc/nginx/snippets/hamail-php.conf;
        fastcgi_pass php_postfixadmin;
    }

    location ~ \.php$ {
        limit_req zone=hamail_app burst=30 nodelay;
        include /etc/nginx/snippets/hamail-php.conf;
        fastcgi_pass php_postfixadmin;
    }

    location ~ /\. {
        deny all;
        return 404;
    }

    location / {
        try_files $uri $uri/ /index.php$is_args$args;
    }
}
