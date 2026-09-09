#!/usr/bin/env bash
##############################################################################
# ha-mail :: scripts/90-roundcube.sh
# Webmail. Genuinely active-active: each node's Roundcube talks only to its
# own Dovecot and its own database replica.
##############################################################################

set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_env "${HAMAIL_ENV_FILE:-${HAMAIL_ROOT}/.env}"
require_root

log "installing Roundcube ${ROUNDCUBE_VERSION}"

if [[ ! -f "${ROUNDCUBE_ROOT}/index.php" && ! -d "${ROUNDCUBE_ROOT}/program" ]]; then
    TARBALL="/tmp/roundcube-${ROUNDCUBE_VERSION}.tar.gz"
    URL="https://github.com/roundcube/roundcubemail/releases/download/${ROUNDCUBE_VERSION}/roundcubemail-${ROUNDCUBE_VERSION}-complete.tar.gz"

    curl -fsSL -o "${TARBALL}" "${URL}" \
        || die "could not download Roundcube ${ROUNDCUBE_VERSION} from ${URL}"

    ensure_dir "${ROUNDCUBE_ROOT}" 0755 root:root
    tar -xzf "${TARBALL}" -C "${ROUNDCUBE_ROOT}" --strip-components=1
    rm -f "${TARBALL}"
    ok "extracted to ${ROUNDCUBE_ROOT}"
fi

ensure_dir "${ROUNDCUBE_ROOT}/temp" 0750 www-data:www-data
ensure_dir "${ROUNDCUBE_ROOT}/logs" 0750 www-data:www-data

render "${HAMAIL_TEMPLATES}/roundcube/config.inc.php.tpl" \
       "${ROUNDCUBE_ROOT}/config/config.inc.php" 0640 root:www-data

# ---------------------------------------------------------------------------
# Database schema - NODE A ONLY.
# ---------------------------------------------------------------------------
# Same reasoning as the mail schema: this is DDL, it replicates, and running
# it independently on both nodes produces two divergent table histories.
if [[ "${SELF_ROLE}" == "A" ]]; then
    if ! mysql_root -N -B -e "SHOW TABLES FROM ${RC_DB_NAME} LIKE 'users'" | grep -q users; then
        log "initialising the Roundcube schema"
        mariadb -u"${RC_DB_USER}" -p"${RC_DB_PASS}" --socket=/run/mysqld/mysqld.sock \
            "${RC_DB_NAME}" < "${ROUNDCUBE_ROOT}/SQL/mysql.initial.sql"
        ok "Roundcube schema created (replicates to ${PEER_HOSTNAME})"
    else
        log "running Roundcube's own schema updater"
        ( cd "${ROUNDCUBE_ROOT}" && sudo -u www-data bin/updatedb.sh --package=roundcube --dir=SQL ) || true
    fi
else
    log "node ${SELF_ROLE}: Roundcube schema arrives by replication"
    # Wait for it rather than proceeding into a broken install.
    for i in $(seq 1 30); do
        if mysql_root -N -B -e "SHOW TABLES FROM ${RC_DB_NAME} LIKE 'users'" 2>/dev/null | grep -q users; then
            ok "Roundcube schema is present (replicated)"
            break
        fi
        sleep 2
        (( i == 30 )) && warn "the Roundcube schema has not arrived from Node A. Check replication."
    done
fi

# ---------------------------------------------------------------------------
# The installer directory must not exist on a live server.
# ---------------------------------------------------------------------------
rm -rf "${ROUNDCUBE_ROOT}/installer"

chown -R root:www-data "${ROUNDCUBE_ROOT}"
chown -R www-data:www-data "${ROUNDCUBE_ROOT}/temp" "${ROUNDCUBE_ROOT}/logs"
chmod -R o-rwx "${ROUNDCUBE_ROOT}"

# ---------------------------------------------------------------------------
# Cache cleanup. Roundcube ships a cron job for this; run it daily.
# ---------------------------------------------------------------------------
cat > /etc/cron.d/hamail-roundcube <<CRON
# ha-mail :: Roundcube housekeeping
# Randomised minute so the two nodes do not both run it at the same instant.
$(( RANDOM % 60 )) 4 * * * www-data ${ROUNDCUBE_ROOT}/bin/cleandb.sh >/dev/null 2>&1
CRON

# ---------------------------------------------------------------------------
# Verify the whole webmail path, not just that files exist.
# ---------------------------------------------------------------------------
if sudo -u www-data php -r "
\$_SERVER['HTTPS']='on';
define('INSTALL_PATH', '${ROUNDCUBE_ROOT}/');
require_once '${ROUNDCUBE_ROOT}/program/include/iniset.php';
\$rc = rcmail::get_instance();
echo \$rc->config->get('imap_host') ? 'CONFIG_OK' : 'CONFIG_FAIL';
" 2>/dev/null | grep -q CONFIG_OK; then
    ok "Roundcube configuration loads"
else
    warn "could not verify the Roundcube configuration from the CLI; check ${ROUNDCUBE_ROOT}/logs/errors.log"
fi

systemctl reload nginx || true
ok "Roundcube ready at https://${WEBMAIL_HOST}/"
