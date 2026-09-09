##############################################################################
# ha-mail :: /etc/rspamd/local.d/milter_headers.conf
#
# The headers added here are what default.sieve keys off. They must be
# IDENTICAL on both nodes, otherwise the same message filed by Node A lands in
# Junk and by Node B lands in INBOX - which surfaces as a phantom replication
# bug.
##############################################################################

use = ["x-spamd-bar", "x-spam-level", "authentication-results", "x-spam-status"];

routines {
  x-spam-header {
    header = "X-Spam";
    value = "Yes";
    remove = 1;
  }
  x-spamd-bar {
    header = "X-Spamd-Bar";
    remove = 1;
  }
  x-spam-level {
    header = "X-Spam-Level";
    remove = 1;
  }
  authentication-results {
    header = "Authentication-Results";
    remove = 1;
    # Must be the node's own hostname: a recipient (and our own downstream
    # Sieve) has to be able to tell which server made the assertion.
    authenticated_headers = ["auth"];
  }
}

# remove = 1 on every routine strips any pre-existing copy of the header
# before adding ours. Without it, a spammer can pre-set "X-Spam: No" and sail
# straight past default.sieve.
extended_spam_headers = true;
