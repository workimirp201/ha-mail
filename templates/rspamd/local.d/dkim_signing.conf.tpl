##############################################################################
# ha-mail :: /etc/rspamd/local.d/dkim_signing.conf
# Node ${SELF_ROLE} - signs with selector "${SELF_DKIM_SELECTOR}"
#
#            *** DKIM ALIGNMENT ACROSS TWO NODES ***
#
# THE PROBLEM
# Either node may dispatch any user's outbound mail: the MX records are equal
# priority, users' MUAs round-robin between the two submission hosts, and a
# failover moves everyone to the survivor. So the recipient's DMARC evaluation
# must succeed identically whether ${NODE_A_HOSTNAME} or ${NODE_B_HOSTNAME}
# sent the message.
#
# THE SOLUTION USED HERE (DKIM_MODE=${DKIM_MODE})
# Each node holds its OWN private key under its OWN selector, and BOTH public
# keys are published in DNS:
#
#     ${NODE_A_DKIM_SELECTOR}._domainkey.${DOMAIN}   IN TXT "v=DKIM1; k=rsa; p=<node A public key>"
#     ${NODE_B_DKIM_SELECTOR}._domainkey.${DOMAIN}   IN TXT "v=DKIM1; k=rsa; p=<node B public key>"
#
# DMARC alignment does NOT depend on the selector. It compares the DOMAIN in
# the DKIM d= tag against the domain in the From: header. Both nodes sign with
# d=${DOMAIN}, so both align, and the recipient does not care which selector
# was used. The selector only tells the verifier which public key to fetch.
#
# WHY NOT ONE SHARED KEY
#   * A shared key must be copied between the nodes, so the private key exists
#     on the wire and in whatever transferred it. Two keys never move.
#   * Rotation with a shared key is an atomic two-node operation. With
#     separate selectors you rotate one node, verify it, then the other.
#   * If one node is compromised you revoke ONE selector by deleting one TXT
#     record. Mail from the other node keeps flowing, signed and aligned.
# If you set DKIM_MODE=shared, scripts/70-rspamd-dkim.sh copies Node A's key
# to Node B and both use selector ${NODE_A_DKIM_SELECTOR}. That works, and the
# DNS is simpler; the trade-offs above are the price.
#
# MULTI-DOMAIN
# The path below is templated on $domain, so a domain added later through the
# admin portal only needs its key generated (bin/dkim-add-domain.sh) - no
# rspamd configuration change and no restart.
##############################################################################

enabled = true;

# Sign mail from authenticated users...
sign_authenticated = true;
# ...and from our own networks (locally generated cron/system mail).
sign_local = true;

# Do NOT sign mail merely because its From: domain is one of ours. An
# unauthenticated message claiming to be from us is a forgery, and signing it
# would hand the forger a valid DMARC pass.
sign_inbound = false;
use_esld = true;

# The selector for THIS node.
selector = "${SELF_DKIM_SELECTOR}";

# One key per domain, named <selector>.<domain>.key. The $domain and
# $selector placeholders are expanded by rspamd at signing time - they are NOT
# shell variables and must survive templating verbatim.
path = "${DKIM_PATH}/$selector.$domain.key";

# Fall back to a single key if no per-domain key exists. Left disabled: a
# missing key should be visible as unsigned mail in the logs, not silently
# papered over with a key that belongs to a different domain and will fail
# alignment at the recipient.
try_fallback = false;

# Headers to sign. Oversigning (listing a header twice) prevents an attacker
# from ADDING a second From:/Subject: header downstream without breaking the
# signature - the classic DKIM header-injection replay.
sign_headers = "(o)from:(o)sender:(o)reply-to:(o)subject:(o)date:(o)message-id:(o)to:(o)cc:mime-version:content-type:content-transfer-encoding:resent-to:resent-cc:resent-from:resent-sender:resent-message-id:in-reply-to:references:list-id:list-owner:list-unsubscribe:list-subscribe:list-post";

# Relaxed canonicalisation on both. "simple" breaks the moment any mailing
# list or gateway rewrites whitespace, which in practice is always.
header_canon = "relaxed";
body_canon = "relaxed";

# Do not sign the body length (l= tag). An l= tag lets an attacker APPEND
# content to a signed message and keep the signature valid.
sign_body_length = false;

allow_hdrfrom_mismatch = false;
allow_hdrfrom_multiple = false;
allow_username_mismatch = false;

# Explicit per-domain map. scripts/70-rspamd-dkim.sh and
# bin/dkim-add-domain.sh maintain this file; it lets a domain override the
# node's default selector if you ever need a per-tenant rotation schedule.
domain {
  ${DOMAIN} {
    path = "${DKIM_PATH}/${SELF_DKIM_SELECTOR}.${DOMAIN}.key";
    selector = "${SELF_DKIM_SELECTOR}";
  }
}
