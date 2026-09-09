##############################################################################
# ha-mail :: /etc/rspamd/local.d/worker-proxy.inc
# The milter endpoint Postfix connects to (smtpd_milters = inet:127.0.0.1:11332).
##############################################################################

bind_socket = "127.0.0.1:11332";
milter = yes;
timeout = 120s;

upstream "local" {
  default = yes;
  self_scan = yes;
}

# Self-scan mode: this worker does the scanning itself instead of proxying to
# a normal worker. Fewer moving parts, one less socket, and on a two-node mail
# cluster the scan volume never justifies a separate scanner tier.

max_retries = 5;
discard_on_reject = false;
quarantine_on_reject = false;
spam_header = "X-Spam";
reject_message = "Message rejected: appears to be spam";
