#!/usr/bin/env bash
##############################################################################
# ha-mail :: scripts/80-nginx-php.sh
# nginx and the two isolated PHP-FPM pools.
##############################################################################

set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_env "${HAMAIL_ENV_FILE:-${HAMAIL_ROOT}/.env}"
require_root

log "configuring nginx and PHP-FPM"

PHPVER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
log "detected PHP ${PHPVER}"

# ---------------------------------------------------------------------------
# PHP-FPM pools
# ---------------------------------------------------------------------------
# The packaged www pool is removed. Leaving it in place means an unexpected
# vhost can reach a pool with no open_basedir and none of our hardening.
rm -f "/etc/php/${PHPVER}/fpm/pool.d/www.conf"

render "${HAMAIL_TEMPLATES}/php/pool-postfixadmin.conf.tpl" \
       "/etc/php/${PHPVER}/fpm/pool.d/postfixadmin.conf"
render "${HAMAIL_TEMPLATES}/php/pool-roundcube.conf.tpl" \
       "/etc/php/${PHPVER}/fpm/pool.d/roundcube.conf"

# The pool templates name the 8.3 path in their comment header; if the system
# has a different PHP, fix the socket paths to match reality.
cat > "/etc/php/${PHPVER}/fpm/conf.d/99-hamail.ini" <<PHPINI
; ha-mail :: global PHP hardening (applies to every pool)
expose_php = Off
display_errors = Off
display_startup_errors = Off
log_errors = On
allow_url_fopen = Off
allow_url_include = Off

; Timezone must be set explicitly or PHP warns on every date() call and the
; admin portal's audit timestamps drift from the mail logs.
date.timezone = ${TIMEZONE}

; Opcache. A mail admin portal is read-mostly and benefits substantially.
opcache.enable = 1
opcache.memory_consumption = 128
opcache.max_accelerated_files = 10000
opcache.validate_timestamps = 1
opcache.revalidate_freq = 60

; Session cookies are also set per-pool; these are the floor.
session.use_strict_mode = 1
session.cookie_httponly = 1
session.cookie_secure = 1
PHPINI

ensure_dir /var/lib/php/sessions-postfixadmin 0700 www-data:www-data
ensure_dir /var/lib/php/sessions-roundcube    0700 www-data:www-data

systemctl enable --now "php${PHPVER}-fpm"
systemctl restart "php${PHPVER}-fpm"
ok "PHP-FPM pools running"

# ---------------------------------------------------------------------------
# nginx
# ---------------------------------------------------------------------------
if [[ ! -f /etc/nginx/dhparam.pem ]]; then
    if [[ -f "/etc/postfix/dh${DH_BITS}.pem" ]]; then
        cp "/etc/postfix/dh${DH_BITS}.pem" /etc/nginx/dhparam.pem
    else
        log "generating DH parameters for nginx"
        openssl dhparam -out /etc/nginx/dhparam.pem "${DH_BITS}" 2>/dev/null
    fi
fi

ensure_dir /etc/nginx/snippets 0755 root:root
render "${HAMAIL_TEMPLATES}/nginx/nginx.conf.tpl" /etc/nginx/nginx.conf
render "${HAMAIL_TEMPLATES}/nginx/snippets/tls.conf.tpl"              /etc/nginx/snippets/hamail-tls.conf
render "${HAMAIL_TEMPLATES}/nginx/snippets/security-headers.conf.tpl" /etc/nginx/snippets/hamail-security-headers.conf
render "${HAMAIL_TEMPLATES}/nginx/snippets/acme.conf.tpl"             /etc/nginx/snippets/hamail-acme.conf
render "${HAMAIL_TEMPLATES}/nginx/snippets/php.conf.tpl"              /etc/nginx/snippets/hamail-php.conf

rm -f /etc/nginx/sites-enabled/default
for site in acme webmail admin autoconfig; do
    render "${HAMAIL_TEMPLATES}/nginx/site-${site}.conf.tpl" \
           "/etc/nginx/sites-available/hamail-${site}.conf"
    ln -sf "/etc/nginx/sites-available/hamail-${site}.conf" \
           "/etc/nginx/sites-enabled/hamail-${site}.conf"
done

# ---------------------------------------------------------------------------
# Client auto-configuration documents
# ---------------------------------------------------------------------------
ensure_dir /var/www/autoconfig/mail 0755 www-data:www-data
ensure_dir /var/www/autoconfig/autodiscover 0755 www-data:www-data
render "${HAMAIL_TEMPLATES}/autoconfig/mail/config-v1.1.xml.tpl" \
       /var/www/autoconfig/mail/config-v1.1.xml 0644 www-data:www-data
render "${HAMAIL_TEMPLATES}/autoconfig/autodiscover/autodiscover.xml.tpl" \
       /var/www/autoconfig/autodiscover/autodiscover.xml 0644 www-data:www-data

# ---------------------------------------------------------------------------
# Validate before reloading. `nginx -t` on a config that references a
# certificate file which does not exist yet fails, which is why 60-dovecot.sh
# has already dropped self-signed placeholders in.
# ---------------------------------------------------------------------------
if ! nginx -t 2>/tmp/nginx-t.err; then
    cat /tmp/nginx-t.err >&2
    die "nginx configuration is invalid"
fi
ok "nginx configuration is valid"

systemctl enable --now nginx
systemctl reload nginx || systemctl restart nginx
ok "nginx running"
