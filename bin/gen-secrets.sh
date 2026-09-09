#!/usr/bin/env bash
##############################################################################
# ha-mail :: bin/gen-secrets.sh
#
# Fills every CHANGE_ME_* placeholder in a .env with a strong random value.
#
# Run this ONCE, on ONE machine, then copy the resulting .env to the other
# node and change ONLY the NODE_ROLE line. Every secret except NODE_ROLE must
# be byte-identical on both nodes:
#   - DB_* : replication users authenticate in both directions
#   - DOVEADM_PASS : dsync is mutually authenticated
#   - ROUNDCUBE_DES_KEY : encrypts the IMAP password inside the session
#   - SETUP_PASS : PostfixAdmin setup gate
#
# Usage:  ./bin/gen-secrets.sh [path/to/.env]
##############################################################################

set -Eeuo pipefail
trap 'echo "[gen-secrets] failed at line ${LINENO} (exit $?)" >&2' ERR
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${1:-${REPO_ROOT}/.env}"

if [[ ! -f "${ENV_FILE}" ]]; then
    if [[ -f "${REPO_ROOT}/env.example" ]]; then
        cp "${REPO_ROOT}/env.example" "${ENV_FILE}"
        chmod 600 "${ENV_FILE}"
        echo "[gen-secrets] created ${ENV_FILE} from env.example" >&2
    else
        echo "[gen-secrets] no ${ENV_FILE} and no env.example to copy" >&2
        exit 1
    fi
fi

# NOTE: deliberately NOT `tr -dc ... < /dev/urandom | head -c N`.
# `head` closes the pipe after N bytes, `tr` dies of SIGPIPE, and under
# `set -o pipefail` the whole script exits with no output and no changes -
# a silent failure that looks exactly like "it worked".
# Bounding the read with head FIRST and terminating with `cut` (which consumes
# all of its input) means no process is ever killed by a closed pipe.
randstr() {
    local n="$1"
    head -c "$(( n * 8 ))" /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c "1-${n}"
}

# Fixed-length secrets. Roundcube's DES key is exactly 24 chars by contract.
declare -A LENGTHS=(
    [DB_PASS]=32
    [DB_RO_PASS]=32
    [DB_REPL_PASS]=32
    [DB_ROOT_PASS]=32
    [RC_DB_PASS]=32
    [ADMIN_PASS]=20
    [SETUP_PASS]=24
    [DOVEADM_PASS]=40
    [RSPAMD_PASS]=32
    [ROUNDCUBE_DES_KEY]=24
)

cp -a "${ENV_FILE}" "${ENV_FILE}.bak.$(date +%Y%m%d%H%M%S)"

changed=0
for key in "${!LENGTHS[@]}"; do
    current="$(grep -E "^${key}=" "${ENV_FILE}" | head -n1 | cut -d= -f2- || true)"
    if [[ -z "${current}" || "${current}" == CHANGE_ME* ]]; then
        value="$(randstr "${LENGTHS[$key]}")"
        # Use a delimiter that cannot appear in an alphanumeric secret.
        sed -i "s|^${key}=.*|${key}=${value}|" "${ENV_FILE}"
        printf '[gen-secrets] set %-22s (%d chars)\n' "${key}" "${LENGTHS[$key]}" >&2
        changed=$((changed + 1))
    else
        printf '[gen-secrets] kept %-22s (already set)\n' "${key}" >&2
    fi
done

chmod 600 "${ENV_FILE}"

cat >&2 <<EOF

[gen-secrets] ${changed} secret(s) generated in ${ENV_FILE}

NEXT STEPS
  1. Edit ${ENV_FILE} and set: DOMAIN, NODE_A_IP, NODE_B_IP,
     NODE_A_HOSTNAME, NODE_B_HOSTNAME, ADMIN_EMAIL, ADMIN_USER.
  2. Copy this exact file to BOTH nodes:
        scp ${ENV_FILE} root@NODE_A:/opt/ha-mail/.env
        scp ${ENV_FILE} root@NODE_B:/opt/ha-mail/.env
  3. On Node B ONLY, change the single line:  NODE_ROLE=B
  4. Run ./deploy.sh on Node A first, then on Node B.

Do not commit ${ENV_FILE} to version control.
EOF
