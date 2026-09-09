##############################################################################
# ha-mail :: /etc/dovecot/conf.d/95-replication.conf
#
#            *** THE HEART OF THIS ARCHITECTURE ***
#
# Node ${SELF_ROLE} (${SELF_HOSTNAME}) replicates mailboxes to and from
# Node ${PEER_ROLE} (${PEER_HOSTNAME}) over the WireGuard tunnel using
# Dovecot's native dsync.
#
# HOW IT WORKS
#   1. The `notify` plugin raises an event on every mail save, flag change,
#      copy, rename and expunge.
#   2. The `replication` plugin turns that event into a job on the
#      `aggregator` FIFO.
#   3. The `replicator` process dequeues jobs and runs `dsync` against the
#      peer's `doveadm` TCP listener, one connection per mailbox.
#   4. dsync compares per-message GUIDs and per-mailbox modification
#      sequences, then transfers only the difference - in BOTH directions in a
#      single pass.
#
# WHY dsync AND NOT rsync OR A CLUSTER FILESYSTEM
#   * dsync speaks IMAP semantics. It knows that a message is identified by
#     its GUID, not by its filename, and that a Maildir filename legitimately
#     changes when a flag changes. rsync sees a rename and copies the file
#     again; worse, `rsync --delete` run from a stale source resurrects
#     deleted mail or deletes new mail, depending on direction.
#   * dsync is bidirectional and conflict-aware in a single run. rsync is
#     one-way by definition, so an active-active pair needs two rsync jobs
#     that will eventually run at the same time and fight.
#   * GlusterFS (or any shared/distributed POSIX filesystem) requires
#     synchronous locking across the link. Dovecot takes flock() on index
#     files on essentially every operation. At ~180ms RTT each lock is a third
#     of a second, IMAP sessions serialise behind it, and a split network
#     turns into a filesystem-level split-brain that must be healed by hand.
#     This is the single most common way people destroy a two-continent mail
#     cluster - see README, Phase 1.
##############################################################################

# ---------------------------------------------------------------------------
# doveadm - the replication endpoint the PEER connects to.
# ---------------------------------------------------------------------------
# Bound to ${SELF_WG_IP} ONLY. It is not reachable from the public internet
# even if every firewall rule on this box were flushed, because it is not
# listening on a public address.
service doveadm {
  inet_listener {
    address = ${SELF_WG_IP}
    port = ${DOVEADM_PORT}
  }
  # One process per inbound sync; must be at least REPL_MAX_CONNS on the peer.
  process_min_avail = 2
  process_limit = 32
  # dsync of a large mailbox is memory-hungry; the default 256M is not enough
  # for a multi-gigabyte account with tens of thousands of messages.
  vsz_limit = 1G
}

# Shared secret used in BOTH directions. It must be byte-identical on the two
# nodes (bin/gen-secrets.sh generates it once and you copy the .env).
doveadm_password = ${DOVEADM_PASS}
doveadm_port = ${DOVEADM_PORT}

# ---------------------------------------------------------------------------
# replicator - the queue and scheduler.
# ---------------------------------------------------------------------------
service replicator {
  # Must be 1: the replicator holds the queue in memory and a second instance
  # would schedule the same mailbox twice.
  process_min_avail = 1

  # `doveadm replicator status` talks to this socket. Root-only, because the
  # same socket can force a full resync of every mailbox on the cluster.
  unix_listener replicator-doveadm {
    mode = 0600
    user = ${VMAIL_USER}
    group = ${VMAIL_GROUP}
  }
}

# ---------------------------------------------------------------------------
# aggregator - collects notifications from every imap/lmtp process.
# ---------------------------------------------------------------------------
service aggregator {
  fifo_listener replication-notify-fifo {
    mode = 0660
    user = ${VMAIL_USER}
    group = ${VMAIL_GROUP}
  }
  unix_listener replication-notify {
    mode = 0660
    user = ${VMAIL_USER}
    group = ${VMAIL_GROUP}
  }
}

# ---------------------------------------------------------------------------
# Replication parameters
# ---------------------------------------------------------------------------
plugin {
  # WHERE TO REPLICATE TO.
  #
  # `tcp:` and not `tcps:`. The tunnel already provides ChaCha20-Poly1305
  # authenticated encryption between these two addresses, and `tcps:` on a
  # private /32 address means either disabling certificate verification (no
  # security benefit, real risk of it silently staying disabled) or minting an
  # internal CA whose expiry becomes a new outage source. If you remove
  # WireGuard, you MUST switch this to tcps: and set ssl = yes on the doveadm
  # inet_listener above.
  mail_replica = tcp:${PEER_WG_IP}:${DOVEADM_PORT}

  # Concurrent dsync connections. Each one is a live TCP session across the
  # ocean holding index state on both ends. Too high and a burst of deliveries
  # saturates the tunnel and starves MariaDB replication, which shares it.
  replication_max_conns = ${REPL_MAX_CONNS}

  # Belt and braces against a lost notification. Every mailbox gets a full
  # state comparison at least this often, regardless of whether anything
  # appeared to change. This is what heals the "notification was dropped
  # because the replicator was restarted mid-queue" case.
  #
  # Do NOT set this to a very small value: a full sync of every mailbox is
  # proportional to total mail volume, not to what changed.
  replication_full_sync_interval = ${REPL_FULL_SYNC_INTERVAL}

  # dsync flags:
  #   -d  use the mail_replica setting as the destination
  #   -N  sync ALL namespaces, not just INBOX
  #   -l  seconds to wait for the peer's per-user lock. The default (30s) is
  #       tuned for a LAN; on a ~180ms link with a busy peer, 30s produces
  #       spurious "Timeout during state=..." failures and endless requeues.
  #   -U  release the local lock as soon as the remote side has it, so a slow
  #       remote cannot block local IMAP access to the same mailbox.
  replication_dsync_parameters = -d -N -l ${REPL_SYNC_TIMEOUT} -U
}

# ---------------------------------------------------------------------------
# OPERATIONAL NOTES - read before you touch this in anger
# ---------------------------------------------------------------------------
#
# INSPECT THE QUEUE
#     doveadm replicator status
#     doveadm replicator status '*'          # per-user detail
#     doveadm replicator dsync-status        # what is running right now
#
# FORCE A RESYNC OF ONE USER (safe, bidirectional, merges)
#     doveadm sync -u alice@${DOMAIN} tcp:${PEER_WG_IP}:${DOVEADM_PORT}
#
# FORCE A RESYNC OF EVERY USER AFTER AN OUTAGE
#     doveadm replicator replicate -f '*'
#
# *** NEVER RUN `doveadm backup` ON A LIVE NODE ***
# `doveadm backup` is one-way and DESTRUCTIVE: it makes the destination
# identical to the source, which means every message that exists only on the
# destination is deleted. On an active-active pair that is a data-loss command
# dressed up as a backup command. The bidirectional, merging equivalent is
# `doveadm sync`. bin/health-check.sh greps the shell history of both nodes
# for `doveadm backup` and warns, because this mistake is that common.
