#!/usr/bin/env bash
##############################################################################
# ha-mail :: scripts/85-postfixadmin.sh
# The web admin portal.
#
# Installed and kept running on BOTH nodes so a failover needs no deployment
# step. DNS publishes ${ADMIN_HOST} at one node at a time - see the header of
# templates/nginx/site-admin.conf.tpl and docs/AUDIT.md section 5 for why
# admin WRITES are deliberately steered rather than load-balanced.
##############################################################################

set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_env "${HAMAIL_ENV_FILE:-${HAMAIL_ROOT}/.env}"
require_root

log "installing PostfixAdmin ${POSTFIXADMIN_VERSION}"

# ---------------------------------------------------------------------------
# Fetch
# ---------------------------------------------------------------------------
if [[ ! -d "${POSTFIXADMIN_ROOT}/public" ]]; then
    TARBALL="/tmp/postfixadmin-${POSTFIXADMIN_VERSION}.tar.gz"
    URL="https://github.com/postfixadmin/postfixadmin/archive/refs/tags/postfixadmin-${POSTFIXADMIN_VERSION}.tar.gz"

    curl -fsSL -o "${TARBALL}" "${URL}" \
        || die "could not download PostfixAdmin ${POSTFIXADMIN_VERSION} from ${URL}"

    ensure_dir "${POSTFIXADMIN_ROOT}" 0755 root:root
    tar -xzf "${TARBALL}" -C "${POSTFIXADMIN_ROOT}" --strip-components=1
    rm -f "${TARBALL}"
    ok "extracted to ${POSTFIXADMIN_ROOT}"
fi

ensure_dir "${POSTFIXADMIN_ROOT}/templates_c" 0750 www-data:www-data

# ---------------------------------------------------------------------------
# setup_password hash
# ---------------------------------------------------------------------------
# PostfixAdmin stores a salted SHA-1 of the setup password as "salt:hash".
# Deriving it here - deterministically, from SETUP_PASS - means both nodes end
# up with the SAME value without anyone pasting a hash between servers.
#
# The salt is derived from the password itself rather than being random,
# purely so the two nodes agree. That is acceptable because this credential
# only gates setup.php, which is firewalled off below; it is not a user
# password.
if [[ -z "${SETUP_PASS_HASH}" ]]; then
    SALT="$(printf '%s' "${SETUP_PASS}${DOMAIN}" | sha1sum | cut -c1-16)"
    HASH="$(printf '%s:%s' "${SALT}" "${SETUP_PASS}" | sha1sum | cut -d' ' -f1)"
    SETUP_PASS_HASH="${SALT}:${HASH}"
    export SETUP_PASS_HASH
fi

render "${HAMAIL_TEMPLATES}/postfixadmin/config.local.php.tpl" \
       "${POSTFIXADMIN_ROOT}/config.local.php" 0640 root:www-data

chown -R root:www-data "${POSTFIXADMIN_ROOT}"
chmod -R o-rwx "${POSTFIXADMIN_ROOT}"
chown -R www-data:www-data "${POSTFIXADMIN_ROOT}/templates_c"

# ---------------------------------------------------------------------------
# Schema reconciliation - NODE A ONLY.
# ---------------------------------------------------------------------------
# 45-db-schema.sh created the tables from our own DDL. PostfixAdmin's
# upgrade.php now reconciles anything our DDL got wrong for this exact release
# and stamps config.version, so a future PostfixAdmin upgrade applies the
# right migrations instead of trying to create tables that already exist.
#
# Running it on Node B as well would replay the same DDL a second time through
# a database that has already received it by replication.
if [[ "${SELF_ROLE}" == "A" ]]; then
    log "reconciling the schema with PostfixAdmin's own upgrade path"
    ( cd "${POSTFIXADMIN_ROOT}" && sudo -u www-data php public/upgrade.php ) \
        || warn "upgrade.php reported problems - check them before creating mailboxes"
    ok "schema reconciled"

    # -----------------------------------------------------------------------
    # Superadmin
    # -----------------------------------------------------------------------
    if ! mysql_root -N -B -e "SELECT 1 FROM ${DB_NAME}.admin WHERE username='${ADMIN_USER}'" | grep -q 1; then
        log "creating superadmin ${ADMIN_USER}"
        HASHED="$(doveadm pw -s ARGON2ID -p "${ADMIN_PASS}")"
        mysql_root <<SQL
USE ${DB_NAME};
INSERT INTO admin (username, password, superadmin, created, modified, active)
VALUES ('${ADMIN_USER}', '${HASHED}', 1, NOW(), NOW(), 1);
INSERT INTO domain_admins (username, domain, created, active)
VALUES ('${ADMIN_USER}', 'ALL', NOW(), 1);
SQL
        ok "superadmin created (replicates to ${PEER_HOSTNAME} automatically)"
    else
        ok "superadmin ${ADMIN_USER} already exists"
    fi
else
    log "node ${SELF_ROLE}: schema and superadmin arrive by replication - not touching the database"
fi

# ---------------------------------------------------------------------------
# Disable setup.php permanently.
# ---------------------------------------------------------------------------
# It is an unauthenticated-adjacent installer that can create a superadmin.
# The nginx vhost already restricts it to loopback; this replaces that block
# with an outright refusal, so even a loopback request (e.g. via an SSRF in
# another app on the box) cannot reach it.
SITE=/etc/nginx/sites-available/hamail-admin.conf
if grep -q 'location = /setup.php' "${SITE}"; then
    python3 - "$SITE" <<'PY'
import re, sys
path = sys.argv[1]
src = open(path).read()
new_block = """location = /setup.php {
        # Disabled by scripts/85-postfixadmin.sh after installation.
        # To re-enable temporarily: comment out the two lines below, reload
        # nginx, run setup, then PUT THEM BACK.
        deny all;
        return 404;
    }"""
src = re.sub(r"location = /setup\.php \{.*?\n    \}", new_block, src, count=1, flags=re.S)
open(path, "w").write(src)
PY
    nginx -t && systemctl reload nginx
    ok "setup.php disabled in the nginx vhost"
fi

ok "PostfixAdmin ready at https://${ADMIN_HOST}/"
