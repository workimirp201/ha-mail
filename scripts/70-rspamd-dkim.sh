#!/usr/bin/env bash
##############################################################################
# ha-mail :: scripts/70-rspamd-dkim.sh
# rspamd (spam filtering, DKIM signing, ARC sealing) and this node's DKIM key.
##############################################################################

set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
load_env "${HAMAIL_ENV_FILE:-${HAMAIL_ROOT}/.env}"
require_root

log "configuring rspamd and DKIM (mode: ${DKIM_MODE}, selector: ${SELF_DKIM_SELECTOR})"

# ---------------------------------------------------------------------------
# Redis - node-local, loopback only.
# ---------------------------------------------------------------------------
sed -i "s/^# *bind .*/bind ${REDIS_BIND} -::1/" /etc/redis/redis.conf
sed -i 's/^# *protected-mode .*/protected-mode yes/' /etc/redis/redis.conf
grep -q '^maxmemory ' /etc/redis/redis.conf || cat >> /etc/redis/redis.conf <<'REDIS'

# ha-mail: bound memory for Bayes tokens and ratelimit counters. allkeys-lru
# means a full Redis degrades classifier accuracy instead of failing writes -
# on a mail server, degrading is always better than erroring.
maxmemory 256mb
maxmemory-policy allkeys-lru
REDIS
systemctl enable --now redis-server
systemctl restart redis-server
ok "Redis running on ${REDIS_BIND}"

# ---------------------------------------------------------------------------
# Controller password hash
# ---------------------------------------------------------------------------
# rspamadm produces a PBKDF-based hash so the plaintext never lands in a
# config file. Exported for the template render below.
SETUP_HASH="$(rspamadm pw --encrypt -p "${RSPAMD_PASS}" 2>/dev/null | tr -d '\n')"
RSPAMD_PASS_HASH="${SETUP_HASH}"
export RSPAMD_PASS_HASH

ensure_dir /etc/rspamd/local.d 0755 root:root
for f in "${HAMAIL_TEMPLATES}"/rspamd/local.d/*.tpl; do
    base="$(basename "${f}" .tpl)"
    render "${f}" "/etc/rspamd/local.d/${base}" 0644 root:root
done
ok "rspamd configuration written"

# ---------------------------------------------------------------------------
# DKIM KEY
# ---------------------------------------------------------------------------
ensure_dir "${DKIM_PATH}" 0750 _rspamd:_rspamd

KEY="${DKIM_PATH}/${SELF_DKIM_SELECTOR}.${DOMAIN}.key"

if [[ "${DKIM_MODE}" == "shared" ]]; then
    # Shared-key mode: Node A generates, Node B receives a copy over the
    # tunnel. Both then sign under the SAME selector, so only one TXT record
    # is published.
    #
    # The trade-off, stated honestly: the private key crosses the network and
    # exists in two places, and a compromise of either node requires rotating
    # for both. The default (distinct) avoids that entirely.
    if [[ "${SELF_ROLE}" == "A" ]]; then
        [[ -f "${KEY}" ]] || openssl genrsa -out "${KEY}" "${DKIM_KEY_BITS}" 2>/dev/null
    else
        if [[ ! -f "${KEY}" ]]; then
            log "pulling the shared DKIM key from ${PEER_HOSTNAME}"
            peer_ssh "cat ${DKIM_PATH}/${NODE_A_DKIM_SELECTOR}.${DOMAIN}.key" > "${KEY}" \
                || die "could not fetch the shared DKIM key from the peer"
        fi
    fi
else
    # Distinct-key mode (the default and the recommendation).
    # Each node generates its own key locally. Nothing is ever transferred.
    if [[ ! -f "${KEY}" ]]; then
        openssl genrsa -out "${KEY}" "${DKIM_KEY_BITS}" 2>/dev/null
        ok "generated a ${DKIM_KEY_BITS}-bit DKIM key for selector ${SELF_DKIM_SELECTOR}"
    fi
fi

chown _rspamd:_rspamd "${KEY}"
chmod 0400 "${KEY}"

PUB="$(openssl rsa -in "${KEY}" -pubout -outform PEM 2>/dev/null | sed '1d;$d' | tr -d '\n')"
printf 'v=DKIM1; k=rsa; p=%s\n' "${PUB}" > "${STATE_DIR}/dkim-${SELF_DKIM_SELECTOR}.txt"

systemctl enable --now rspamd
systemctl restart rspamd
wait_for_port 127.0.0.1 11332 20 || die "rspamd milter is not listening on 11332"
ok "rspamd running"

# ---------------------------------------------------------------------------
# Publish instructions
# ---------------------------------------------------------------------------
cat >&2 <<NOTE

  ---------------------------------------------------------------------------
  DKIM RECORD TO PUBLISH FOR THIS NODE

  Name:  ${SELF_DKIM_SELECTOR}._domainkey.${DOMAIN}
  Type:  TXT
  Value: v=DKIM1; k=rsa; p=${PUB}

  (also saved to ${STATE_DIR}/dkim-${SELF_DKIM_SELECTOR}.txt)

  A ${DKIM_KEY_BITS}-bit key exceeds the 255-character limit of a single TXT
  string. Most DNS providers - Linode included - split it automatically. If
  yours does not, enter it as multiple quoted strings on one record:
      "v=DKIM1; k=rsa; p=FIRST_HALF" "SECOND_HALF"
  A record that is silently truncated verifies as a syntactically valid but
  WRONG key, and every message you send fails DKIM. hamail-health.sh compares
  the published record against the local key on every run precisely to catch
  this.

  BOTH nodes' selectors must be published before you move DMARC past p=none.
  ---------------------------------------------------------------------------

NOTE
