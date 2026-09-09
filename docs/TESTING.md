# PHASE 7 — Verification and testing playbook

Concrete commands. Run them in order the first time; keep §1–§4 as the
post-change regression suite.

Conventions: `[A]` = run on Node A, `[B]` = Node B, `[both]` = both,
`[ext]` = a third machine that is neither node.

---

## 0. One-command overview

```bash
[both] hamail-health.sh
```

Checks services, listeners, tunnel, certificate validity and key match, DKIM
record vs. local key, MX/A/SPF/DMARC/PTR, queue depth, disk, and the
auto-increment invariants. Exit codes: `0` healthy, `1` warnings, `2` errors.

```bash
[both] hamail-repl-watchdog.sh      # replication specifically
[both] journalctl -u hamail-health.timer -u hamail-repl-watchdog.timer --since -1d
```

---

## 1. MariaDB master ⇄ master replication

### 1.1 Both directions are running

```bash
[both] mariadb -e "SHOW SLAVE STATUS\G" | \
       grep -E 'Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master|Last_Errno|Last_Error|Master_Host|Using_Gtid'
```

Expected on **each** node:

```
              Master_Host: 10.77.0.2      (peer's tunnel IP)
         Slave_IO_Running: Yes
        Slave_SQL_Running: Yes
    Seconds_Behind_Master: 0
               Last_Errno: 0
               Last_Error:
               Using_Gtid: Slave_Pos
```

`SHOW SLAVE STATUS` returning **empty** means this node is not replicating at
all — run `scripts/50-replication.sh`.

### 1.2 Each node is a master with a live binlog

```bash
[both] mariadb -e "SHOW MASTER STATUS\G"
[both] mariadb -e "SELECT @@server_id, @@gtid_domain_id, @@gtid_binlog_pos, @@log_slave_updates"
```

`server_id` and `gtid_domain_id` must be **1 on A and 2 on B**, and
`log_slave_updates` must be `1`.

### 1.3 The collision guards

```bash
[A] mariadb -e "SELECT @@auto_increment_increment, @@auto_increment_offset"
    # expect 2, 1
[B] mariadb -e "SELECT @@auto_increment_increment, @@auto_increment_offset"
    # expect 2, 2
```

Prove they actually work — insert on both nodes at once and confirm the id
sequences never intersect:

```bash
[A] mariadb -e "USE mailserver; INSERT INTO log (timestamp,username,domain,action,data)
                VALUES (NOW(),'test','example.com','pk-test','from-A');"
[B] mariadb -e "USE mailserver; INSERT INTO log (timestamp,username,domain,action,data)
                VALUES (NOW(),'test','example.com','pk-test','from-B');"

sleep 3

[both] mariadb -e "SELECT id, data, MOD(id,2) AS parity FROM mailserver.log
                   WHERE action='pk-test' ORDER BY id;"
```

Expected on **both** nodes — identical rows, Node A's ids odd, Node B's even:

```
+----+--------+--------+
| id | data   | parity |
+----+--------+--------+
| 15 | from-A |      1 |
| 16 | from-B |      0 |
+----+--------+--------+
```

Cleanup:

```bash
[A] mariadb -e "USE mailserver; DELETE FROM log WHERE action='pk-test';"
```

### 1.4 Round-trip latency measurement

```bash
[A] mariadb -e "USE mailserver; INSERT INTO log (timestamp,username,domain,action,data)
                VALUES (NOW(6),'test','example.com','latency','$(date +%s%N)');"

[B] mariadb -e "SELECT data AS sent_ns,
                       (UNIX_TIMESTAMP(NOW(6))*1000000000 - data)/1000000 AS lag_ms
                FROM mailserver.log WHERE action='latency' ORDER BY id DESC LIMIT 1;"
```

Expect roughly the WireGuard RTT plus a few ms — around **180–250 ms** on a
Singapore ↔ US link. Anything over a second means the replica is backlogged.

### 1.5 Filters are behaving

```bash
[A] mariadb -e "USE mailserver; UPDATE quota2 SET bytes=bytes WHERE 1=0;"
[both] mariadb -e "SHOW VARIABLES LIKE 'replicate_ignore_table'"
```

`quota`, `quota2` and the Roundcube session/cache tables must be listed. If
they are not, every delivery becomes a cross-node write conflict (`AUDIT.md`
§1, §6).

---

## 2. Dovecot dsync mailbox replication

### 2.1 The replicator is alive

```bash
[both] doveadm replicator status
```

```
Queued 'sync' requests        0
Queued 'high' requests        0
Queued 'low' requests         0
Queued 'failed' requests      0
Queued 'full resync' requests 0
Waiting 'failed' requests     0
Total number of known users   12
```

Non-zero **failed** requests, or a **queued** count that keeps growing, means
the tunnel or the peer cannot keep up.

```bash
[both] doveadm replicator status '*'      # per-user detail
[both] doveadm replicator dsync-status    # what is running right now
```

### 2.2 Configuration sanity

```bash
[both] doveconf -n | grep -E 'mail_replica|replication_|doveadm_port|mail_plugins'
[both] ss -ltnp | grep 12345      # must show 10.77.0.x:12345, NEVER 0.0.0.0
```

The replication plugin must appear in `mail_plugins`. If it does not, nothing
replicates and everything else looks perfectly healthy.

### 2.3 Live end-to-end test — delivery

```bash
[A] doveadm mailbox list -u alice@example.com
[A] echo "replication test $(date -Is)" | \
       /usr/lib/dovecot/dovecot-lda -d alice@example.com

# within a second or two:
[B] doveadm search -u alice@example.com mailbox INBOX text "replication test"
[B] doveadm fetch -u alice@example.com text mailbox INBOX \
       SUBJECT "replication test" | head -20
```

Measure it:

```bash
[A] echo "timing $(date +%s%N)" | /usr/lib/dovecot/dovecot-lda -d alice@example.com
[B] time until doveadm search -u alice@example.com mailbox INBOX text "timing" \
        | grep -q .; do sleep 0.2; done
```

Sub-second is normal. Anything over ~5 s warrants checking
`doveadm replicator status`.

### 2.4 Flag changes replicate (not just messages)

Flags are the thing naive sync approaches get wrong.

```bash
[A] doveadm flags add -u alice@example.com '\Seen' mailbox INBOX ALL
sleep 3
[B] doveadm search -u alice@example.com mailbox INBOX unseen
    # expect NO output — every message is seen on B too
```

### 2.5 Folder creation, rename and subscription

```bash
[A] doveadm mailbox create -u alice@example.com "Projects/HA-Test"
[A] doveadm mailbox subscribe -u alice@example.com "Projects/HA-Test"
sleep 3
[B] doveadm mailbox list -s -u alice@example.com | grep HA-Test

[A] doveadm mailbox rename -u alice@example.com "Projects/HA-Test" "Projects/Renamed"
sleep 3
[B] doveadm mailbox list -u alice@example.com | grep Renamed
```

### 2.6 Expunge replicates (deletion, not resurrection)

```bash
[A] doveadm expunge -u alice@example.com mailbox "Projects/Renamed" all
[A] doveadm mailbox delete -u alice@example.com "Projects/Renamed"
sleep 5
[B] doveadm mailbox list -u alice@example.com | grep Renamed
    # expect NO output
```

If the folder reappears on Node A a few seconds later, replication is running
one-way and Node B is pushing it back — check `mail_replica` on both nodes.

### 2.7 Forced resync (the recovery command)

```bash
[A] doveadm sync -u alice@example.com tcp:10.77.0.2:12345      # one user
[A] doveadm replicator replicate -f '*'                        # everyone
```

> `doveadm sync` is **bidirectional and merging** — safe on a live pair.
> `doveadm backup` is **one-way and destructive** — it deletes anything on the
> destination that is not on the source. Never run it against a live peer.

### 2.8 Sieve scripts replicate

Sieve lives in the user's home, so it rides along with the mail:

```bash
[A] doveadm sieve list -u alice@example.com
[A] echo 'require "fileinto"; if header :contains "subject" "test" { fileinto "Junk"; }' \
       | doveadm sieve put -u alice@example.com hatest
sleep 3
[B] doveadm sieve list -u alice@example.com | grep hatest
[B] doveadm sieve get  -u alice@example.com hatest
```

---

## 3. Admin portal write → peer visibility

The end-to-end test of Phase 3.

### 3.1 Through the UI

1. `[ext]` Open `https://admin.example.com/` and sign in.
2. **Virtual List → Add Mailbox**: `hatest@example.com`, quota 100 MB.
3. Immediately, on **Node B**:

```bash
[B] mariadb -e "SELECT username, domain, quota, active, created
                FROM mailserver.mailbox WHERE username='hatest@example.com'\G"
```

The row should be present. Time it:

```bash
[B] time until mariadb -N -B -e \
      "SELECT 1 FROM mailserver.mailbox WHERE username='hatest@example.com'" \
      | grep -q 1; do sleep 0.2; done
```

Expect well under a second on a healthy link.

### 3.2 The account actually works on the peer

Database replication is necessary but not sufficient — prove authentication and
delivery work on the node that never saw the write:

```bash
[B] doveadm auth test hatest@example.com <password>
    # expect: passdb: hatest@example.com auth succeeded

[B] swaks --server 127.0.0.1:587 --tls \
          --auth --auth-user hatest@example.com --auth-password '<password>' \
          --from hatest@example.com --to alice@example.com \
          --header "Subject: sent via node B"
```

### 3.3 Aliases and catch-all

```bash
# In the portal on Node A: add alias sales@example.com -> alice@example.com
[B] postmap -q sales@example.com mysql:/etc/postfix/sql/mysql-virtual-alias-maps.cf
    # expect: alice@example.com

# Add a catch-all: alias "@example.com" -> alice@example.com
[B] postmap -q @example.com mysql:/etc/postfix/sql/mysql-virtual-alias-maps.cf
[B] swaks --server 127.0.0.1:25 --to nosuchuser@example.com --from ext@example.org
    # expect 250, delivered to alice
```

### 3.4 Password reset crosses nodes

The reset token is stored in `mailbox.token`, so a link issued by Node A must
be redeemable on Node B — which matters because DNS may steer the user's
browser to either.

```bash
# Trigger a reset in the portal, then:
[B] mariadb -e "SELECT username, token, token_validity
                FROM mailserver.mailbox WHERE username='hatest@example.com'\G"
```

### 3.5 Quota changes take effect on both

```bash
# Change the quota in the portal to 50 MB, then:
[both] doveadm quota get -u hatest@example.com
```

Both nodes should report the new limit. **Usage** may differ briefly — the
quota tables are node-local by design (`AUDIT.md` §6).

### 3.6 Cleanup

```bash
# Delete hatest@example.com in the portal, then confirm on the peer:
[B] mariadb -e "SELECT COUNT(*) FROM mailserver.mailbox WHERE username='hatest@example.com'"
```

---

## 4. Full failure of Node A

**Run this drill deliberately, in a maintenance window, before you need it.**

### 4.1 Baseline

```bash
[both] hamail-health.sh
[A]    mariadb -N -B -e "SELECT @@gtid_binlog_pos"
[B]    mariadb -N -B -e "SELECT @@gtid_slave_pos"
```

Record both GTID positions; you will compare them after recovery.

### 4.2 Kill Node A

Choose the most realistic failure you can tolerate:

```bash
# (a) hard power off — closest to a real outage
[ext] linode-cli linodes shutdown <NODE_A_ID>

# (b) network isolation, keeping the console
[A] ufw --force reset && ufw default deny incoming && \
    ufw allow 22/tcp && ufw --force enable

# (c) service-level failure only
[A] systemctl stop postfix dovecot nginx mariadb
```

### 4.3 Inbound mail still works

```bash
[ext] dig +short MX example.com                 # both still listed
[ext] swaks --to alice@example.com --from you@elsewhere.org \
            --server us1.example.com --header "Subject: failover inbound"
```

Then verify a real sender fails over on its own — send from an external mailbox
(Gmail, etc.) and confirm delivery. The `Received:` chain in the delivered
message shows `us1`, proving the retry happened.

```bash
[B] doveadm search -u alice@example.com mailbox INBOX text "failover inbound"
```

### 4.4 IMAP and submission still work

```bash
[ext] openssl s_client -connect mail.example.com:993 -servername mail.example.com </dev/null 2>&1 \
      | grep -E 'subject=|Verify return code'

[ext] swaks --server mail.example.com:587 --tls \
            --auth --auth-user alice@example.com --auth-password '<password>' \
            --to alice@example.com --header "Subject: failover submission"
```

The client library retries the second A record automatically. Time it — 5–20 s
is normal for the first connection after the failure.

### 4.5 Webmail still works

```bash
[ext] curl -sSI https://webmail.example.com/ | head -1     # expect 200
```

Then log in through a browser. Any session that was live on Node A is gone
(sessions are node-local by design) — one re-login, nothing worse.

### 4.6 Take over the admin portal

```bash
[B] hamail-dns-failover.sh --status
[B] hamail-dns-failover.sh --promote-self
```

The script refuses while Node A is still reachable — that guard is the point.
Without the Linode API configured, edit the `admin.example.com` A record by
hand, or for an immediate operator fix:

```bash
[ext] echo "198.51.100.20 admin.example.com" | sudo tee -a /etc/hosts
```

Confirm the portal identifies the node it is running on — the page title reads
`[node B: us1]`.

### 4.7 Verify mail is not being lost

```bash
[B] mailq | tail -5
[B] postqueue -p | grep -c '^[A-F0-9]'
[B] journalctl -u postfix --since -10min | grep -Ei 'reject|error|warning'
```

Deferred mail addressed to Node A is expected and correct — it will be
delivered when Node A returns. Nothing should be **bouncing**.

### 4.8 Bring Node A back

```bash
[ext] linode-cli linodes boot <NODE_A_ID>
[A]   hamail-health.sh
```

Watch the catch-up:

```bash
[A] watch -n2 'mariadb -e "SHOW SLAVE STATUS\G" | grep -E "Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master"'
[A] watch -n2 'doveadm replicator status'
```

`Seconds_Behind_Master` should fall to 0, and the replicator queue should drain.

Force a full mailbox reconciliation to be certain nothing was missed:

```bash
[A] doveadm replicator replicate -f '*'
[A] doveadm replicator status '*' | grep -v ' - ' | head
```

Restore DNS:

```bash
[B] hamail-dns-failover.sh --restore
```

### 4.9 Prove convergence

```bash
[both] mariadb -N -B -e "SELECT COUNT(*) FROM mailserver.mailbox"
[both] mariadb -N -B -e "SELECT COUNT(*) FROM mailserver.alias"
[both] mariadb -N -B -e "SELECT MD5(GROUP_CONCAT(username ORDER BY username))
                         FROM mailserver.mailbox"
```

The MD5 must match on both nodes.

```bash
[both] doveadm mailbox status -u alice@example.com messages vsize INBOX
```

Message counts and total size must match. If they do not, run
`doveadm sync -u alice@example.com tcp:<peer-wg-ip>:12345` on either node and
re-check.

### 4.10 Also drill the reverse

Everything above with the roles swapped. Node B is the ACME follower and the
admin standby, so its failure exercises **different** paths — in particular,
certificate renewal continues normally while B is down, and resumes pulling
when it returns.

---

## 5. Rebuilding a destroyed node

If Node B is lost entirely and rebuilt from scratch:

```bash
[B-new] # deploy through stage 40 only
        ./deploy.sh --to 40
        # do NOT run 45-db-schema.sh — the data comes from A
        ./scripts/50-replication.sh      # seeds from A, then follows it
        ./deploy.sh --from 55
```

`50-replication.sh` detects the empty database and seeds it with
`mariadb-dump --gtid --single-transaction` from Node A, so the GTID position is
recorded inside the dump and replication resumes at exactly the right place.

For the mail store:

```bash
[A] doveadm sync -u <each-user> tcp:10.77.0.2:12345
# or, for everyone at once:
[A] doveadm replicator replicate -f '*'
```

Do **not** rsync `/var/vmail` between nodes, and do **not** use
`doveadm backup`. Let dsync rebuild it.

---

## 6. Recovering from a duplicate-key replication stall

Symptom: `Last_Errno: 1062`, SQL thread stopped, the watchdog alerting.

```bash
[both] mariadb -e "SHOW SLAVE STATUS\G" | grep -A3 Last_Error
```

Identify the conflicting row, then decide which side is authoritative:

```bash
[A] mariadb -e "SELECT * FROM mailserver.mailbox WHERE username='<the address>'\G"
[B] mariadb -e "SELECT * FROM mailserver.mailbox WHERE username='<the address>'\G"
```

**Do not** run `SET GLOBAL sql_slave_skip_counter = 1`. Skipping the event means
the two databases now disagree about that row and will diverge silently
forever.

Correct procedure:

1. Decide which node's version is authoritative (usually the earlier `created`
   timestamp, or whichever the admin intended).
2. On the **losing** node, delete or correct the row so the incoming event can
   apply cleanly.
3. `START SLAVE;` on the stalled node.
4. Verify with the `MD5(GROUP_CONCAT(...))` check in §4.9.
5. Confirm `admin.${DOMAIN}` points at exactly one node — a 1062 on a natural
   key means two people wrote to two nodes, which the steering exists to
   prevent (`AUDIT.md` §5).

---

## 7. Mail authentication from BOTH nodes

The most-skipped test, and the one that most often ships broken.

```bash
[ext] swaks --server sg1.example.com:587 --tls \
            --auth --auth-user alice@example.com --auth-password '<password>' \
            --from alice@example.com --to check-auth@verifier.port25.com

[ext] swaks --server us1.example.com:587 --tls \
            --auth --auth-user alice@example.com --auth-password '<password>' \
            --from alice@example.com --to check-auth@verifier.port25.com
```

Both replies must show:

```
SPF check:          pass
DKIM check:         pass
DMARC check:        pass
```

...and the DKIM result must name the **correct selector per node** (`sg` from
Node A, `us` from Node B). If one node passes and the other does not, that
node's TXT record is missing or truncated — see `DNS.md` §1.6.

Inspect a delivered header:

```bash
[B] doveadm fetch -u alice@example.com hdr mailbox INBOX \
        SUBJECT "..." | grep -Ei 'dkim-signature|authentication-results|received:'
```

Check the signature yourself:

```bash
[both] rspamadm dkim_keygen -s test -d example.com >/dev/null && echo "rspamd dkim tooling ok"
[both] openssl rsa -in /var/lib/rspamd/dkim/<selector>.example.com.key -pubout | \
       sed '1d;$d' | tr -d '\n' > /tmp/local.pub
[ext]  dig +short TXT <selector>._domainkey.example.com | tr -d '"' | sed 's/.*p=//' > /tmp/dns.pub
       diff /tmp/local.pub /tmp/dns.pub && echo "DKIM record matches the key"
```

---

## 8. Certificate synchronisation

```bash
[A] ls -la /var/lib/ha-mail/cert-export/mail.example.com/
[A] cat /var/lib/ha-mail/cert-export/mail.example.com/SERIAL

[B] hamail-cert-sync.sh          # pull now
[B] openssl x509 -in /etc/letsencrypt/live/mail.example.com/fullchain.pem \
        -noout -serial -enddate
```

Serials must match. Then confirm the loop-prevention behaviour:

```bash
[B] hamail-cert-sync.sh          # second run
    # expect: "already current (serial ...); no reload"
[A] hamail-cert-sync.sh
    # expect: "this node is the ACME leader; nothing to pull (by design)"
```

That asymmetry is the loop prevention (`AUDIT.md` §2).

Dry-run a renewal on the leader:

```bash
[A] certbot renew --dry-run
[A] journalctl -u nginx -u postfix -u dovecot --since -5min | grep -i reload
```

Test the cross-node ACME challenge path:

```bash
[A] echo hello > /var/www/letsencrypt/.well-known/acme-challenge/probe
[ext] curl -s http://sg1.example.com/.well-known/acme-challenge/probe   # served locally
[ext] curl -s http://us1.example.com/.well-known/acme-challenge/probe   # proxied from A
    # both must print "hello"
[A] rm /var/www/letsencrypt/.well-known/acme-challenge/probe
```

---

## 9. Security regression checks

```bash
[ext] nmap -Pn -p 22,25,80,110,143,443,465,587,993,995,3306,4190,11334,12345 sg1.example.com
```

Open: 22, 25, 80, 143, 443, 465, 587, 4190.
**Closed/filtered: 110, 995, 3306, 11334, 12345.** Anything else on that second
list being open is a finding.

```bash
[ext] swaks --server mail.example.com:25 --from spammer@evil.org \
            --to victim@notyourdomain.com
      # expect: 554 Relay access denied

[ext] swaks --server mail.example.com:587 --tls \
            --auth --auth-user alice@example.com --auth-password '<password>' \
            --from bob@example.com --to alice@example.com
      # expect: 553 Sender address rejected: not owned by user
      # (this is smtpd_sender_login_maps stopping tenant-on-tenant spoofing)

[ext] curl -sI https://admin.example.com/setup.php   # expect 404
[ext] curl -sI http://webmail.example.com/           # expect 301 to https
[ext] curl -sI https://webmail.example.com/ | grep -Ei 'strict-transport|content-security|x-frame'
```

Brute-force protection:

```bash
[both] fail2ban-client status
[both] fail2ban-client status dovecot
[both] fail2ban-client get sshd ignoreip     # MUST list both node IPs + 10.77.0.0/24
```

That last one is not optional — without it the nodes ban each other during
recovery (`AUDIT.md` §8).

---

## 10. Regression suite after any change

```bash
[both] hamail-health.sh                       # 0 errors
[both] hamail-repl-watchdog.sh                # exit 0
[both] postfix check && doveconf -n >/dev/null && nginx -t
[A]    # §1.3 dual-insert parity test
[A]    # §2.3 dsync delivery test
[ext]  # §7 authentication from both nodes
```

Before any config change, preview it without touching the system:

```bash
[both] ./deploy.sh --dry-run
       diff -ru /etc/postfix /tmp/hamail-dryrun-A/etc/postfix
       diff -ru /etc/dovecot /tmp/hamail-dryrun-A/etc/dovecot
```
