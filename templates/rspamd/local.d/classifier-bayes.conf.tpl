##############################################################################
# ha-mail :: /etc/rspamd/local.d/classifier-bayes.conf
##############################################################################

backend = "redis";
servers = "${REDIS_BIND}:6379";

# Autolearn is off. It is a feedback loop: the classifier trains on its own
# verdicts, and because the two nodes see different traffic they diverge
# faster and in less predictable ways. All training here is explicit and
# user-driven (move to/from Junk -> imap_sieve -> rspamc learn_*).
autolearn = false;

# Per-user statistics would multiply the token space by the number of
# mailboxes and make the node-local Redis considerably larger for very little
# gain at this scale.
users_enabled = false;

min_learns = 200;
min_tokens = 11;
