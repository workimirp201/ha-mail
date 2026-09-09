##############################################################################
# ha-mail :: /etc/dovecot/conf.d/10-mail.conf
# Storage layout, plugin set and the choices that make dsync safe over a WAN.
##############################################################################

# ---------------------------------------------------------------------------
# MAILBOX FORMAT: Maildir
# ---------------------------------------------------------------------------
# Chosen over mdbox/sdbox for one reason that matters in a replicated pair:
# every message is an independent file with an immutable name. If replication
# ever goes wrong, recovery is `cp` and `doveadm force-resync`. With mdbox a
# corrupted or half-synced index can take a multi-message .m file with it, and
# the repair tooling is far less forgiving.
#
# The cost is more inodes and slower per-folder listing. On a mail server with
# thousands (not millions) of mailboxes that trade is obviously worth it.
#
# INDEX and CONTROL are deliberately NOT under ${VMAIL_ROOT}:
#   * dsync compares index state constantly; keeping it on its own path stops
#     index churn from interleaving with message files in the same directories
#   * restoring a mail-volume backup then cannot restore stale indexes on top
#     of current mail, which is one of the classic ways to resurrect deleted
#     messages (see docs/AUDIT.md section 4)
mail_location = maildir:${VMAIL_ROOT}/%d/%n/Maildir:INDEX=${VMAIL_INDEX_ROOT}/%d/%n/index:CONTROL=${VMAIL_INDEX_ROOT}/%d/%n/control

# %d = domain, %n = local part. Homes are per-domain so two tenants can never
# collide on a bare local part.
mail_home = ${VMAIL_ROOT}/%d/%n

# ---------------------------------------------------------------------------
# Ownership
# ---------------------------------------------------------------------------
mail_uid = ${VMAIL_UID}
mail_gid = ${VMAIL_GID}
first_valid_uid = ${VMAIL_UID}
last_valid_uid = ${VMAIL_UID}
first_valid_gid = ${VMAIL_GID}
last_valid_gid = ${VMAIL_GID}

# ---------------------------------------------------------------------------
# Durability
# ---------------------------------------------------------------------------
# always, not the default "optimized". A node that loses a just-accepted
# message on power failure has broken the SMTP contract - it told the sender
# 250 OK. The write amplification is real but small next to that.
mail_fsync = always

# Never use NFS-style locking heuristics; storage is local disk on both nodes.
# This is the setting that would have to change if anyone ever proposed
# putting ${VMAIL_ROOT} on shared storage - which is precisely what this
# architecture avoids (see README, Phase 1).
mmap_disable = no
dotlock_use_excl = yes
mail_nfs_index = no
mail_nfs_storage = no
lock_method = flock

# ---------------------------------------------------------------------------
# Indexes
# ---------------------------------------------------------------------------
# The mailbox list index makes LIST/STATUS cheap, which matters because the
# replicator issues them constantly. Without it, dsync on a mailbox with many
# folders spends most of its time on directory scans.
mailbox_list_index = yes
mailbox_list_index_very_dirty_syncs = yes

# Cache the fields dsync and IMAP clients actually ask for, so a sync does not
# have to reopen every message file.
mail_always_cache_fields = flags
mail_cache_min_mail_count = 10

# ---------------------------------------------------------------------------
# MAIL ATTRIBUTE DICTIONARY - REQUIRED FOR CORRECT REPLICATION
# ---------------------------------------------------------------------------
# IMAP METADATA (RFC 5464), per-mailbox annotations and the "special-use"
# assignments a client makes live here. Without this dict, dsync replicates
# messages and flags but silently loses the metadata - which shows up months
# later as "my Sent folder stopped being the Sent folder on the other server".
mail_attribute_dict = file:${VMAIL_ROOT}/%d/%n/dovecot-attributes

# ---------------------------------------------------------------------------
# PLUGINS
# ---------------------------------------------------------------------------
#   quota        - enforcement
#   quota_clone  - mirrors the computed quota into SQL for the admin portal
#   notify       - the event bus replication listens on
#   replication  - queues a dsync run whenever a mailbox changes
#   acl / imap_acl are NOT loaded: shared mailboxes across a replicated pair
#   add a second class of conflict for no benefit in this design.
mail_plugins = quota quota_clone notify replication

# Auto-expunge nothing globally. Retention is a per-domain policy decision and
# is expressed in Sieve, not here. A global expunge rule in a replicated pair
# is a very efficient way to delete the same mail twice.

# ---------------------------------------------------------------------------
# Namespace
# ---------------------------------------------------------------------------
namespace inbox {
  type = private
  separator = /
  prefix =
  inbox = yes
  # list = yes and subscriptions = yes must both be set for dsync to
  # replicate the subscription list along with the folders themselves.
  list = yes
  subscriptions = yes
}

# Shared/public namespaces are intentionally omitted. See the note above.

# Protocol-agnostic warning threshold: log when a single mail takes long to
# save, which on this cluster almost always means the replicator is saturating
# the tunnel.
mail_max_lock_timeout = 60s
