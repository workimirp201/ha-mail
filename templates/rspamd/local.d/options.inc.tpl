##############################################################################
# ha-mail :: /etc/rspamd/local.d/options.inc
##############################################################################

# Both nodes' public addresses and the tunnel are "local". This keeps rspamd
# from scoring our own infrastructure as an untrusted relay when a message
# legitimately passes through it.
local_addrs = "127.0.0.0/8, ::1, ${NODE_A_IP}/32, ${NODE_B_IP}/32, ${WG_SUBNET}";

# DNS. Resolution failures on a mail server are outages, so keep the timeout
# short and retry rather than letting a scan block.
dns {
  timeout = 1s;
  sockets = 16;
  retransmits = 2;
}

# Do not let a single pathological message hold a scanner hostage.
task_timeout = 8s;

# This node's identity in Authentication-Results and in the web UI.
filters = "chartable,dkim,spf,surbl,regexp,fuzzy_check";
