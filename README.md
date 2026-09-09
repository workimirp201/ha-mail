# ha-mail

A reusable, fully templated blueprint for a **two-node, cross-continental,
active-active mail cluster** on Ubuntu 24.04.

Everything here is driven by a single `.env`. To deploy a different domain on a
different pair of servers, you change that file and nothing else.

```
Node A — Singapore              WireGuard              Node B — United States
${NODE_A_HOSTNAME}          <==================>      ${NODE_B_HOSTNAME}
${NODE_A_IP}                    ~180 ms RTT           ${NODE_B_IP}
10.77.0.1                                             10.77.0.2

  Postfix ─┐                                            ┌─ Postfix
  Dovecot ─┼── dsync replication (bidirectional) ───────┼─ Dovecot
  MariaDB ─┴── master ⇄ master (async, GTID) ───────────┴─ MariaDB
  rspamd      selector sg._domainkey                       selector us._domainkey
  nginx       Roundcube + PostfixAdmin                     Roundcube + PostfixAdmin
```

---

## Contents

| Path | What it is |
|---|---|
| `env.example` | **Phase 2** — every variable, documented. Copy to `.env`. |
| `deploy.sh` | Orchestrator. `--list`, `--from`, `--only`, `--dry-run`. |
| `lib/common.sh` | Env loading, validation, `SELF_*`/`PEER_*` derivation, safe rendering. |
| `bin/` | `gen-secrets.sh`, `render.sh` (dry-run the whole tree). |
| `scripts/` | Numbered, idempotent installers. |
| `templates/` | **Phase 4** — every configuration file, complete and untruncated. |
| `docs/AUDIT.md` | **Phase 5** — the bug-prevention audit. Read this one. |
| `docs/DNS.md` | **Phase 6** — the full record table and Linode PTR steps. |
| `docs/TESTING.md` | **Phase 7** — verification and failover drills. |
| `docs/OPERATIONS.md` | Day-two runbook: add a domain, rotate DKIM, rebuild a node. |

---

## Quick start

```bash
# On one machine (either node, or your laptop):
git clone <this repo> /opt/ha-mail && cd /opt/ha-mail
cp env.example .env && chmod 600 .env
./bin/gen-secrets.sh                # fills every CHANGE_ME_* with a strong value
$EDITOR .env                        # set DOMAIN, both IPs, both hostnames

scp .env root@NODE_A:/opt/ha-mail/.env
scp .env root@NODE_B:/opt/ha-mail/.env
# On Node B ONLY, change one line:  NODE_ROLE=B

# Node A, then Node B:
./deploy.sh --to 20                 # stops after generating WireGuard keys
# exchange the two public keys into both .env files (WG_PEER_PUBKEY)
# exchange the two SSH public keys into both /root/.ssh/authorized_keys

./deploy.sh --from 20               # Node A first, then Node B
```

Then publish the DNS from `docs/DNS.md` and run `docs/TESTING.md`.

---

# PHASE 1 — Architectural decisions

The whole design follows from one physical fact: **the two nodes are ~180 ms
apart, and that number cannot be engineered away.** Every decision below is
about refusing to put a synchronous operation on that link.

## 1.1 Mailbox storage and synchronisation

### The choice: Dovecot `dsync` replication

| Option | Verdict | Why |
|---|---|---|
| **Dovecot dsync** | ✅ **Chosen** | Object-aware, bidirectional, conflict-merging, asynchronous. Understands that a message is identified by GUID, not filename. |
| rsync (cron or inotify) | ❌ Rejected | One-directional by definition; unaware of IMAP semantics; `--delete` from a stale source destroys mail. |
| GlusterFS / CephFS / DRBD / NFS | ❌ **Rejected emphatically** | Requires synchronous POSIX locking across the WAN. This is the design that kills two-continent mail clusters. |

### Why a shared filesystem is the wrong answer

Dovecot takes an `flock()` on index and `dovecot-uidlist` files on essentially
every mailbox operation. Over a 180 ms link:

- each lock acquisition costs at least one round trip — **0.18 s per lock**
- IMAP sessions serialise behind those locks, so a user opening a folder with a
  few hundred messages waits *seconds*
- a network partition produces **filesystem-level** split-brain. GlusterFS will
  happily present two divergent copies of `dovecot.index.log`, and Dovecot's
  index format has no notion of "merge two histories" — the repair is manual
  and lossy
- performance is worst exactly when you need it most: during a burst of
  deliveries, when lock contention peaks

The rule this design follows: **the WAN link carries only asynchronous,
restartable, idempotent traffic.** A filesystem lock is none of those things.

### Why not rsync

`rsync` looks tempting because Maildir is "just files". It is not safe here:

1. **Maildir filenames encode flags.** Marking a message read renames
   `1699…:2,` → `1699…:2,S`. rsync sees a delete plus a create and re-transfers
   the whole message. dsync sees a flag change and transfers a few bytes.
2. **`--delete` is a loaded gun.** In an active-active pair you need sync in
   both directions, which means two rsync jobs. They will eventually overlap.
   When they do, whichever runs second treats the other's new mail as "not in
   my source" and deletes it.
3. **No expunge semantics.** A message deleted on Node A and a message
   delivered on Node B are indistinguishable to rsync — both are "a file
   present here and absent there".
4. **Indexes.** Copying Dovecot's index files between nodes with rsync produces
   corrupt state; not copying them means every sync triggers a full re-index.

### How dsync works here

```
message saved on Node A
   → notify plugin fires
   → replication plugin queues the mailbox
   → replicator dequeues, opens a dsync connection to Node B's doveadm listener
   → both sides exchange mailbox GUIDs + modseqs, transfer only the delta
   → done, typically < 1 s after the delivery
```

Configuration: `templates/dovecot/conf.d/95-replication.conf.tpl`.

WAN-specific tuning, all exposed in `.env`:

| Setting | Value | Why |
|---|---|---|
| `replication_max_conns` | `6` | Each connection is a live TCP session across the ocean. Too many starve MariaDB replication, which shares the tunnel. |
| `replication_dsync_parameters` | `-d -N -l 120 -U` | The stock 30 s lock timeout is a LAN number. At 180 ms with a busy peer it produces spurious failures and endless requeues. `-U` releases the *local* lock early so a slow peer cannot block local IMAP. |
| `replication_full_sync_interval` | `4h` | Heals any notification that was dropped (replicator restart mid-queue). |
| `mail_attribute_dict` | file, in the user's home | Without it, dsync silently loses IMAP METADATA and special-use assignments. |
| `iterate_query` | set in SQL | **Required.** Without it you can never run a cluster-wide resync — which is exactly the operation you need after an outage. |

Format is **Maildir**, not mdbox: every message is an independent file with an
immutable name, so worst-case recovery is `cp` plus `doveadm force-resync`.

`INDEX` and `CONTROL` live on a separate path (`/var/vmail-index`) so that
restoring a mail-volume backup cannot restore stale indexes over current mail —
one of the classic ways deleted messages come back from the dead.

## 1.2 Database: MariaDB master ⇄ master

Both nodes are writable. Replication is **asynchronous, GTID-based, ROW
format**, over the tunnel.

### Primary-key collision avoidance

```ini
auto_increment_increment = 2      # size of the ring
auto_increment_offset    = 1      # Node A  → 1, 3, 5, 7, …
auto_increment_offset    = 2      # Node B  → 2, 4, 6, 8, …
gtid_domain_id           = 1 / 2  # must ALSO differ, or parallel replication
                                  # cannot order two independent write streams
```

Two simultaneous inserts on opposite nodes can never be handed the same
surrogate key. `hamail-repl-watchdog.sh` re-verifies these three values every
five minutes, because a package upgrade that reinstates a stock `50-server.cnf`
removes them and **nothing breaks until the first simultaneous insert**.

### What the offsets do *not* protect

They protect surrogate keys. They do **not** protect natural keys — and the
PostfixAdmin schema is mostly natural keys (`mailbox.username`,
`alias.address`, `domain.domain`). Two admins creating `alice@example.com` at
the same moment on opposite nodes both succeed locally and then deadlock
replication with error 1062.

That is why **admin writes are steered to one node at a time**. See
`docs/AUDIT.md` §5 — this is the one place where honest engineering means
declining to claim active-active.

### Other choices, and why

| Setting | Value | Reason |
|---|---|---|
| `binlog_format` | `ROW` | `STATEMENT` would replicate `NOW()`, `UUID()` and auto-increment-dependent statements differently on each node. |
| `transaction_isolation` | `READ-COMMITTED` | Shorter gap locks. The admin portal must not hold a range lock while another admin inserts an adjacent alias. |
| `innodb_lock_wait_timeout` | `15` | A blocked web request fails fast and is retried, instead of pinning a PHP-FPM worker. |
| `log_slave_updates` | `ON` | Mandatory in a ring; also makes point-in-time recovery complete. |
| `slave_compressed_protocol` | `ON` | Pays for itself on an intercontinental link. |
| `slave_parallel_mode` | `conservative` | Overlaps network latency while preserving commit order. |
| `slave_skip_errors` | **never set** | Skipping a 1062 guarantees permanent silent divergence. The watchdog alerts instead. |
| `replicate_ignore_table` | quota, sessions, caches | Derived, high-write, node-local state. See §1.4. |

## 1.3 Traffic routing and client failover

No load balancer, no floating IP, no VRRP. A shared VIP cannot span two
continents, and a proxy in front would become the single point of failure the
architecture exists to remove.

| Path | Mechanism | Recovery time |
|---|---|---|
| **Inbound mail** | Two MX records at **equal priority (10/10)** | Seconds. Built into SMTP: a sending MTA that cannot reach one MX immediately tries the other. This is the most reliable failover in the whole stack. |
| **IMAP / submission** | `mail.${DOMAIN}` → two A records | 5–20 s. Every mainstream MUA and OS resolver retries the second address on connection failure. |
| **Webmail** | `webmail.${DOMAIN}` → two A records | Usually invisible; browsers retry aggressively. |
| **Admin portal** | `admin.${DOMAIN}` → **one** A record | Manual or scripted DNS change. Deliberate — see `docs/AUDIT.md` §5. |

TTL on failover-sensitive records is **300 s**, the practical floor.

The optional `hamail-dns-failover.sh` (Linode API) withdraws a dead node's A
records so users stop hitting a timeout on alternate attempts. It is
**deliberately not automatic**: a node unreachable *from here* is not
necessarily down, and two nodes that each conclude the other is dead will fight
over the zone. It requires two independent failure signals (tunnel *and* public
SMTP) before it will act, and refuses outright while the peer still answers.

**MX records are never withdrawn during a failover.** A dead MX costs a sender
one retry; a missing MX risks losing mail if the node returns.

## 1.4 What is deliberately *not* replicated

Replicating everything is the beginner's instinct and it is wrong. Each of
these is node-local on purpose:

| State | Why it stays local |
|---|---|
| Dovecot quota counters (`quota`, `quota2`) | Both nodes hold the same mail, so both compute the same number. Replicating makes every delivery a cross-node write conflict on one row. The authoritative backend is `count` (index-derived), which touches no database at all — so quota enforcement survives a MariaDB outage. |
| Roundcube sessions | Every page view would become a replicated write, and consecutive requests landing on different nodes would race. Cost of keeping them local: one re-login after a failover. |
| Roundcube message caches | Tied to that node's Dovecot index state. A replicated cache serves stale data. |
| rspamd Bayes / greylist / ratelimit (Redis) | Rebuildable, very high write volume, and worth little across the ocean. Replicating it would put a hard cross-node dependency on the *mail acceptance* path. |
| Postfix queue, postscreen cache, TLS session cache | Node-local by nature. |

Roundcube **contacts, identities and saved searches do** replicate, so a user's
address book follows them across a failover.

## 1.5 DKIM across two senders

Either node may dispatch any user's mail, so the recipient's DMARC evaluation
must succeed identically from both. This blueprint uses **distinct selectors
with distinct keys** (`DKIM_MODE=distinct`):

```
sg._domainkey.example.com   TXT   v=DKIM1; k=rsa; p=<Node A public key>
us._domainkey.example.com   TXT   v=DKIM1; k=rsa; p=<Node B public key>
```

DMARC alignment compares the **`d=` domain** against the `From:` header. Both
nodes sign with `d=${DOMAIN}`, so both align. The selector only tells the
verifier which key to fetch.

Why not one shared key: a shared private key has to cross the network and then
exists in two places; rotation becomes an atomic two-node operation; and a
compromise of either node forces rotation for both. With distinct selectors you
revoke one node by deleting one TXT record, and mail from the other keeps
flowing. `DKIM_MODE=shared` is supported if you want the simpler DNS.

## 1.6 Summary of the latency-driven rules

1. Nothing synchronous crosses the tunnel.
2. Every service queries its **own** local replica; a node never depends on its
   peer to accept, deliver, or authenticate mail.
3. The tunnel carries only asynchronous, restartable, idempotent traffic:
   MariaDB replication, dsync, and a certificate pull.
4. State that is *derived* is recomputed locally, never shipped.
5. Where true multi-master is unsafe (natural-key writes from the admin UI),
   the design steers writes rather than pretending.
