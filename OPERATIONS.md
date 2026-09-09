# Day-two operations runbook

Short, task-oriented. For architecture see `../README.md`; for the reasoning
behind any "do not do X" below, see `AUDIT.md`.

---

## Add a hosted domain

```bash
# 1. On BOTH nodes — DKIM key, certificate, and the DNS to publish
[both] hamail-add-domain.sh newdomain.tld

# 2. Publish the printed records (both DKIM selectors!)

# 3. Add the domain in the admin portal (Node A / the write leader)
#    Domain List → New Domain

# 4. Verify
[both] hamail-health.sh
[ext]  swaks --server mail.newdomain.tld:587 --tls --auth ... \
             --to check-auth@verifier.port25.com
```

No configuration file changes and no restarts: `dkim_signing.conf` interpolates
`$selector.$domain` into the key path, and the Postfix/Dovecot maps read the
database.

---

## Add a mailbox

Through the portal at `https://admin.${DOMAIN}/` on the **write leader**.
It replicates to the peer in well under a second.

By hand, if the portal is unavailable — run on **one** node only:

```bash
HASH=$(doveadm pw -s ARGON2ID -p 'the-password')
mariadb <<SQL
USE mailserver;
INSERT INTO mailbox (username,password,name,maildir,quota,local_part,domain,
                     created,modified,active)
VALUES ('bob@example.com','$HASH','Bob','example.com/bob/',
        2147483648,'bob','example.com',NOW(),NOW(),1);
SQL
```

Verify on the peer before telling the user:

```bash
[peer] doveadm auth test bob@example.com 'the-password'
```

---

## Rotate a DKIM key

Zero-downtime, because the two nodes have independent selectors.

```bash
# 1. New key under a new selector on ONE node
[A] openssl genrsa -out /var/lib/rspamd/dkim/sg2.example.com.key 2048
[A] chown _rspamd:_rspamd /var/lib/rspamd/dkim/sg2.example.com.key
[A] chmod 400 /var/lib/rspamd/dkim/sg2.example.com.key
[A] openssl rsa -in /var/lib/rspamd/dkim/sg2.example.com.key -pubout | sed '1d;$d' | tr -d '\n'

# 2. Publish sg2._domainkey.example.com, leaving sg._domainkey in place
# 3. Wait for DNS propagation (at least the old TTL)
# 4. Switch the node over
[A] sed -i 's/selector = "sg"/selector = "sg2"/' /etc/rspamd/local.d/dkim_signing.conf
[A] sed -i 's|sg\.example\.com\.key|sg2.example.com.key|' /etc/rspamd/local.d/dkim_signing.conf
[A] systemctl reload rspamd
[A] # update NODE_A_DKIM_SELECTOR in .env so a redeploy does not revert it

# 5. Verify, then repeat for Node B. Only after BOTH are verified,
#    remove the old TXT records.
```

Keep the old public key published for at least a week: messages already in
transit are still signed with it.

---

## Rotate the WireGuard keys

```bash
[A] wg genkey | tee /etc/wireguard/keys/private.key.new | wg pubkey
# put the new public key into Node B's .env as WG_PEER_PUBKEY
[B] ./scripts/20-wireguard.sh          # B now accepts both? No — WireGuard
                                       # peers hold one key, so do this in a
                                       # short window:
[A] mv /etc/wireguard/keys/private.key{.new,} && ./scripts/20-wireguard.sh
```

The tunnel drops for a few seconds. Replication and dsync both resume by
themselves — neither loses data, both are restartable by design.

---

## Rotate the database passwords

```bash
# 1. Change the values in .env on BOTH nodes (they must stay identical)
# 2. Apply on BOTH nodes:
[both] mariadb -e "ALTER USER 'mailuser'@'localhost' IDENTIFIED BY 'newpass';"
[both] ./scripts/55-postfix.sh
[both] ./scripts/60-dovecot.sh
[both] ./scripts/85-postfixadmin.sh
[both] ./scripts/90-roundcube.sh
```

For `DB_REPL_PASS`, change it on both nodes, then on each:

```bash
[both] STOP SLAVE; CHANGE MASTER TO MASTER_PASSWORD='newpass'; START SLAVE;
```

---

## Move the admin write leader to Node B

```bash
[B] hamail-dns-failover.sh --promote-self        # refuses while A is reachable
# or edit the admin.${DOMAIN} A record by hand
[B] echo "$(hostname -f)" > /var/lib/ha-mail/admin-leader
```

Also flip `IS_CERT_LEADER` if the move is permanent: set `NODE_ROLE=B`
semantics by swapping the A/B blocks in `.env`, or re-issue the shared
certificate on B and point `hamail-cert-sync.sh` the other way. For a temporary
failover, leave the ACME leader alone — the certificate has ~60 days of life
and Node A will be back long before it matters.

---

## Take a node out for maintenance, gracefully

```bash
# 1. Drain: stop accepting NEW mail, keep serving existing sessions
[A] postfix stop                      # senders immediately use the other MX
[A] doveadm replicator replicate -f '*'   # push everything to the peer
[A] watch doveadm replicator status   # wait for the queue to reach 0

# 2. Now stop the rest
[A] systemctl stop dovecot nginx

# 3. Maintenance, reboot, whatever

# 4. Return
[A] systemctl start mariadb dovecot postfix nginx
[A] hamail-health.sh
[A] doveadm replicator replicate -f '*'
```

Stopping Postfix first is the important part: SMTP failover is instantaneous,
so no inbound mail is lost, whereas stopping Dovecot first would leave Postfix
accepting mail it cannot deliver.

---

## Read the logs

```bash
# Mail flow
journalctl -u postfix -f
tail -f /var/log/mail.log

# One message end to end
grep <queue-id> /var/log/mail.log

# Replication
tail -f /var/log/ha-mail/replication.log
journalctl -u dovecot -f | grep -i repl

# Spam decisions
journalctl -u rspamd -f
rspamc stat

# Certificate sync
tail -f /var/log/ha-mail/cert.log

# Who is banned
fail2ban-client status dovecot
fail2ban-client set dovecot unbanip 203.0.113.99
```

---

## Back up

Replication is **not** a backup: a deletion replicates just as faithfully as a
creation. Take real backups, and take them from **one** node only (they are
identical, and dumping both doubles the load for nothing).

```bash
# Database — consistent, GTID-aware
mariadb-dump --single-transaction --gtid --routines --triggers --events \
             --databases mailserver roundcube \
             | gzip > /backup/mail-$(date +%F).sql.gz

# Mail store — Maildir is plain files, so any file-level backup works
tar -C /var/vmail -czf /backup/vmail-$(date +%F).tar.gz .

# Configuration and secrets
tar -czf /backup/etc-$(date +%F).tar.gz \
    /etc/postfix /etc/dovecot /etc/nginx /etc/mysql \
    /etc/rspamd /etc/wireguard /etc/letsencrypt \
    /var/lib/rspamd/dkim /opt/ha-mail/.env
```

Test a restore into a throwaway VM at least once. A backup you have never
restored is a hypothesis.

---

## Things never to do

| Never | Because |
|---|---|
| `doveadm backup` against a live peer | One-way and destructive — deletes anything the destination has that the source does not. Use `doveadm sync`. |
| `rsync` `/var/vmail` between nodes | Resurrects deleted mail or deletes new mail, depending on direction. Use `doveadm sync`. |
| `SET GLOBAL sql_slave_skip_counter = 1` | Guarantees permanent silent divergence. Fix the row instead (`TESTING.md` §6). |
| Add `slave_skip_errors` to `50-server.cnf` | Same, but automated and forever. |
| Publish `admin.${DOMAIN}` at both nodes | Invites a natural-key collision that stops replication (`AUDIT.md` §5). |
| Run `45-db-schema.sh` on both nodes | Creates two unrelated table histories. |
| Remove the peer from `fail2ban` `ignoreip` | The nodes ban each other during recovery. |
| Point a node hostname at both IPs | Breaks PTR, HELO and certificate issuance. |
| Move DMARC past `p=none` before both selectors verify | Half your mail starts failing. |
| Put `/var/vmail` on shared/network storage | The failure mode this whole architecture exists to avoid. |
