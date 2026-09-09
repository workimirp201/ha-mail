##############################################################################
# ha-mail :: /etc/rspamd/local.d/worker-normal.inc
# The scanning worker. Bound to loopback only - nothing outside this node ever
# talks to it, on either the public interface or the tunnel.
##############################################################################

bind_socket = "127.0.0.1:11333";
count = 2;
