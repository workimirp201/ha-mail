#!/usr/bin/env bash
##############################################################################
# ha-mail :: deploy.sh
#
# Orchestrates a full node build. Idempotent - safe to re-run.
#
#   ./deploy.sh                 run every stage in order
#   ./deploy.sh --from 55       resume from a given stage
#   ./deploy.sh --only 60       run a single stage
#   ./deploy.sh --list          show the stages
#   ./deploy.sh --dry-run       render every template to /tmp and stop
#
# ---------------------------------------------------------------------------
# THE ORDER TO BUILD A PAIR
# ---------------------------------------------------------------------------
# The two nodes are NOT symmetric during the build, even though they are
# symmetric afterwards. Node A creates the schema and issues the shared
# certificate; Node B receives both. Build them in this order:
#
#   NODE A   ./deploy.sh --to 20        (through WireGuard key generation)
#   NODE B   ./deploy.sh --to 20
#            -> exchange the two WireGuard public keys into both .env files
#            -> exchange the two SSH public keys into both authorized_keys
#   NODE A   ./deploy.sh --from 20
#   NODE B   ./deploy.sh --from 20
#
# Running Node B's full deploy before Node A's has finished is the most
# common way to end up with two independently created schemas.
##############################################################################

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

STAGES=(
    "00:preflight:00-preflight.sh"
    "10:base system:10-base-system.sh"
    "20:wireguard tunnel:20-wireguard.sh"
    "30:firewall:30-firewall.sh"
    "40:mariadb:40-mariadb.sh"
    "45:database schema (node A only):45-db-schema.sh"
    "50:replication:50-replication.sh"
    "55:postfix:55-postfix.sh"
    "60:dovecot:60-dovecot.sh"
    "70:rspamd and dkim:70-rspamd-dkim.sh"
    "80:nginx and php:80-nginx-php.sh"
    "75:tls certificates:75-certbot.sh"
    "85:admin portal:85-postfixadmin.sh"
    "90:webmail:90-roundcube.sh"
    "95:fail2ban:95-fail2ban.sh"
    "99:finalize:99-finalize.sh"
)

# NOTE the deliberate 80-before-75 ordering above: Certbot's HTTP-01 challenge
# needs nginx already serving the webroot on port 80, so the web server must be
# up before certificates are requested. The numbers are kept as-is because they
# name the files; the array defines the actual execution order.

usage() {
    cat <<'USAGE'
Usage: ./deploy.sh [options]

  --list             list stages in execution order
  --from <id>        start at this stage
  --to <id>          stop after this stage
  --only <id>        run exactly one stage
  --env <file>       .env path (default: ./.env)
  --dry-run          render every template into a scratch tree and exit
  --yes              do not prompt for confirmation
USAGE
}

ENV_FILE="${SCRIPT_DIR}/.env"
FROM=""; TO=""; ONLY=""; DRY=0; ASSUME_YES=0

while (($#)); do
    case "$1" in
        --list)    LIST=1; shift ;;
        --from)    FROM="$2"; shift 2 ;;
        --to)      TO="$2"; shift 2 ;;
        --only)    ONLY="$2"; shift 2 ;;
        --env)     ENV_FILE="$2"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        --yes|-y)  ASSUME_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

if [[ -n "${LIST:-}" ]]; then
    printf 'Execution order:\n\n'
    for s in "${STAGES[@]}"; do
        IFS=':' read -r id label _ <<< "${s}"
        printf '  %-4s %s\n' "${id}" "${label}"
    done
    exit 0
fi

export HAMAIL_ENV_FILE="${ENV_FILE}"
load_env "${ENV_FILE}"
require_root

if (( DRY )); then
    out="/tmp/hamail-dryrun-${SELF_ROLE}"
    rm -rf "${out}"
    "${SCRIPT_DIR}/bin/render.sh" --all --out "${out}" --env "${ENV_FILE}"
    ok "rendered into ${out} - nothing on this system was changed"
    exit 0
fi

# ---------------------------------------------------------------------------
# Confirmation. This script rewrites /etc/postfix, /etc/dovecot, /etc/nginx,
# /etc/mysql and the firewall. Saying so out loud is cheap.
# ---------------------------------------------------------------------------
if (( ! ASSUME_YES )); then
    cat >&2 <<CONFIRM

  About to deploy ha-mail on this machine:

    node            ${SELF_ROLE}  (${SELF_HOSTNAME}, ${SELF_IP})
    peer            ${PEER_ROLE}  (${PEER_HOSTNAME}, ${PEER_IP})
    primary domain  ${DOMAIN}
    server_id       ${SELF_SERVER_ID}, auto_increment_offset ${SELF_AUTOINC_OFFSET}
    DKIM selector   ${SELF_DKIM_SELECTOR}
    ACME role       $( [[ "${IS_CERT_LEADER}" == "1" ]] && echo "LEADER" || echo "follower" )

  This REPLACES the configuration of postfix, dovecot, mariadb, nginx, rspamd
  and ufw on this host. Originals are saved alongside as *.hamail-orig.

CONFIRM
    read -r -p "  Type the node role (A or B) to confirm: " answer
    [[ "${answer}" == "${SELF_ROLE}" ]] || die "aborted"
fi

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
started=0
[[ -z "${FROM}" ]] && started=1

for s in "${STAGES[@]}"; do
    IFS=':' read -r id label file <<< "${s}"

    if [[ -n "${ONLY}" ]]; then
        [[ "${id}" == "${ONLY}" ]] || continue
    else
        [[ "${id}" == "${FROM}" ]] && started=1
        (( started )) || continue
    fi

    printf '\n' >&2
    log "=== stage ${id}: ${label} ==="
    if ! "${SCRIPT_DIR}/scripts/${file}"; then
        err "stage ${id} (${label}) FAILED"
        err "fix the problem, then resume with:  ./deploy.sh --from ${id}"
        exit 1
    fi

    if [[ -n "${TO}" && "${id}" == "${TO}" ]]; then
        ok "stopped after stage ${id} as requested"
        exit 0
    fi
done

ok "deployment complete on node ${SELF_ROLE}"
