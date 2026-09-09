# PHASE 5 — Code audit, bug checking and edge-case prevention

This is the self-audit performed **before** the configuration files were
written. Each section states the failure mode, why the obvious implementation
produces it, what this blueprint does instead, and where to look in the tree.

Sections 1–5 are the classes you asked about. Sections 6–12 are additional
failure modes found while auditing this specific architecture; several of them
are more likely to bite in practice than the ones on the original list.

---

## 1. Primary-key collisions

### The failure

Two writers, one keyspace. `INSERT` on Node A gets id 7; `INSERT` on Node B at
the same moment also gets id 7. ~180 ms later each node receives the other's
row for a key it already holds. Replication stops on **both** sides with
`Last_Errno: 1062 Duplicate entry '7' for key 'PRIMARY'` and stays stopped.

Meanwhile both nodes keep accepting mail and keep serving IMAP. Nothing looks
broken. The databases simply stop agreeing, silently, for as long as nobody
looks.

### Prevention — surrogate keys

`templates/mariadb/50-server.cnf.tpl`:

```ini
auto_increment_increment = 2                        # ring size
auto_increment_offset    = ${SELF_AUTOINC_OFFSET}   # 1 on A, 2 on B
gtid_domain_id           = ${SELF_SERVER_ID}        # must also differ
```

Node A yields 1, 3, 5, 7…; Node B yields 2, 4, 6, 8…. The keyspaces are
disjoint by construction.

`gtid_domain_id` is easy to miss and matters: with both nodes in one GTID
domain, the two independent write streams interleave into a single sequence and
parallel replication cannot order them.

### Verified, not assumed

These values *are* the mechanism, so they are checked three times:

| Where | When |
|---|---|
| `scripts/40-mariadb.sh` | At deploy — refuses to continue if wrong. |
| `hamail-repl-watchdog.sh` | Every 5 minutes — a package upgrade that reinstates a stock `50-server.cnf` removes them silently. |
| `hamail-health.sh` | On every health run. |

### The part the offsets do NOT solve

Offsets protect **surrogate** keys. The PostfixAdmin schema is mostly
**natural** keys:

| Table | Primary key | Collision risk |
|---|---|---|
| `mailbox` | `username` (email address) | **Yes** — two admins create the same address |
| `alias` | `address` | **Yes** |
| `domain` | `domain` | **Yes** |
| `domain_admins` | `(username, domain)` | No — a duplicate grant is idempotent |
| `vacation_notification` | `(on_vacation, notified)` | No — converges |
| `log`, `fetchmail`, `config` | surrogate `AUTO_INCREMENT` | Solved by offsets |

No configuration setting can fix a natural-key collision — the two rows are
genuinely the same identity created twice. The fix is at the application layer:
**admin writes go to one node at a time.** See §5.

### Also fixed here: the `log` table has no primary key upstream

PostfixAdmin ships `log` with no PK. Under ROW-based replication, a table
without a primary key forces the replica to **full-scan** for every row event.
An append-only audit log then costs O(n) per write and eventually stalls the
SQL thread. `templates/mariadb/schema.sql.tpl` adds a
`BIGINT AUTO_INCREMENT PRIMARY KEY`, which inherits the offsets. PostfixAdmin
only INSERTs and SELECTs there, so the extra column is transparent.

### If a 1062 does occur

**Do not** use `SET GLOBAL sql_slave_skip_counter = 1`. Skipping the event
means the two databases now disagree about a row and will diverge forever, with
no record of when it started. The watchdog deliberately alerts and stops rather
than "self-healing". Recovery procedure: `docs/TESTING.md` §6.

---

## 2. Circular SSL synchronisation loops

### The failure

The obvious implementation is a bidirectional rsync on both nodes:

```
1. A pushes the certificate to B.            B's files change.
2. B's watcher/timer sees a change → pushes back to A.
3. rsync updates A's mtimes.                 A sees a change → pushes to B.
4. → 2
```

The pair reloads Postfix, Dovecot and nginx every few seconds indefinitely.
Worse: if both nodes ever hold *different valid* certificates (both ran
certbot), the loop flip-flops which one is live, so roughly half of all TLS
handshakes present the wrong certificate — intermittently, which is the hardest
kind of bug to report.

There is a second, subtler loop specific to a dual-A architecture: **the ACME
HTTP-01 challenge itself.** `mail.${DOMAIN}` resolves to both nodes, so Let's
Encrypt may validate against the node that did *not* create the token. Naive
setups fail renewal roughly half the time.

### Prevention — four independent guarantees

`templates/bin/hamail-cert-sync.sh.tpl`:

**(a) Direction is a compile-time constant.** `IS_CERT_LEADER` is baked in at
render time from `NODE_ROLE`. On the leader the script exits at line one. There
is *no code path* in which the leader writes to the follower, or the follower
writes to the leader. A loop needs two directions; only one exists.

**(b) Only the leader runs certbot for the shared names.** The follower has no
renewal configuration for `${MAIL_HOST}` at all, so it can never produce a
competing certificate that would need pushing back.

**(c) Change detection is content-addressed.** The install trigger is a change
in the certificate's **X.509 serial number**, not a file mtime. rsync touching
a file, a filesystem restore, or clock skew cannot make the script believe
something changed. `rsync --checksum` ignores mtime entirely.

**(d) Monotonicity.** The incoming certificate must expire *later* than the
installed one. Even a restored-from-backup export directory cannot roll the
follower backwards.

Plus a randomised timer delay (`RandomizedDelaySec=45m`) so the two nodes never
fire simultaneously — cheap insurance against a future "improvement".

### The ACME challenge path

`templates/nginx/snippets/acme.conf.tpl`:

```nginx
location ^~ /.well-known/acme-challenge/ {
    root ${ACME_WEBROOT};
    try_files $uri @hamail_acme_peer;      # local file first
}
location @hamail_acme_peer {
    proxy_pass http://${PEER_WG_IP}:8080;  # then the peer, over the tunnel
}
```

The peer endpoint (`site-acme.conf.tpl`, bound to the tunnel address only) is a
plain static file server **with no fallback of its own**. Maximum chain length
is therefore one hop: `A → B → 404`. A request cannot bounce back and forth.

### Integrity guards on the pulled bundle

Before anything reaches the live path:

- SHA-256 manifest verification (a truncated transfer is refused)
- the private key must actually match the certificate (RSA *and* ECDSA paths)
- reload, never restart, so in-flight IMAP and SMTP sessions survive

### What is *not* synchronised

Each node's own certificate for `${SELF_HOSTNAME}` is issued locally and never
exported. Pushing it would overwrite the peer's certificate for *its* hostname
with one that does not match its name — a self-inflicted TLS outage.

---

## 3. DKIM / SPF / DMARC alignment from either node

### The failure

Mail sent from Node B fails DMARC because SPF only lists Node A, or because
Node B's DKIM key was never published, or because Node B signs with `d=` set to
its own hostname rather than the user's domain. The symptom is "some of our
mail goes to spam and we can't work out which".

### The four things that must each hold

**(1) SPF authorises both nodes.**

```
example.com. TXT "v=spf1 ip4:${NODE_A_IP} ip4:${NODE_B_IP} -all"
```

One record, both addresses. Never two separate `v=spf1` records — that is a
`permerror` and everything fails.

**(2) Both DKIM selectors are published, and both sign with `d=${DOMAIN}`.**

`templates/rspamd/local.d/dkim_signing.conf.tpl` sets `use_esld = true` and
signs on the From-header domain, not the hostname. Alignment compares `d=`
against `From:`; the selector is irrelevant to alignment.

**(3) Outbound mail actually leaves from the address in SPF.**

`smtp_bind_address = ${SELF_IP}` in `main.cf`. This is the single most
important line for alignment on a multi-homed node. Without it Postfix may
source outbound SMTP from the WireGuard address, and every recipient sees an IP
that is in no SPF record and has no reverse DNS.

**(4) Forward-confirmed reverse DNS on both nodes.**

`${NODE_A_IP} → ${NODE_A_HOSTNAME} → ${NODE_A_IP}`, and the same for B. Set in
the Linode Cloud Manager — see `docs/DNS.md`. Missing or mismatched PTR causes
deferrals at several large providers, and the failure is invisible from your
side.

### Signing hygiene

| Setting | Why |
|---|---|
| oversigned `from`, `subject`, `to`, `date`… | Prevents header-injection replay: an attacker cannot add a second `From:` downstream without breaking the signature. |
| `sign_body_length = false` | An `l=` tag lets an attacker **append** content to a signed message and keep the signature valid. |
| `sign_inbound = false` | Never sign an unauthenticated message just because its `From:` claims one of our domains — that hands a forger a valid DMARC pass. |
| `relaxed/relaxed` canonicalisation | `simple` breaks the moment any list or gateway rewrites whitespace. |
| `try_fallback = false` | A missing key should be visible as unsigned mail in the log, not silently signed with a key belonging to a different domain. |

### The truncated-TXT trap

A 2048-bit key exceeds the 255-character limit of a single DNS TXT string. Some
providers split it automatically; some truncate it silently. A truncated record
is *syntactically valid* and *cryptographically wrong* — every message fails
DKIM. `hamail-health.sh` extracts the public key from the local private key,
fetches the published TXT, and compares them on every run.

### Also enforced: users cannot spoof each other

`smtpd_sender_login_maps` + `reject_sender_login_mismatch`. On a multi-tenant
cluster this matters more than usual: a spoofed message would be **legitimately
signed by us** and would therefore pass DMARC at the recipient.

---

## 4. Split-brain and mail loss in dsync

### The failure

Node A and Node B are both live but cannot see each other (tunnel down). Mail
is delivered to both. A user reads and deletes messages on both. When the
tunnel returns:

- **naive fix A** — `doveadm backup` in one direction: destroys everything that
  exists only on the destination
- **naive fix B** — rsync: resurrects deleted mail, or deletes new mail,
  depending on direction
- **naive fix C** — a shared filesystem: two divergent `dovecot.index.log`
  histories that cannot be merged

### Why dsync is safe here

dsync's conflict resolution is **union merge on GUIDs**:

- a message present on only one side is **copied**, never deleted
- an expunge is replicated only when the receiving side can prove it saw the
  message (it is recorded against a GUID in the expunge log, not inferred from
  absence)
- flag conflicts resolve by highest modification sequence
- a message that exists on both sides with the same GUID is not duplicated

The bias is deliberately toward **keeping** mail. dsync's failure mode is a
duplicate; rsync's failure mode is deletion. On a mail server those are not
comparable.

### The residual risk, stated honestly

If a node is offline **longer than the expunge-log retention**, the surviving
node can no longer prove which messages were deliberately deleted versus never
seen. A full resync then re-creates some previously deleted mail. Mitigations
in this blueprint:

| Mitigation | Where |
|---|---|
| `mailbox_list_index = yes` and cached flags | `10-mail.conf` — keeps sync cheap so the queue drains fast |
| `replication_full_sync_interval = 4h` | `95-replication.conf` — bounds how stale state can get |
| Watchdog alerts within 5 minutes | `hamail-repl-watchdog.sh` |
| INDEX/CONTROL off the mail volume | Restoring a mail backup cannot restore stale indexes over current mail |
| `mail_fsync = always` | A node that lost a just-accepted message on power failure has broken the SMTP contract |
| POP3 not offered | Download-and-delete generates expunges that race the replication queue by design |

### The `doveadm backup` tripwire

`doveadm backup` is one-way and **destructive**: it makes the destination
identical to the source, deleting anything the destination has that the source
does not. On a live active-active pair it is a data-loss command with a
reassuring name. It is documented in a banner comment in `95-replication.conf`,
and `hamail-health.sh` greps both nodes' shell history for it and warns —
because this mistake is that common.

The correct command is always `doveadm sync` (bidirectional, merging).

### Duplicate folder trees

A subtler split-brain: if the server does not declare special-use flags, each
MUA invents its own names ("Sent Items", "Sent Messages"). Two clients on two
nodes create two folders for one purpose, dsync faithfully replicates **both**,
and the user gets a duplicated tree that looks exactly like a replication bug.
`15-mailboxes.conf` declares the special-use flags server-side and additionally
declares the common client-invented aliases without `auto=create`.

Roundcube's `*_mbox` settings are pinned to the same names for the same reason.

---

## 5. Web-UI database lockups, and the honest limit of active-active

### The failure

Two failure modes, related:

1. **Lock contention.** PHP-FPM has a bounded worker pool. If a request blocks
   on an InnoDB lock, the worker is pinned. Enough of those and the pool is
   exhausted and the portal stops responding entirely — including for the
   person trying to log in and fix it.
2. **Cross-node write conflict.** Two admins performing the same natural-key
   insert on opposite nodes deadlock replication with a 1062 (see §1).

### Prevention — lock contention

| Setting | Value | Effect |
|---|---|---|
| `transaction_isolation` | `READ-COMMITTED` | Far shorter gap locks. No range lock held while another admin inserts an adjacent alias. Safe because `binlog_format = ROW`. |
| `innodb_lock_wait_timeout` | `15` | A blocked request fails fast and is retried, instead of pinning a worker indefinitely. |
| `lock_wait_timeout` | `30` | Bounds metadata-lock waits (an `ALTER` during a busy period). |
| `request_terminate_timeout` | `60s` (admin pool) | A PHP request that outlives this is stuck, not working. |
| Separate FPM pools | admin / webmail | A Roundcube slow-loris cannot exhaust the workers the admin portal needs. |
| `pm.max_children = 10` (admin) | | Bounded concurrency into the database. |
| Local UNIX socket, not TCP to the peer | | A portal write completes in single-digit ms instead of waiting ~180 ms. |

The portal writes to its **own** node and lets replication carry the change.
That also means it keeps working when the tunnel is down.

### Prevention — cross-node write conflict

**This is where the design declines to claim active-active, and says so.**

Asynchronous multi-master gives eventual consistency, not mutual exclusion.
There is no setting that makes two simultaneous `INSERT`s of
`alice@example.com` on opposite nodes safe. Anyone who tells you otherwise is
selling you a 1062 at 3 a.m.

So:

- PostfixAdmin is **installed and running on both nodes** — failover needs no
  deployment step
- `admin.${DOMAIN}` publishes **one** A record, pointed at the write leader
  (Node A by default)
- failover is one DNS change (`hamail-dns-failover.sh --promote-self`) or one
  `/etc/hosts` line for an operator in a hurry
- the page title shows the node, so an operator always knows where they are

Cost: nothing that matters. Administration is low-volume and bursty; the
standby is seconds away. Benefit: an entire class of unrecoverable failure is
removed by construction rather than mitigated.

Mail delivery, IMAP, submission and webmail remain genuinely active-active.
It is only *administrative writes* that are steered.

### Detection if someone bypasses the steering

The watchdog surfaces any 1062 within five minutes with an explanation of what
it means and an explicit instruction not to skip it.

---

## 6. Bayes, quota and cache divergence (accepted, not fixed)

Three pieces of state are node-local by choice. Documented here so the
divergence is never mistaken for a bug:

| State | Consequence | Why it is right |
|---|---|---|
| rspamd Bayes tokens | The two classifiers drift; the same borderline message may score slightly differently | Replicating Redis puts a hard cross-node dependency on the *mail acceptance* path. A tunnel outage would degrade delivery. Not worth a few points of accuracy. |
| Quota counters | The portal shows the local node's view; may differ briefly during catch-up | Both nodes hold the same mail, so both compute the same number. Replicating makes every delivery a cross-node write conflict on one row. |
| Roundcube caches/sessions | One re-login after a failover | Replicated sessions race between consecutive requests and put a second copy of the encrypted IMAP password in the replication stream. |

The **deterministic** part of spam handling — the `X-Spam` header threshold and
`default.sieve` — is identical on both nodes, so filing decisions agree even
when scores differ slightly. `default.sieve` deliberately depends only on the
message: no clock, no randomness, no node-local state. If both nodes ever
process the same message, they must reach the same folder, or dsync sees a
conflict and you get a duplicate.

---

## 7. The bind-before-tunnel race

### The failure

Three services bind to `${SELF_WG_IP}`: MariaDB (3306), Dovecot's doveadm
listener, and nginx's ACME peer endpoint (8080). That address does not exist
until `wg-quick` has run. At boot, systemd starts units in parallel, so
occasionally a service binds before the interface exists and dies with
`EADDRNOTAVAIL`.

The failure is **intermittent**, and it never reproduces when you try — by the
time you run `systemctl restart` by hand, the tunnel is up.

### Prevention — two independent defences

1. `templates/systemd/10-hamail-wireguard.conf.tpl`, installed as a drop-in for
   **mariadb, dovecot and nginx**: `Wants=` + `After=wg-quick@wg0.service`.
   `Wants`, not `Requires` — if the tunnel genuinely cannot come up, these
   services must still start and serve local users. A dead tunnel degrades
   replication; it must never take mail service down with it.
2. `net.ipv4.ip_nonlocal_bind = 1` in `/etc/sysctl.d/99-hamail.conf`, which
   lets the bind succeed even if the interface is a fraction of a second late.

---

## 8. The nodes banning each other

### The failure

fail2ban on Node A sees, from Node B: repeated SSH connections (certificate
sync), repeated MySQL logins (replication reconnects), a burst of IMAP-ish
traffic (dsync after an outage). It bans the peer — **at the exact moment the
cluster is trying to heal**. Node B does the same in the other direction. The
cluster partitions itself and stays partitioned.

This is the most common self-inflicted outage in an HA mail pair.

### Prevention

`templates/fail2ban/jail.d/hamail.conf.tpl`:

```ini
ignoreip = 127.0.0.1/8 ::1 ${NODE_A_IP} ${NODE_B_IP} ${WG_SUBNET}
```

Both public addresses **and** the whole tunnel subnet. `scripts/95-fail2ban.sh`
verifies at deploy time that the peer is actually on the loaded ignore list and
**refuses to complete** if it is not.

### The related limitation, stated

fail2ban and nginx `limit_req` counters are node-local. An attacker alternating
between the two nodes gets twice the budget. Mitigations: the admin portal is
DNS-steered to one node, so only webmail is exposed on both; and the rate
limits are set with the doubling already accounted for.

---

## 9. `envsubst` destroying configuration files

### The failure

The natural way to template a config is `envsubst < tpl > out`. With no
arguments, `envsubst` replaces **every** `$NAME` and `${NAME}` it finds. Nginx
configs are full of `$host`, `$remote_addr`, `$upstream_addr`; Postfix uses
`$mydomain`, `$myhostname`, `$data_directory`; Dovecot uses `$mail_plugins`.

All of them get replaced with the empty string. The result is a mail server
that half-works, in ways that take a day to find.

### Prevention

`lib/common.sh :: RENDER_VARS` is an explicit whitelist, and `render()` passes
it to `envsubst` as a SHELL-FORMAT argument. Only listed names are touched.

`render()` then **greps the output for any surviving `${UPPERCASE}`** and dies
with the offending names — catching the "added a variable to `env.example` but
forgot `RENDER_VARS`" class of bug at deploy time rather than at 3 a.m.

`./deploy.sh --dry-run` renders the entire tree to a scratch directory so you
can diff before touching anything.

---

## 10. Wrong `NODE_ROLE`

### The failure

Every auto-increment offset, DKIM selector, `server_id`, `gtid_domain_id` and
the ACME leader election derive from one line in `.env`. Deploying both nodes
with `NODE_ROLE=A` produces two servers that each believe they are Node A —
identical offsets, identical selectors, two ACME leaders. The first
simultaneous write is a guaranteed collision.

### Prevention

`scripts/00-preflight.sh` enumerates the host's own addresses and compares them
against `SELF_IP` and `PEER_IP`. If the machine holds the *peer's* address, the
deploy aborts with the exact line to change. `40-mariadb.sh` then re-verifies
`server_id`, `gtid_domain_id`, increment and offset against the expected values
after MariaDB restarts.

---

## 11. Foot-guns that bite before mail ever flows

Caught in `00-preflight.sh`, because each one otherwise wastes a day:

| Check | Why |
|---|---|
| **Outbound port 25 blocked** | Linode blocks SMTP on new accounts. Everything looks healthy and no mail ever leaves. Requires a support ticket, which takes time — find out first. |
| Missing A record for the node / mail host | ACME HTTP-01 fails. Failed attempts count against the rate limit (5/hostname/week). |
| `exim4`, `sendmail`, `apache2`, `mysql-server` installed | Silent port conflicts. |
| < 2 GiB RAM | MariaDB + Dovecot + rspamd + PHP-FPM will OOM under load. |
| Clock not NTP-synchronised | Breaks replication reasoning, TLS validity and DKIM. |

And at issuance time, `75-certbot.sh` writes a probe token and fetches it over
plain HTTP **before** calling Let's Encrypt, so a webroot or firewall mistake
costs a curl instead of a rate-limit slot.

---

## 12. Smaller items found and closed

| Issue | Fix | File |
|---|---|---|
| Postfix `path_info` RCE (`/x.jpg/y.php` handed to PHP-FPM) | `try_files $fastcgi_script_name =404` before `fastcgi_pass` | `snippets/php.conf.tpl` |
| `tls_server_sni_maps` silently failing | `postmap -F` — without `-F` Postfix stores the literal path string instead of reading the file | `hamail-sni-map.sh` |
| `setup.php` left reachable — the most exploited PostfixAdmin misconfiguration | Rewritten to `deny all; return 404;` after install | `85-postfixadmin.sh` |
| Roundcube `installer/` left on disk | Deleted at install | `90-roundcube.sh` |
| Users' private IPs leaking in `Received:` headers | Dedicated `submission-cleanup` service, applied to 587/465 only so inbound mail keeps its full chain | `master.cf`, `submission_header_cleanup.tpl` |
| Over-quota mailbox cannot receive its own quota warning | `plugin/quota=…:noenforcing` on the warning delivery | `hamail-quota-warning.sh.tpl` |
| Over-quota user cannot delete their way out | `Trash:ignore`, `Junk:ignore` quota rules | `90-quota.conf.tpl` |
| Case-varying logins creating a second mailbox on one node only | `auth_username_format = %Lu` | `10-auth.conf.tpl` |
| Roundcube and PostfixAdmin hashing passwords differently → login works in webmail but not IMAP | Both delegate to the same `doveadm pw` binary | both config templates |
| `iterate_query` missing → cluster-wide resync impossible | Present and documented | `dovecot-sql.conf.ext.tpl` |
| Replication DDL run on both nodes | `45-db-schema.sh` and `90-roundcube.sh` refuse to run on Node B | both |
| Unknown `Host` header served by the first vhost (the admin portal answering on an IP) | `default_server` returning 444 | `nginx.conf.tpl` |
| Certbot rate-limit burn from a broken webroot | Pre-flight probe token | `75-certbot.sh` |
| `fetchmail` polling the same remote account from both nodes → every message twice | Disabled, with the reason recorded | `config.local.php.tpl` |
| Peer's stale certificate export going unnoticed | Leader warns when its own export is < 10 days from expiry | `hamail-cert-sync.sh.tpl` |
| Milter failure bouncing mail | `milter_default_action = accept` — a crashed spam filter must not become an outage | `main.cf.tpl` |

---

## 13. Bugs found by executing the blueprint against real binaries

The audit above was written before the configuration. The blueprint was then
**validated against actual software** — MariaDB 10.11.14, Postfix 3.8,
Dovecot 2.3.21, nginx 1.24, fail2ban, PHP 8.3 — rather than by inspection.
That found five defects that no amount of reading would have caught. All are
fixed; they are recorded here because each is a trap in its own right.

### 13.1 `tr … | head -c N` under `set -o pipefail` fails silently

`bin/gen-secrets.sh` used the idiomatic
`tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32`. `head` closes the pipe after
32 bytes, `tr` dies of `SIGPIPE`, and under `pipefail` the script exited
**with no output and no changes**. The result looked exactly like "it worked" —
and would have produced a deploy where every password was still `CHANGE_ME_*`.

Fixed by bounding the read first and terminating with `cut`, which consumes all
of its input, so no process is ever killed by a closed pipe. The same idiom in
`lib/common.sh :: randpw()` was fixed with it.

### 13.2 Two `<HOST>` tokens in one fail2ban `failregex`

fail2ban expands `<HOST>` into a **named** capture group. Two of them in one
expression is a duplicate group name, Python refuses to compile it, and the
**entire filter is disabled**. `fail2ban-regex` reports it immediately; a
running fail2ban logs it once at startup and then protects nothing while
`fail2ban-client status` still lists the jail as active.

### 13.3 fail2ban strips the `datepattern` text before matching

The custom `datepattern` in the Roundcube and PostfixAdmin filters included the
surrounding brackets. fail2ban **removes the matched date text from the line**
before applying `failregex`, so `[09/Sep/2026:22:30:01 +0000]` disappeared
entirely rather than collapsing to `[]` — and the filters matched zero lines.
This is why the shipped nginx filters are written with `\[\]`.

Both filters now keep the brackets out of the datepattern, and both were
verified with `fail2ban-regex` against real log lines: 3/3 failures matched,
successful logins correctly not matched.

### 13.4 `backend = systemd` silently unhooks every file-based jail

The most dangerous of the five. A global `backend = systemd` in `[DEFAULT]`
makes fail2ban **ignore every `logpath`** and read the journal instead. The
jails that watch files — nginx's access and error logs, Roundcube's
`errors.log`, fail2ban's own log — ended up with **no log source at all**.
`fail2ban-client -d | grep addlogpath` returned zero results, while
`fail2ban-client status` cheerfully listed all eleven jails as active.

Fixed: `backend = auto` in `[DEFAULT]`, with `backend = systemd` stated
explicitly on the jails whose services log through journald (sshd, Postfix,
Dovecot). Verified — every jail now resolves to a real log source.

### 13.5 A heredoc delimiter that collides with its own body

`hamail-add-domain.sh` used `cat <<DNS` and then printed a line beginning
`DNS RECORDS TO PUBLISH FOR …`. Bash tolerates it (a terminator must be alone
on its line) so `bash -n` passed, but it is a landmine for the next person who
edits that block. Renamed to `DNSRECORDS`.

### What the validation confirmed as correct

| Check | Result |
|---|---|
| `schema.sql` against MariaDB 10.11 | 15 tables, all grants, seed rows — loads clean |
| All 12 replication directives | Accepted; parse to the intended values (increment 2 / offset 1 · 2, `gtid_domain_id` 1 · 2, ROW, READ-COMMITTED) |
| `postfix check` + full `postconf` parse | No errors, no warnings |
| All 10 Postfix SQL maps, against live data | Every one returns the correct value, including multi-line `query =` continuation, catch-all, alias-domain chains and `tls_policy` |
| `doveconf -n` | Parses clean; `mail_replica`, `replication_*`, `quota = count`, `quota_clone` all as intended |
| All 3 Sieve scripts | Compile with `sievec` |
| `nginx -t` on the full rendered config | Syntax OK (this is also what proved `DH_BITS` must be ≥ 2048) |
| PHP syntax of both app configs | Clean |
| `shellcheck -S warning` on every script, source and rendered | Clean |
| Whitelisted `envsubst` | Every runtime variable survived — `$host`, `$remote_addr`, `$mydomain`, `$data_directory`, `$mail_plugins`, rspamd's `$selector.$domain` |
| Role derivation, A vs B | Every value correctly mirrored |

---

## What this design does not solve

Stated plainly, because a blueprint that claims no limits is not trustworthy:

1. **Administrative writes are not active-active.** They are steered. §5.
2. **Replication is asynchronous.** A node that dies with unreplicated
   transactions in its binlog loses them. The window is normally sub-second;
   it is not zero. Synchronous replication across 180 ms would make every
   admin action take ~400 ms and every delivery depend on both nodes being up —
   a worse trade for this workload.
3. **A tunnel-only partition is not automatically resolved.** Both nodes stay
   live and diverge until it heals. This is deliberate: the alternative is
   fencing, and fencing a mail server that is still reachable from the internet
   means refusing mail you could have accepted.
4. **Two nodes cannot establish a quorum.** There is no third witness, so no
   automatic leader election is safe. Promotion is a human decision (or an
   external monitor's), never a self-diagnosis.
5. **Bayes, quota and cache state diverge by design.** §6.
