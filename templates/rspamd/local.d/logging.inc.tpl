##############################################################################
# ha-mail :: /etc/rspamd/local.d/logging.inc
##############################################################################

type = "console";
systemd = true;
level = "notice";

# One line per message with the symbols that fired. This is what you read when
# a user asks why their mail went to Junk on one node and not the other.
log_urls = false;
log_re_cache = false;
