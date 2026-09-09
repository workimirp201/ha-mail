#!/usr/bin/env bash
# shellcheck shell=bash
##############################################################################
# ha-mail :: lib/common.sh
# Shared library: env loading, variable derivation, rendering, logging.
# Sourced by every script in scripts/ and bin/. Never executed directly.
##############################################################################

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Locate the repository root regardless of where we were invoked from.
# ---------------------------------------------------------------------------
HAMAIL_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HAMAIL_ROOT="$(cd -- "${HAMAIL_LIB_DIR}/.." && pwd)"
export HAMAIL_ROOT
export HAMAIL_TEMPLATES="${HAMAIL_ROOT}/templates"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
    C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_DIM=$'\033[2m'
else
    C_RESET=''; C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_DIM=''
fi

log()   { printf '%s[ha-mail]%s %s\n'        "${C_BLU}" "${C_RESET}" "$*" >&2; }
ok()    { printf '%s[  ok  ]%s %s\n'         "${C_GRN}" "${C_RESET}" "$*" >&2; }
warn()  { printf '%s[ warn ]%s %s\n'         "${C_YEL}" "${C_RESET}" "$*" >&2; }
err()   { printf '%s[ fail ]%s %s\n'         "${C_RED}" "${C_RESET}" "$*" >&2; }
dbg()   { [[ "${HAMAIL_DEBUG:-0}" == "1" ]] && printf '%s[ dbg  ] %s%s\n' "${C_DIM}" "$*" "${C_RESET}" >&2 || true; }
die()   { err "$*"; exit 1; }

trap 'err "aborted at ${BASH_SOURCE[0]}:${LINENO} (exit $?)"' ERR

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "this script must run as root (try: sudo $0)"
}

# ---------------------------------------------------------------------------
# RENDER_VARS
# ---------------------------------------------------------------------------
# The exhaustive whitelist of names bin/render.sh will substitute.
#
# WHY A WHITELIST: `envsubst` with no arguments replaces EVERY $NAME and
# ${NAME} it finds. Nginx configs are full of $host, $remote_addr,
# $upstream_addr; Postfix configs contain $mydomain, $myhostname; Dovecot
# uses %d/%n but also $mail_plugins. A naive `envsubst < tpl > out` silently
# blanks all of them and you get a mail server that half-works in ways that
# take a day to find. This list is the fix.
# ---------------------------------------------------------------------------
RENDER_VARS=(
    NODE_ROLE
    DOMAIN MAIL_HOST WEBMAIL_HOST ADMIN_HOST AUTOCONFIG_HOST ADMIN_EMAIL
    NODE_A_IP NODE_A_HOSTNAME NODE_A_SHORTNAME NODE_A_REGION
    NODE_A_DKIM_SELECTOR NODE_A_WG_IP NODE_A_IP6 NODE_A_SERVER_ID
    NODE_B_IP NODE_B_HOSTNAME NODE_B_SHORTNAME NODE_B_REGION
    NODE_B_DKIM_SELECTOR NODE_B_WG_IP NODE_B_IP6 NODE_B_SERVER_ID
    WG_INTERFACE WG_PORT WG_SUBNET WG_KEEPALIVE WG_PEER_PUBKEY WG_PRIVKEY
    DB_NAME DB_USER DB_PASS DB_RO_USER DB_RO_PASS
    DB_REPL_USER DB_REPL_PASS DB_ROOT_PASS
    RC_DB_NAME RC_DB_USER RC_DB_PASS
    POSTFIXADMIN_VERSION POSTFIXADMIN_ROOT ADMIN_USER ADMIN_PASS SETUP_PASS
    SETUP_PASS_HASH
    DEFAULT_QUOTA_MB MAX_QUOTA_MB DEFAULT_QUOTA_BYTES MAX_QUOTA_BYTES
    DEFAULT_DOMAIN_ALIASES DEFAULT_DOMAIN_MAILBOXES
    ROUNDCUBE_VERSION ROUNDCUBE_ROOT ROUNDCUBE_DES_KEY
    VMAIL_USER VMAIL_GROUP VMAIL_UID VMAIL_GID VMAIL_ROOT VMAIL_INDEX_ROOT
    DOVEADM_PORT DOVEADM_PASS REPL_MAX_CONNS REPL_SYNC_TIMEOUT
    REPL_FULL_SYNC_INTERVAL
    CERT_ROOT CERT_LIVE ACME_WEBROOT ACME_STAGING DH_BITS
    DKIM_MODE DKIM_KEY_BITS DKIM_PATH
    RSPAMD_PASS RSPAMD_PASS_HASH RSPAMD_WEB_PORT REDIS_BIND
    LINODE_API_TOKEN LINODE_DOMAIN_ID DNS_TTL
    TIMEZONE STATE_DIR LOG_DIR SSH_PORT ALERT_EMAIL
    # --- derived (see derive_vars) ---
    SELF_ROLE SELF_IP SELF_IP6 SELF_HOSTNAME SELF_SHORTNAME SELF_WG_IP
    SELF_SERVER_ID SELF_DKIM_SELECTOR SELF_AUTOINC_OFFSET SELF_REGION
    PEER_ROLE PEER_IP PEER_IP6 PEER_HOSTNAME PEER_SHORTNAME PEER_WG_IP
    PEER_SERVER_ID PEER_DKIM_SELECTOR PEER_REGION
    IS_CERT_LEADER IS_ADMIN_LEADER
)

# ---------------------------------------------------------------------------
# load_env <path-to-.env>
# ---------------------------------------------------------------------------
load_env() {
    local envfile="${1:-${HAMAIL_ROOT}/.env}"
    [[ -f "${envfile}" ]] || die "env file not found: ${envfile} (copy env.example to .env)"

    # Reject world/group-readable secrets before we source them.
    local mode
    mode="$(stat -c '%a' "${envfile}")"
    if [[ "${mode}" != "600" && "${mode}" != "400" ]]; then
        warn "${envfile} has mode ${mode}; tightening to 600"
        chmod 600 "${envfile}"
    fi

    # `set -a` exports everything the file defines. The file is deliberately
    # allowed to reference earlier variables (MAIL_HOST=mail.${DOMAIN}).
    set -a
    # shellcheck disable=SC1090
    source "${envfile}"
    set +a

    HAMAIL_ENV_FILE="${envfile}"
    export HAMAIL_ENV_FILE
    validate_env
    derive_vars
}

# ---------------------------------------------------------------------------
# validate_env - fail loudly and early, never half-deploy.
# ---------------------------------------------------------------------------
validate_env() {
    local missing=() v
    local required=(
        NODE_ROLE DOMAIN ADMIN_EMAIL
        NODE_A_IP NODE_A_HOSTNAME NODE_A_WG_IP NODE_A_DKIM_SELECTOR
        NODE_B_IP NODE_B_HOSTNAME NODE_B_WG_IP NODE_B_DKIM_SELECTOR
        DB_NAME DB_USER DB_PASS DB_RO_USER DB_RO_PASS
        DB_REPL_USER DB_REPL_PASS DB_ROOT_PASS
        RC_DB_NAME RC_DB_USER RC_DB_PASS
        ADMIN_USER ADMIN_PASS SETUP_PASS
        VMAIL_USER VMAIL_UID VMAIL_GID VMAIL_ROOT VMAIL_INDEX_ROOT
        DOVEADM_PORT DOVEADM_PASS
        ROUNDCUBE_DES_KEY RSPAMD_PASS
        MAIL_HOST WEBMAIL_HOST ADMIN_HOST
    )
    for v in "${required[@]}"; do
        [[ -n "${!v:-}" ]] || missing+=("${v}")
    done
    ((${#missing[@]} == 0)) || die "missing required variables: ${missing[*]}"

    [[ "${NODE_ROLE}" == "A" || "${NODE_ROLE}" == "B" ]] \
        || die "NODE_ROLE must be exactly 'A' or 'B' (got: ${NODE_ROLE})"

    [[ "${#ROUNDCUBE_DES_KEY}" -eq 24 ]] \
        || die "ROUNDCUBE_DES_KEY must be exactly 24 characters (got ${#ROUNDCUBE_DES_KEY})"

    # Refuse to deploy with shipped placeholder secrets.
    local leaked=()
    for v in DB_PASS DB_RO_PASS DB_REPL_PASS DB_ROOT_PASS RC_DB_PASS \
             ADMIN_PASS SETUP_PASS DOVEADM_PASS RSPAMD_PASS ROUNDCUBE_DES_KEY; do
        [[ "${!v}" == CHANGE_ME* ]] && leaked+=("${v}")
    done
    ((${#leaked[@]} == 0)) \
        || die "these still hold placeholder values: ${leaked[*]} (run bin/gen-secrets.sh)"

    # Password length floor. Everything here is machine-generated in practice.
    for v in DB_PASS DB_REPL_PASS DB_ROOT_PASS DOVEADM_PASS ADMIN_PASS; do
        local val="${!v}"
        [[ "${#val}" -ge 12 ]] || die "${v} must be at least 12 characters"
    done

    valid_ipv4 "${NODE_A_IP}" || die "NODE_A_IP is not a valid IPv4 address: ${NODE_A_IP}"
    valid_ipv4 "${NODE_B_IP}" || die "NODE_B_IP is not a valid IPv4 address: ${NODE_B_IP}"
    valid_ipv4 "${NODE_A_WG_IP}" || die "NODE_A_WG_IP invalid: ${NODE_A_WG_IP}"
    valid_ipv4 "${NODE_B_WG_IP}" || die "NODE_B_WG_IP invalid: ${NODE_B_WG_IP}"
    [[ "${NODE_A_IP}" != "${NODE_B_IP}" ]] || die "NODE_A_IP and NODE_B_IP are identical"
    [[ "${NODE_A_DKIM_SELECTOR}" != "${NODE_B_DKIM_SELECTOR}" || "${DKIM_MODE}" == "shared" ]] \
        || die "DKIM selectors must differ when DKIM_MODE=distinct"

    ok "environment validated (node ${NODE_ROLE}, domain ${DOMAIN})"
}

valid_ipv4() {
    local ip="$1" o
    [[ "${ip}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS='.' read -r -a _octets <<< "${ip}"
    for o in "${_octets[@]}"; do
        ((o >= 0 && o <= 255)) || return 1
    done
    return 0
}

# ---------------------------------------------------------------------------
# derive_vars - turn NODE_ROLE into SELF_* / PEER_* so that every template is
# written exactly once and is identical on both machines.
# ---------------------------------------------------------------------------
derive_vars() {
    if [[ "${NODE_ROLE}" == "A" ]]; then
        SELF_ROLE=A;                        PEER_ROLE=B
        SELF_IP="${NODE_A_IP}";             PEER_IP="${NODE_B_IP}"
        SELF_IP6="${NODE_A_IP6:-}";         PEER_IP6="${NODE_B_IP6:-}"
        SELF_HOSTNAME="${NODE_A_HOSTNAME}"; PEER_HOSTNAME="${NODE_B_HOSTNAME}"
        SELF_SHORTNAME="${NODE_A_SHORTNAME}"; PEER_SHORTNAME="${NODE_B_SHORTNAME}"
        SELF_WG_IP="${NODE_A_WG_IP}";       PEER_WG_IP="${NODE_B_WG_IP}"
        SELF_SERVER_ID="${NODE_A_SERVER_ID}"; PEER_SERVER_ID="${NODE_B_SERVER_ID}"
        SELF_DKIM_SELECTOR="${NODE_A_DKIM_SELECTOR}"; PEER_DKIM_SELECTOR="${NODE_B_DKIM_SELECTOR}"
        SELF_REGION="${NODE_A_REGION}";     PEER_REGION="${NODE_B_REGION}"
        SELF_AUTOINC_OFFSET=1
        IS_CERT_LEADER=1
        IS_ADMIN_LEADER=1
    else
        SELF_ROLE=B;                        PEER_ROLE=A
        SELF_IP="${NODE_B_IP}";             PEER_IP="${NODE_A_IP}"
        SELF_IP6="${NODE_B_IP6:-}";         PEER_IP6="${NODE_A_IP6:-}"
        SELF_HOSTNAME="${NODE_B_HOSTNAME}"; PEER_HOSTNAME="${NODE_A_HOSTNAME}"
        SELF_SHORTNAME="${NODE_B_SHORTNAME}"; PEER_SHORTNAME="${NODE_A_SHORTNAME}"
        SELF_WG_IP="${NODE_B_WG_IP}";       PEER_WG_IP="${NODE_A_WG_IP}"
        SELF_SERVER_ID="${NODE_B_SERVER_ID}"; PEER_SERVER_ID="${NODE_A_SERVER_ID}"
        SELF_DKIM_SELECTOR="${NODE_B_DKIM_SELECTOR}"; PEER_DKIM_SELECTOR="${NODE_A_DKIM_SELECTOR}"
        SELF_REGION="${NODE_B_REGION}";     PEER_REGION="${NODE_A_REGION}"
        SELF_AUTOINC_OFFSET=2
        IS_CERT_LEADER=0
        IS_ADMIN_LEADER=0
    fi

    # Quotas are configured in MiB but consumed in bytes by Dovecot/PostfixAdmin.
    DEFAULT_QUOTA_BYTES=$(( ${DEFAULT_QUOTA_MB:-0} * 1024 * 1024 ))
    MAX_QUOTA_BYTES=$(( ${MAX_QUOTA_MB:-0} * 1024 * 1024 ))

    # Defaults for anything the operator may have omitted.
    : "${WG_INTERFACE:=wg0}"
    : "${WG_PORT:=51820}"
    : "${WG_SUBNET:=10.77.0.0/24}"
    : "${WG_KEEPALIVE:=25}"
    : "${WG_PEER_PUBKEY:=}"
    : "${WG_PRIVKEY:=}"
    : "${STATE_DIR:=/var/lib/ha-mail}"
    : "${LOG_DIR:=/var/log/ha-mail}"
    : "${SSH_PORT:=22}"
    : "${DNS_TTL:=300}"
    : "${TIMEZONE:=UTC}"
    : "${DH_BITS:=2048}"
    : "${ACME_STAGING:=0}"
    : "${DKIM_MODE:=distinct}"
    : "${DKIM_KEY_BITS:=2048}"
    : "${DKIM_PATH:=/var/lib/rspamd/dkim}"
    : "${ACME_WEBROOT:=/var/www/letsencrypt}"
    : "${CERT_ROOT:=/etc/letsencrypt}"
    : "${CERT_LIVE:=${CERT_ROOT}/live/${MAIL_HOST}}"
    : "${REPL_MAX_CONNS:=6}"
    : "${REPL_SYNC_TIMEOUT:=120}"
    : "${REPL_FULL_SYNC_INTERVAL:=4h}"
    : "${RSPAMD_WEB_PORT:=11334}"
    : "${REDIS_BIND:=127.0.0.1}"
    : "${LINODE_API_TOKEN:=}"
    : "${LINODE_DOMAIN_ID:=}"
    : "${ALERT_EMAIL:=root@localhost}"
    : "${SETUP_PASS_HASH:=}"
    : "${RSPAMD_PASS_HASH:=}"
    : "${POSTFIXADMIN_ROOT:=/opt/postfixadmin}"
    : "${ROUNDCUBE_ROOT:=/opt/roundcube}"
    : "${AUTOCONFIG_HOST:=autoconfig.${DOMAIN}}"

    export SELF_ROLE SELF_IP SELF_IP6 SELF_HOSTNAME SELF_SHORTNAME SELF_WG_IP \
           SELF_SERVER_ID SELF_DKIM_SELECTOR SELF_AUTOINC_OFFSET SELF_REGION \
           PEER_ROLE PEER_IP PEER_IP6 PEER_HOSTNAME PEER_SHORTNAME PEER_WG_IP \
           PEER_SERVER_ID PEER_DKIM_SELECTOR PEER_REGION \
           IS_CERT_LEADER IS_ADMIN_LEADER \
           DEFAULT_QUOTA_BYTES MAX_QUOTA_BYTES \
           WG_INTERFACE WG_PORT WG_SUBNET WG_KEEPALIVE WG_PEER_PUBKEY WG_PRIVKEY \
           STATE_DIR LOG_DIR SSH_PORT DNS_TTL TIMEZONE DH_BITS ACME_STAGING \
           DKIM_MODE DKIM_KEY_BITS DKIM_PATH ACME_WEBROOT CERT_ROOT CERT_LIVE \
           REPL_MAX_CONNS REPL_SYNC_TIMEOUT REPL_FULL_SYNC_INTERVAL \
           RSPAMD_WEB_PORT REDIS_BIND LINODE_API_TOKEN LINODE_DOMAIN_ID \
           ALERT_EMAIL SETUP_PASS_HASH RSPAMD_PASS_HASH \
           POSTFIXADMIN_ROOT ROUNDCUBE_ROOT AUTOCONFIG_HOST

    dbg "self=${SELF_HOSTNAME}(${SELF_IP}) peer=${PEER_HOSTNAME}(${PEER_IP})"
}

# ---------------------------------------------------------------------------
# render <template> <destination> [mode] [owner:group]
# Whitelisted envsubst + atomic install + change detection.
# Returns 0 always; sets RENDER_CHANGED=1 when the destination differed.
# ---------------------------------------------------------------------------
RENDER_CHANGED=0
render() {
    local tpl="$1" dest="$2" mode="${3:-0644}" owner="${4:-root:root}"
    [[ -f "${tpl}" ]] || die "template missing: ${tpl}"

    local varspec=""
    local v
    for v in "${RENDER_VARS[@]}"; do
        varspec+="\${${v}} "
    done

    local tmp
    tmp="$(mktemp "${dest}.hamail.XXXXXX")"
    # envsubst with an explicit SHELL-FORMAT only touches the listed names.
    envsubst "${varspec}" < "${tpl}" > "${tmp}"

    # Fail fast on any variable that survived unsubstituted. This catches the
    # "added a var to env.example but forgot RENDER_VARS" class of bug at
    # deploy time instead of at 3am.
    if grep -nE '\$\{[A-Z][A-Z0-9_]*\}' "${tmp}" >/dev/null; then
        local stray
        stray="$(grep -ohE '\$\{[A-Z][A-Z0-9_]*\}' "${tmp}" | sort -u | tr '\n' ' ')"
        rm -f "${tmp}"
        die "unsubstituted variables in ${tpl}: ${stray} (add them to RENDER_VARS in lib/common.sh)"
    fi

    mkdir -p "$(dirname -- "${dest}")"
    if [[ -f "${dest}" ]] && cmp -s "${tmp}" "${dest}"; then
        rm -f "${tmp}"
        chmod "${mode}" "${dest}"
        chown "${owner}" "${dest}"
        dbg "unchanged: ${dest}"
        RENDER_CHANGED=0
        return 0
    fi

    if [[ -f "${dest}" && ! -f "${dest}.hamail-orig" ]]; then
        cp -a "${dest}" "${dest}.hamail-orig"
        dbg "backed up original: ${dest}.hamail-orig"
    fi

    chmod "${mode}" "${tmp}"
    chown "${owner}" "${tmp}"
    mv -f "${tmp}" "${dest}"
    ok "wrote ${dest}"
    RENDER_CHANGED=1
    return 0
}

# render_dir <template-subdir> <dest-dir> [mode] [owner]
# Renders every *.tpl in a directory, stripping the .tpl suffix, and copies
# non-.tpl files verbatim.
render_dir() {
    local src="$1" dst="$2" mode="${3:-0644}" owner="${4:-root:root}" f base
    [[ -d "${src}" ]] || die "template dir missing: ${src}"
    mkdir -p "${dst}"
    shopt -s nullglob
    for f in "${src}"/*; do
        [[ -f "${f}" ]] || continue
        base="$(basename -- "${f}")"
        if [[ "${base}" == *.tpl ]]; then
            render "${f}" "${dst}/${base%.tpl}" "${mode}" "${owner}"
        else
            install -m "${mode}" -o "${owner%%:*}" -g "${owner##*:}" "${f}" "${dst}/${base}"
            ok "wrote ${dst}/${base}"
        fi
    done
    shopt -u nullglob
}

# ---------------------------------------------------------------------------
# Small helpers used across installers
# ---------------------------------------------------------------------------

# mysql_root <<< "SQL"  - run SQL as root using the unix_socket plugin.
mysql_root() {
    mariadb --protocol=socket -uroot "$@"
}

# svc_restart_if_changed <unit>  - restart only when RENDER_CHANGED was set.
svc_reload() {
    local unit="$1"
    if systemctl is-active --quiet "${unit}"; then
        systemctl reload-or-restart "${unit}" && ok "reloaded ${unit}"
    else
        systemctl enable --now "${unit}" && ok "started ${unit}"
    fi
}

# wait_for_port <host> <port> <timeout-seconds>
wait_for_port() {
    local host="$1" port="$2" timeout="${3:-30}" i
    for ((i = 0; i < timeout; i++)); do
        if timeout 2 bash -c ">/dev/tcp/${host}/${port}" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# apt_install <pkg...>  - non-interactive, idempotent.
apt_install() {
    local missing=() p
    for p in "$@"; do
        dpkg-query -W -f='${Status}' "${p}" 2>/dev/null | grep -q "ok installed" || missing+=("${p}")
    done
    if ((${#missing[@]})); then
        log "installing: ${missing[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
    else
        dbg "already installed: $*"
    fi
}

# randpw <length>
# Bounded read first, `cut` last: `tr ... | head -c N` gives tr a SIGPIPE, and
# under `set -o pipefail` that aborts the calling script silently.
randpw() {
    local n="${1:-32}"
    head -c "$(( n * 8 ))" /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c "1-${n}"
}

# ensure_dir <path> <mode> <owner:group>
ensure_dir() {
    local path="$1" mode="${2:-0755}" owner="${3:-root:root}"
    mkdir -p "${path}"
    chmod "${mode}" "${path}"
    chown "${owner}" "${path}"
}

# peer_ssh <command...>  - run a command on the peer over the tunnel.
peer_ssh() {
    ssh -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 \
        -o ServerAliveInterval=10 \
        -o ServerAliveCountMax=3 \
        -p "${SSH_PORT}" \
        -i /root/.ssh/id_ed25519_hamail \
        "root@${PEER_WG_IP}" "$@"
}

# lockfile <name> - flock-based single-instance guard for cron-driven scripts.
# Usage: lockfile cert-sync || exit 0
lockfile() {
    local name="$1"
    local lock="/run/ha-mail-${name}.lock"
    exec {HAMAIL_LOCK_FD}>"${lock}"
    flock -n "${HAMAIL_LOCK_FD}" || return 1
    return 0
}
