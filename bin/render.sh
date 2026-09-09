#!/usr/bin/env bash
##############################################################################
# ha-mail :: bin/render.sh
#
# Standalone template renderer. Two uses:
#
#   1. Dry-run the whole blueprint into a scratch tree without touching the
#      live system, so you can diff what a deploy WOULD do:
#
#          ./bin/render.sh --all --out /tmp/preview
#          diff -ru /etc/postfix /tmp/preview/etc/postfix
#
#   2. Render a single template to stdout while debugging:
#
#          ./bin/render.sh templates/postfix/main.cf.tpl
#
# Rendering is a whitelisted envsubst (see lib/common.sh :: RENDER_VARS) so
# that $host, $remote_addr, $mydomain and friends survive untouched.
##############################################################################

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

usage() {
    cat <<'USAGE'
Usage:
  render.sh <template-file>              Render one template to stdout
  render.sh --all --out <dir>            Render the full tree into <dir>
  render.sh --list                       List every template and its target

Options:
  --env <file>    Path to the .env file (default: <repo>/.env)
  --role <A|B>    Override NODE_ROLE for this render only
USAGE
}

ENV_FILE="${HAMAIL_ROOT}/.env"
OUT_DIR=""
MODE="single"
ROLE_OVERRIDE=""
TARGET=""

while (($#)); do
    case "$1" in
        --all)   MODE="all"; shift ;;
        --list)  MODE="list"; shift ;;
        --out)   OUT_DIR="$2"; shift 2 ;;
        --env)   ENV_FILE="$2"; shift 2 ;;
        --role)  ROLE_OVERRIDE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*)      die "unknown option: $1" ;;
        *)       TARGET="$1"; shift ;;
    esac
done

load_env "${ENV_FILE}"
if [[ -n "${ROLE_OVERRIDE}" ]]; then
    NODE_ROLE="${ROLE_OVERRIDE}"
    export NODE_ROLE
    derive_vars
    log "role overridden for this render: ${NODE_ROLE}"
fi

# ---------------------------------------------------------------------------
# The authoritative template -> destination map. Everything the deploy writes
# is listed here exactly once, which makes `--list` a complete inventory of
# every file this blueprint owns on a node.
# ---------------------------------------------------------------------------
declare -a MAP=(
    "mariadb/50-server.cnf.tpl|/etc/mysql/mariadb.conf.d/50-server.cnf|0644|root:root"

    "postfix/main.cf.tpl|/etc/postfix/main.cf|0644|root:root"
    "postfix/master.cf.tpl|/etc/postfix/master.cf|0644|root:root"
    "postfix/header_checks|/etc/postfix/header_checks|0644|root:root"
    "postfix/submission_header_cleanup.tpl|/etc/postfix/submission_header_cleanup|0644|root:root"
    "postfix/sql/mysql-virtual-domains.cf.tpl|/etc/postfix/sql/mysql-virtual-domains.cf|0640|root:postfix"
    "postfix/sql/mysql-virtual-alias-domains.cf.tpl|/etc/postfix/sql/mysql-virtual-alias-domains.cf|0640|root:postfix"
    "postfix/sql/mysql-virtual-mailbox-maps.cf.tpl|/etc/postfix/sql/mysql-virtual-mailbox-maps.cf|0640|root:postfix"
    "postfix/sql/mysql-virtual-alias-maps.cf.tpl|/etc/postfix/sql/mysql-virtual-alias-maps.cf|0640|root:postfix"
    "postfix/sql/mysql-virtual-alias-domain-maps.cf.tpl|/etc/postfix/sql/mysql-virtual-alias-domain-maps.cf|0640|root:postfix"
    "postfix/sql/mysql-virtual-alias-domain-catchall-maps.cf.tpl|/etc/postfix/sql/mysql-virtual-alias-domain-catchall-maps.cf|0640|root:postfix"
    "postfix/sql/mysql-virtual-alias-domain-mailbox-maps.cf.tpl|/etc/postfix/sql/mysql-virtual-alias-domain-mailbox-maps.cf|0640|root:postfix"
    "postfix/sql/mysql-virtual-sender-login-maps.cf.tpl|/etc/postfix/sql/mysql-virtual-sender-login-maps.cf|0640|root:postfix"
    "postfix/sql/mysql-virtual-mailbox-limit-maps.cf.tpl|/etc/postfix/sql/mysql-virtual-mailbox-limit-maps.cf|0640|root:postfix"
    "postfix/sql/mysql-tls-policy.cf.tpl|/etc/postfix/sql/mysql-tls-policy.cf|0640|root:postfix"

    "dovecot/dovecot.conf.tpl|/etc/dovecot/dovecot.conf|0644|root:root"
    "dovecot/conf.d/10-auth.conf.tpl|/etc/dovecot/conf.d/10-auth.conf|0644|root:root"
    "dovecot/conf.d/10-logging.conf.tpl|/etc/dovecot/conf.d/10-logging.conf|0644|root:root"
    "dovecot/conf.d/10-mail.conf.tpl|/etc/dovecot/conf.d/10-mail.conf|0644|root:root"
    "dovecot/conf.d/10-master.conf.tpl|/etc/dovecot/conf.d/10-master.conf|0644|root:root"
    "dovecot/conf.d/10-ssl.conf.tpl|/etc/dovecot/conf.d/10-ssl.conf|0644|root:root"
    "dovecot/conf.d/15-lda.conf.tpl|/etc/dovecot/conf.d/15-lda.conf|0644|root:root"
    "dovecot/conf.d/15-mailboxes.conf.tpl|/etc/dovecot/conf.d/15-mailboxes.conf|0644|root:root"
    "dovecot/conf.d/20-imap.conf.tpl|/etc/dovecot/conf.d/20-imap.conf|0644|root:root"
    "dovecot/conf.d/20-lmtp.conf.tpl|/etc/dovecot/conf.d/20-lmtp.conf|0644|root:root"
    "dovecot/conf.d/20-managesieve.conf.tpl|/etc/dovecot/conf.d/20-managesieve.conf|0644|root:root"
    "dovecot/conf.d/90-quota.conf.tpl|/etc/dovecot/conf.d/90-quota.conf|0644|root:root"
    "dovecot/conf.d/90-sieve.conf.tpl|/etc/dovecot/conf.d/90-sieve.conf|0644|root:root"
    "dovecot/conf.d/95-replication.conf.tpl|/etc/dovecot/conf.d/95-replication.conf|0644|root:root"
    "dovecot/sql/auth-sql.conf.ext.tpl|/etc/dovecot/auth-sql.conf.ext|0644|root:root"
    "dovecot/sql/dovecot-sql.conf.ext.tpl|/etc/dovecot/dovecot-sql.conf.ext|0640|root:dovecot"
    "dovecot/sql/dovecot-dict-sql.conf.ext.tpl|/etc/dovecot/dovecot-dict-sql.conf.ext|0640|root:dovecot"
    "dovecot/sieve/default.sieve|/var/lib/dovecot/sieve/default.sieve|0644|root:root"
    "dovecot/sieve/learn-spam.sieve|/var/lib/dovecot/sieve/learn-spam.sieve|0644|root:root"
    "dovecot/sieve/learn-ham.sieve|/var/lib/dovecot/sieve/learn-ham.sieve|0644|root:root"

    "helpers/hamail-learn-spam.sh|/usr/lib/dovecot/sieve-pipe/hamail-learn-spam.sh|0755|root:root"
    "helpers/hamail-learn-ham.sh|/usr/lib/dovecot/sieve-pipe/hamail-learn-ham.sh|0755|root:root"
    "helpers/hamail-quota-warning.sh.tpl|/usr/local/bin/hamail-quota-warning.sh|0755|root:root"

    "rspamd/local.d/dkim_signing.conf.tpl|/etc/rspamd/local.d/dkim_signing.conf|0644|root:root"
    "rspamd/local.d/arc.conf.tpl|/etc/rspamd/local.d/arc.conf|0644|root:root"
    "rspamd/local.d/redis.conf.tpl|/etc/rspamd/local.d/redis.conf|0644|root:root"
    "rspamd/local.d/worker-proxy.inc.tpl|/etc/rspamd/local.d/worker-proxy.inc|0644|root:root"
    "rspamd/local.d/worker-normal.inc.tpl|/etc/rspamd/local.d/worker-normal.inc|0644|root:root"
    "rspamd/local.d/worker-controller.inc.tpl|/etc/rspamd/local.d/worker-controller.inc|0644|root:root"
    "rspamd/local.d/classifier-bayes.conf.tpl|/etc/rspamd/local.d/classifier-bayes.conf|0644|root:root"
    "rspamd/local.d/milter_headers.conf.tpl|/etc/rspamd/local.d/milter_headers.conf|0644|root:root"
    "rspamd/local.d/options.inc.tpl|/etc/rspamd/local.d/options.inc|0644|root:root"
    "rspamd/local.d/logging.inc.tpl|/etc/rspamd/local.d/logging.inc|0644|root:root"

    "nginx/nginx.conf.tpl|/etc/nginx/nginx.conf|0644|root:root"
    "nginx/snippets/tls.conf.tpl|/etc/nginx/snippets/hamail-tls.conf|0644|root:root"
    "nginx/snippets/security-headers.conf.tpl|/etc/nginx/snippets/hamail-security-headers.conf|0644|root:root"
    "nginx/snippets/acme.conf.tpl|/etc/nginx/snippets/hamail-acme.conf|0644|root:root"
    "nginx/snippets/php.conf.tpl|/etc/nginx/snippets/hamail-php.conf|0644|root:root"
    "nginx/site-acme.conf.tpl|/etc/nginx/sites-available/hamail-acme.conf|0644|root:root"
    "nginx/site-webmail.conf.tpl|/etc/nginx/sites-available/hamail-webmail.conf|0644|root:root"
    "nginx/site-admin.conf.tpl|/etc/nginx/sites-available/hamail-admin.conf|0644|root:root"
    "nginx/site-autoconfig.conf.tpl|/etc/nginx/sites-available/hamail-autoconfig.conf|0644|root:root"

    "php/pool-postfixadmin.conf.tpl|/etc/php/8.3/fpm/pool.d/postfixadmin.conf|0644|root:root"
    "php/pool-roundcube.conf.tpl|/etc/php/8.3/fpm/pool.d/roundcube.conf|0644|root:root"

    "postfixadmin/config.local.php.tpl|/opt/postfixadmin/config.local.php|0640|root:www-data"
    "roundcube/config.inc.php.tpl|/opt/roundcube/config/config.inc.php|0640|root:www-data"

    "autoconfig/mail/config-v1.1.xml.tpl|/var/www/autoconfig/mail/config-v1.1.xml|0644|root:root"
    "autoconfig/autodiscover/autodiscover.xml.tpl|/var/www/autoconfig/autodiscover/autodiscover.xml|0644|root:root"

    "fail2ban/jail.d/hamail.conf.tpl|/etc/fail2ban/jail.d/hamail.conf|0644|root:root"
    "fail2ban/filter.d/postfixadmin.conf|/etc/fail2ban/filter.d/postfixadmin.conf|0644|root:root"
    "fail2ban/filter.d/roundcube-auth.conf|/etc/fail2ban/filter.d/roundcube-auth.conf|0644|root:root"
    "fail2ban/filter.d/dovecot-hamail.conf|/etc/fail2ban/filter.d/dovecot-hamail.conf|0644|root:root"

    "wireguard/wg0.conf.tpl|/etc/wireguard/wg0.conf|0600|root:root"

    "bin/hamail-cert-sync.sh.tpl|/usr/local/bin/hamail-cert-sync.sh|0755|root:root"
    "bin/hamail-cert-deploy-hook.sh.tpl|/etc/letsencrypt/renewal-hooks/deploy/hamail-cert-deploy-hook.sh|0755|root:root"
    "bin/hamail-health.sh.tpl|/usr/local/bin/hamail-health.sh|0755|root:root"
    "bin/hamail-repl-watchdog.sh.tpl|/usr/local/bin/hamail-repl-watchdog.sh|0755|root:root"
    "bin/hamail-dns-failover.sh.tpl|/usr/local/bin/hamail-dns-failover.sh|0755|root:root"
    "bin/hamail-sni-map.sh.tpl|/usr/local/bin/hamail-sni-map.sh|0755|root:root"
    "bin/hamail-add-domain.sh.tpl|/usr/local/bin/hamail-add-domain.sh|0755|root:root"

    "systemd/10-hamail-wireguard.conf.tpl|/etc/systemd/system/mariadb.service.d/10-hamail-wireguard.conf|0644|root:root"
    "systemd/hamail-cert-sync.service.tpl|/etc/systemd/system/hamail-cert-sync.service|0644|root:root"
    "systemd/hamail-cert-sync.timer|/etc/systemd/system/hamail-cert-sync.timer|0644|root:root"
    "systemd/hamail-health.service.tpl|/etc/systemd/system/hamail-health.service|0644|root:root"
    "systemd/hamail-health.timer|/etc/systemd/system/hamail-health.timer|0644|root:root"
    "systemd/hamail-repl-watchdog.service.tpl|/etc/systemd/system/hamail-repl-watchdog.service|0644|root:root"
    "systemd/hamail-repl-watchdog.timer|/etc/systemd/system/hamail-repl-watchdog.timer|0644|root:root"
)

case "${MODE}" in
    list)
        printf '%-70s %s\n' "TEMPLATE" "DESTINATION"
        for entry in "${MAP[@]}"; do
            IFS='|' read -r tpl dest _mode _own <<< "${entry}"
            printf '%-70s %s\n' "templates/${tpl}" "${dest}"
        done
        ;;
    single)
        [[ -n "${TARGET}" ]] || { usage; exit 1; }
        [[ -f "${TARGET}" ]] || die "no such template: ${TARGET}"
        varspec=""
        for v in "${RENDER_VARS[@]}"; do varspec+="\${${v}} "; done
        envsubst "${varspec}" < "${TARGET}"
        ;;
    all)
        [[ -n "${OUT_DIR}" ]] || die "--all requires --out <dir>"
        mkdir -p "${OUT_DIR}"
        for entry in "${MAP[@]}"; do
            IFS='|' read -r tpl dest mode own <<< "${entry}"
            src="${HAMAIL_TEMPLATES}/${tpl}"
            [[ -f "${src}" ]] || { warn "skipping missing template ${tpl}"; continue; }
            out="${OUT_DIR}${dest}"
            mkdir -p "$(dirname -- "${out}")"
            varspec=""
            for v in "${RENDER_VARS[@]}"; do varspec+="\${${v}} "; done
            envsubst "${varspec}" < "${src}" > "${out}"
            if grep -qE '\$\{[A-Z][A-Z0-9_]*\}' "${out}"; then
                stray="$(grep -ohE '\$\{[A-Z][A-Z0-9_]*\}' "${out}" | sort -u | tr '\n' ' ')"
                die "unsubstituted variables in ${tpl}: ${stray}"
            fi
            chmod "${mode}" "${out}"
            printf '%s\n' "${out}"
        done
        ok "rendered $(printf '%s\n' "${MAP[@]}" | wc -l) files into ${OUT_DIR}"
        ;;
esac
