##############################################################################
# ha-mail :: /etc/rspamd/local.d/redis.conf
#
# NODE-LOCAL Redis. Deliberately not replicated.
#
# What lives here: Bayes tokens, greylisting state, ratelimit counters, fuzzy
# hashes, reputation. All of it is (a) rebuildable, (b) high write volume, and
# (c) worth very little across a 180ms link.
#
# Replicating it would put a hard cross-node dependency on the SPAM path, so a
# tunnel outage would degrade mail acceptance. That trade is not worth a few
# percentage points of classifier accuracy. See docs/AUDIT.md section 6.
##############################################################################

servers = "${REDIS_BIND}:6379";
timeout = 1s;
db = "0";
