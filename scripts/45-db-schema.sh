#!/usr/bin/env bash
##############################################################################
# ha-mail :: scripts/45-db-schema.sh
#
# Creates the schema, users and grants.
#
# *** RUN THIS ON NODE A ONLY ***
#
# The statements below are DDL and DML. Once replication is running they
# travel to Node B through the binlog. Executing them independently on both
# nodes creates two unrelated table histories and two different sets of
# AUTO_INCREMENT positions - which is the fastest way to break a fresh
# cluster. The script refuses to run on Node B unless --force is given.
##############################################################################

set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_env "${HAMAIL_ENV_FILE:-${HAMAIL_ROOT}/.env}"
require_root

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

if [[ "${SELF_ROLE}" != "A" && "${FORCE}" != "1" ]]; then
    warn "This is node ${SELF_ROLE}. The schema is created on Node A and arrives here"
    warn "through replication. Skipping."
    warn "If you are rebuilding Node A from scratch and Node B holds the good data,"
    warn "re-run with --force after reading docs/TESTING.md section 5."
    exit 0
fi

log "applying schema to ${DB_NAME}"

TMP="$(mktemp /tmp/hamail-schema.XXXXXX.sql)"
trap 'rm -f "${TMP}"' EXIT

# The schema template holds passwords, so render it to a private temp file
# rather than anywhere persistent.
render "${HAMAIL_TEMPLATES}/mariadb/schema.sql.tpl" "${TMP}" 0600 root:root

mysql_root < "${TMP}"
ok "schema, users and grants applied"

# ---------------------------------------------------------------------------
# Verify the grants actually work, by connecting AS each account.
# ---------------------------------------------------------------------------
# A grant that exists but does not work (wrong host, wrong socket, wrong
# plugin) presents later as "Postfix says User unknown" - a very indirect
# symptom for a very direct cause.
if mariadb -u"${DB_RO_USER}" -p"${DB_RO_PASS}" --socket=/run/mysqld/mysqld.sock \
        -D"${DB_NAME}" -e 'SELECT COUNT(*) FROM domain' >/dev/null 2>&1; then
    ok "read-only map account (${DB_RO_USER}) works"
else
    die "cannot connect as ${DB_RO_USER} - Postfix and Dovecot lookups will fail"
fi

if mariadb -u"${DB_USER}" -p"${DB_PASS}" --socket=/run/mysqld/mysqld.sock \
        -D"${DB_NAME}" -e 'SELECT COUNT(*) FROM mailbox' >/dev/null 2>&1; then
    ok "admin portal account (${DB_USER}) works"
else
    die "cannot connect as ${DB_USER} - PostfixAdmin will not start"
fi

mysql_root -e "SELECT domain, active, backupmx FROM ${DB_NAME}.domain" 
ok "schema ready"
