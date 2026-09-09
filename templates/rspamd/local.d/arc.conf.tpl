##############################################################################
# ha-mail :: /etc/rspamd/local.d/arc.conf
#
# ARC (RFC 8617) seals the authentication results this node observed, so that
# when a user forwards mail onwards - which breaks the original DKIM signature
# - the next hop can still see that WE validated it.
#
# Same key material and same per-node selector logic as dkim_signing.conf.
##############################################################################

enabled = true;
sign_authenticated = true;
sign_local = true;
sign_inbound = true;

selector = "${SELF_DKIM_SELECTOR}";
path = "${DKIM_PATH}/$selector.$domain.key";
try_fallback = false;
use_esld = true;

header_canon = "relaxed";
body_canon = "relaxed";
allow_hdrfrom_mismatch = true;
allow_username_mismatch = true;

domain {
  ${DOMAIN} {
    path = "${DKIM_PATH}/${SELF_DKIM_SELECTOR}.${DOMAIN}.key";
    selector = "${SELF_DKIM_SELECTOR}";
  }
}
