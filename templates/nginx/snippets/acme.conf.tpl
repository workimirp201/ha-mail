##############################################################################
# ha-mail :: /etc/nginx/snippets/hamail-acme.conf
#
#        *** HOW ACME WORKS ON A TWO-NODE ACTIVE-ACTIVE PAIR ***
#
# THE PROBLEM
# ${MAIL_HOST}, ${WEBMAIL_HOST} and friends resolve to BOTH ${NODE_A_IP} and
# ${NODE_B_IP} (round-robin A records - that is how client failover works).
# When Let's Encrypt validates an HTTP-01 challenge it picks one of those
# addresses, and it may pick the node that did NOT create the challenge token.
# The naive result is an intermittently failing renewal: it works about half
# the time, which is the worst possible failure mode because it looks
# transient.
#
# THE SOLUTION
# Serve the token locally if we have it; otherwise fetch it from the peer over
# the WireGuard tunnel. Exactly one extra hop, and the same file works
# unmodified on both nodes:
#
#     Node A issues  -> token exists locally on A  -> A serves it directly
#                    -> LE happens to ask B        -> B has no token
#                                                  -> B proxies to A -> served
#
# LOOP SAFETY
# The peer endpoint (see site-acme.conf, the :8080 server on ${SELF_WG_IP}) is
# a plain static file server with NO fallback of its own. So the maximum chain
# is one hop: A -> B or B -> A, then a 404. There is no path by which a
# request can bounce back and forth. This is the same reasoning that governs
# certificate FILE synchronisation - see docs/AUDIT.md section 2.
##############################################################################

location ^~ /.well-known/acme-challenge/ {
    default_type "text/plain";
    root ${ACME_WEBROOT};
    allow all;
    access_log /var/log/nginx/acme.log hamail;

    # Local file first, peer second.
    try_files $uri @hamail_acme_peer;
}

location @hamail_acme_peer {
    # The peer's tunnel-only static endpoint. If the tunnel is down this
    # returns 502 quickly rather than hanging the validation.
    proxy_pass http://${PEER_WG_IP}:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_connect_timeout 5s;
    proxy_read_timeout 10s;
    proxy_send_timeout 10s;
    proxy_intercept_errors off;
}
