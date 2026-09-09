#!/usr/bin/env bash
##############################################################################
# ha-mail :: /usr/local/bin/hamail-add-domain.sh <newdomain.tld>
#
# Everything a NEW hosted domain needs that the admin portal cannot do for
# itself. The portal handles the database side (domain, mailboxes, aliases);
# this handles the two things that live outside the database:
#
#   1. a DKIM key pair and selector for THIS node
#   2. a TLS certificate covering the new domain's service names
#
# RUN IT ON BOTH NODES. Each generates its own DKIM key under its own
# selector, so you will publish two TXT records for the new domain - exactly
# as for the primary domain. Nothing is copied between the nodes.
##############################################################################

set -Eeuo pipefail

NEWDOMAIN="${1:-}"
[[ -n "$NEWDOMAIN" ]] || { printf 'usage: %s <domain.tld>\n' "$0" >&2; exit 64; }
[[ "$NEWDOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
    || { printf 'not a valid domain: %s\n' "$NEWDOMAIN" >&2; exit 64; }

SELF_DKIM_SELECTOR="${SELF_DKIM_SELECTOR}"
PEER_DKIM_SELECTOR="${PEER_DKIM_SELECTOR}"
DKIM_PATH="${DKIM_PATH}"
DKIM_KEY_BITS="${DKIM_KEY_BITS}"
ACME_WEBROOT="${ACME_WEBROOT}"
ADMIN_EMAIL="${ADMIN_EMAIL}"
IS_CERT_LEADER="${IS_CERT_LEADER}"
NODE_A_IP="${NODE_A_IP}"
NODE_B_IP="${NODE_B_IP}"
SELF_ROLE="${SELF_ROLE}"

key="$DKIM_PATH/$SELF_DKIM_SELECTOR.$NEWDOMAIN.key"

# ---------------------------------------------------------------------------
# 1. DKIM
# ---------------------------------------------------------------------------
if [[ -f "$key" ]]; then
    printf 'DKIM key already exists: %s\n' "$key"
else
    install -d -m 0750 -o _rspamd -g _rspamd "$DKIM_PATH"
    openssl genrsa -out "$key" "$DKIM_KEY_BITS" 2>/dev/null
    chown _rspamd:_rspamd "$key"
    chmod 0400 "$key"
    printf 'generated %s\n' "$key"
fi

pub="$(openssl rsa -in "$key" -pubout -outform PEM 2>/dev/null | sed '1d;$d' | tr -d '\n')"

# ---------------------------------------------------------------------------
# 2. Tell rspamd about it.
# ---------------------------------------------------------------------------
# dkim_signing.conf already interpolates $selector.$domain into the key path,
# so no configuration change is needed - only a reload so rspamd re-reads the
# directory. Adding a domain never requires editing a config file.
systemctl reload rspamd 2>/dev/null || systemctl restart rspamd

# ---------------------------------------------------------------------------
# 3. TLS certificate for the new domain's service names (leader only).
# ---------------------------------------------------------------------------
# shellcheck disable=SC2050  # baked in at render time from NODE_ROLE - the constant IS the guarantee
if [[ "$IS_CERT_LEADER" == "1" ]]; then
    certbot certonly --webroot -w "$ACME_WEBROOT" \
        --non-interactive --agree-tos --email "$ADMIN_EMAIL" \
        --cert-name "mail.$NEWDOMAIN" \
        -d "mail.$NEWDOMAIN" -d "webmail.$NEWDOMAIN" -d "autoconfig.$NEWDOMAIN" \
        || printf 'certbot failed - are the DNS records for mail.%s published yet?\n' "$NEWDOMAIN" >&2
    /usr/local/bin/hamail-sni-map.sh
else
    printf 'This node is the ACME follower; the certificate is issued on the leader\n'
    printf 'and pulled by hamail-cert-sync.sh. Run this script on the leader too.\n'
fi

# ---------------------------------------------------------------------------
# 4. Print the DNS the operator must publish.
# ---------------------------------------------------------------------------
cat <<DNSRECORDS

=============================================================================
DNS RECORDS TO PUBLISH FOR $NEWDOMAIN
=============================================================================

MX   @    10 <node A hostname>.
MX   @    10 <node B hostname>.

A    mail       $NODE_A_IP
A    mail       $NODE_B_IP
A    webmail    $NODE_A_IP
A    webmail    $NODE_B_IP
A    autoconfig $NODE_A_IP
A    autoconfig $NODE_B_IP

TXT  @    "v=spf1 ip4:$NODE_A_IP ip4:$NODE_B_IP -all"

TXT  $SELF_DKIM_SELECTOR._domainkey    "v=DKIM1; k=rsa; p=$pub"

  ...and the matching record for the OTHER node's selector
  ($PEER_DKIM_SELECTOR._domainkey), which you get by running this same
  script there. Both must be published before you enforce DMARC, or mail
  sent from one of the two nodes will fail alignment.

TXT  _dmarc   "v=DMARC1; p=none; rua=mailto:dmarc@$NEWDOMAIN; adkim=r; aspf=r"

Start DMARC at p=none, read the aggregate reports for two weeks to confirm
BOTH selectors are passing, and only then move to p=quarantine and p=reject.
=============================================================================

DNSRECORDS
