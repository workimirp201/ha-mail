##############################################################################
# ha-mail :: /etc/nginx/nginx.conf
# Node ${SELF_ROLE} - ${SELF_HOSTNAME}
##############################################################################

user www-data;
worker_processes auto;
worker_rlimit_nofile 8192;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 2048;
    multi_accept on;
}

http {
    ##########################################################################
    # Basics
    ##########################################################################
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    types_hash_max_size 2048;
    server_tokens off;                 # never advertise the nginx version
    client_max_body_size 64m;          # must be >= Postfix message_size_limit
    client_body_timeout 60s;
    client_header_timeout 60s;
    keepalive_timeout 65s;
    send_timeout 60s;
    server_names_hash_bucket_size 128;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    ##########################################################################
    # Logging
    ##########################################################################
    # The node name is in every line. When both nodes ship logs to the same
    # place, this is what tells you which one actually served a request during
    # a failover.
    log_format hamail '$remote_addr - $remote_user [$time_local] '
                      '"$request" $status $body_bytes_sent '
                      '"$http_referer" "$http_user_agent" '
                      'rt=$request_time node=${SELF_SHORTNAME}';

    access_log /var/log/nginx/access.log hamail;
    error_log  /var/log/nginx/error.log warn;

    ##########################################################################
    # RATE LIMITING / BRUTE-FORCE PROTECTION (layer 1 of 3)
    ##########################################################################
    # Layer 1: nginx limit_req - cheap, stops volumetric guessing instantly.
    # Layer 2: fail2ban       - bans the source IP at the firewall after N
    #                           application-level auth failures.
    # Layer 3: the app itself - PostfixAdmin's own lockout, Dovecot's
    #                           auth_failure_delay.
    #
    # THESE COUNTERS ARE NODE-LOCAL AND THAT IS A REAL LIMITATION.
    # An attacker who alternates between ${NODE_A_IP} and ${NODE_B_IP} gets
    # twice the budget. It is documented rather than hidden; the mitigation is
    # that the admin portal is DNS-steered to a single node (see
    # docs/AUDIT.md section 5), so in practice only webmail is exposed on
    # both, and the limits below are set with the doubling already in mind.
    limit_req_zone $binary_remote_addr zone=hamail_login:10m rate=6r/m;
    limit_req_zone $binary_remote_addr zone=hamail_app:10m   rate=30r/s;
    limit_conn_zone $binary_remote_addr zone=hamail_conn:10m;
    limit_req_status 429;
    limit_conn_status 429;

    ##########################################################################
    # TLS defaults (per-vhost certificates live in the site files)
    ##########################################################################
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_session_timeout 1d;
    ssl_session_cache shared:HAMAIL_SSL:10m;

    # Session tickets OFF. The ticket key is node-local, so a resumption
    # attempt against the other node fails and falls back to a full handshake
    # anyway - and a long-lived ticket key weakens forward secrecy for no gain
    # here.
    ssl_session_tickets off;

    ssl_dhparam /etc/nginx/dhparam.pem;

    ##########################################################################
    # Compression
    ##########################################################################
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 5;
    gzip_min_length 512;
    gzip_types text/plain text/css application/json application/javascript
               text/xml application/xml application/xml+rss text/javascript
               image/svg+xml;

    ##########################################################################
    # Upstreams: one PHP-FPM pool per application.
    ##########################################################################
    # Separate pools mean a Roundcube slow-loris cannot exhaust the workers
    # the admin portal needs, and a crash in one does not take the other down.
    upstream php_postfixadmin {
        server unix:/run/php/php-fpm-postfixadmin.sock;
    }
    upstream php_roundcube {
        server unix:/run/php/php-fpm-roundcube.sock;
    }

    ##########################################################################
    # Default server: refuse anything that does not match a real vhost.
    ##########################################################################
    # Without this, a request with an unknown Host header is served by the
    # first vhost alphabetically - which is how the admin portal ends up
    # answering on an IP address.
    server {
        listen 80 default_server;
        listen 443 ssl default_server;
        server_name _;

        ssl_certificate     ${CERT_ROOT}/live/${SELF_HOSTNAME}/fullchain.pem;
        ssl_certificate_key ${CERT_ROOT}/live/${SELF_HOSTNAME}/privkey.pem;

        # ACME must still work on the default server so that a certificate can
        # be issued for a name that has no vhost yet.
        include /etc/nginx/snippets/hamail-acme.conf;

        location / {
            return 444;                # close the connection, log nothing
        }
    }

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
