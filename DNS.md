# PHASE 6 — DNS blueprint

Every record needed for one domain on this cluster. Substitute your own values;
the placeholders match `.env` exactly.

Reference values used below:

| Placeholder | Example |
|---|---|
| `${DOMAIN}` | `example.com` |
| `${NODE_A_IP}` | `203.0.113.10` (Singapore) |
| `${NODE_B_IP}` | `198.51.100.20` (United States) |
| `${NODE_A_HOSTNAME}` | `sg1.example.com` |
| `${NODE_B_HOSTNAME}` | `us1.example.com` |
| `${NODE_A_DKIM_SELECTOR}` | `sg` |
| `${NODE_B_DKIM_SELECTOR}` | `us` |

---

## 1. The complete record table

### 1.1 Node hostnames — the anchor records

These must exist **before** anything else, because reverse DNS, HELO and
certificate issuance all depend on them. Each points at exactly one node.

| Name | Type | TTL | Value | Notes |
|---|---|---|---|---|
| `${NODE_A_HOSTNAME}` | A | 3600 | `${NODE_A_IP}` | One node only. Never round-robin. |
| `${NODE_B_HOSTNAME}` | A | 3600 | `${NODE_B_IP}` | One node only. |

> **Never** give a node hostname two A records. It is the name in the PTR, in
> the HELO and in the MX; it must identify one machine unambiguously.

### 1.2 MX — inbound mail failover

| Name | Type | TTL | Priority | Value |
|---|---|---|---|---|
| `${DOMAIN}` | MX | 3600 | **10** | `${NODE_A_HOSTNAME}.` |
| `${DOMAIN}` | MX | 3600 | **10** | `${NODE_B_HOSTNAME}.` |

**Equal priority is deliberate.** Both nodes are full peers with the same
database and the same mail store; there is no reason to prefer one, and equal
priority makes senders distribute load and fail over immediately.

Use unequal priorities (10 / 20) only if you want the higher number as a
cold standby — which this architecture does not.

Common mistakes:

- **Do not** point an MX at an IP address. RFC 5321 forbids it and many senders
  reject the domain outright.
- **Do not** point an MX at a CNAME. Same problem.
- **Do** include the trailing dot if your provider's UI is not zone-relative.

### 1.3 Service names — client failover

| Name | Type | TTL | Value |
|---|---|---|---|
| `mail.${DOMAIN}` | A | **300** | `${NODE_A_IP}` |
| `mail.${DOMAIN}` | A | **300** | `${NODE_B_IP}` |
| `webmail.${DOMAIN}` | A | **300** | `${NODE_A_IP}` |
| `webmail.${DOMAIN}` | A | **300** | `${NODE_B_IP}` |
| `autoconfig.${DOMAIN}` | A | 300 | `${NODE_A_IP}` |
| `autoconfig.${DOMAIN}` | A | 300 | `${NODE_B_IP}` |
| `autodiscover.${DOMAIN}` | A | 300 | `${NODE_A_IP}` |
| `autodiscover.${DOMAIN}` | A | 300 | `${NODE_B_IP}` |

TTL 300 is the practical floor — lower values are widely ignored and just
increase query volume. This is what makes a DNS-driven failover take minutes
rather than hours.

### 1.4 Admin portal — SINGLE node, on purpose

| Name | Type | TTL | Value |
|---|---|---|---|
| `admin.${DOMAIN}` | A | **300** | `${NODE_A_IP}` **only** |

PostfixAdmin runs on both nodes, but administrative **writes** are steered to
one at a time. Publishing both addresses invites two admins to create the same
mailbox on opposite nodes, which deadlocks replication with a duplicate-key
error that no amount of configuration can prevent. See `AUDIT.md` §5.

Failover: `hamail-dns-failover.sh --promote-self` on the survivor, or edit this
one record.

### 1.5 SPF — one record, both nodes

| Name | Type | TTL | Value |
|---|---|---|---|
| `${DOMAIN}` | TXT | 3600 | `v=spf1 ip4:${NODE_A_IP} ip4:${NODE_B_IP} -all` |

Rules that are not optional:

- **Exactly one** `v=spf1` record per domain. Two records is a `permerror` and
  everything fails.
- `-all` (hard fail), not `~all`, once you have verified both nodes send
  correctly. Start with `~all` for a week if you are nervous.
- Stay under **10 DNS-resolving mechanisms** (`include`, `a`, `mx`, `ptr`,
  `exists`). Using literal `ip4:` costs zero lookups, which is why this
  blueprint uses IPs rather than `a:sg1.example.com`.
- If you also send through a third party, append its `include:` — and re-check
  the lookup count.

Optional, for subdomains that should never send:

| Name | Type | Value |
|---|---|---|
| `*.${DOMAIN}` | TXT | `v=spf1 -all` |

### 1.6 DKIM — one record per node

| Name | Type | TTL | Value |
|---|---|---|---|
| `${NODE_A_DKIM_SELECTOR}._domainkey.${DOMAIN}` | TXT | 3600 | `v=DKIM1; k=rsa; p=<Node A public key>` |
| `${NODE_B_DKIM_SELECTOR}._domainkey.${DOMAIN}` | TXT | 3600 | `v=DKIM1; k=rsa; p=<Node B public key>` |

Get the exact values from each node:

```bash
cat /var/lib/ha-mail/dkim-sg.txt      # on Node A
cat /var/lib/ha-mail/dkim-us.txt      # on Node B
```

**The 255-character trap.** A 2048-bit key does not fit in a single TXT string.
Some providers split it for you; some truncate it silently. A truncated record
is syntactically valid and cryptographically wrong, and **every message you
send fails DKIM**. If your provider does not split automatically, enter it as
multiple quoted strings on one record:

```
"v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOC..." "...remainder of the key"
```

Verify from a third machine:

```bash
dig +short TXT sg._domainkey.example.com
dig +short TXT us._domainkey.example.com
```

`hamail-health.sh` compares the published record against the local private key
on every run, precisely because this failure is invisible otherwise.

Optional but good practice — declare that these are the only selectors:

| Name | Type | Value |
|---|---|---|
| `_domainkey.${DOMAIN}` | TXT | `o=~; r=postmaster@${DOMAIN}` |

### 1.7 DMARC

| Name | Type | TTL | Value |
|---|---|---|---|
| `_dmarc.${DOMAIN}` | TXT | 3600 | see below |

**Stage 1 — observe (deploy with this):**

```
v=DMARC1; p=none; rua=mailto:dmarc@${DOMAIN}; ruf=mailto:dmarc@${DOMAIN}; fo=1; adkim=r; aspf=r; pct=100
```

**Stage 2 — after two weeks of clean reports from BOTH nodes:**

```
v=DMARC1; p=quarantine; pct=25; rua=mailto:dmarc@${DOMAIN}; adkim=r; aspf=r
```

**Stage 3 — steady state:**

```
v=DMARC1; p=reject; rua=mailto:dmarc@${DOMAIN}; adkim=r; aspf=s
```

> **Do not skip stage 1.** On a two-node cluster the specific thing you are
> watching for is aggregate reports showing mail signed by **both** selectors
> passing. If only one selector appears, one node's key is not published (or is
> truncated) and moving to `p=reject` will start bouncing half your mail.

`adkim=r` / `aspf=r` (relaxed) allow subdomain alignment. Use `s` (strict) only
once you are certain nothing sends from a subdomain.

### 1.8 MTA-STS and TLS reporting (recommended)

| Name | Type | TTL | Value |
|---|---|---|---|
| `_mta-sts.${DOMAIN}` | TXT | 3600 | `v=STSv1; id=20260101000000Z` |
| `mta-sts.${DOMAIN}` | A | 3600 | `${NODE_A_IP}` |
| `mta-sts.${DOMAIN}` | A | 3600 | `${NODE_B_IP}` |
| `_smtp._tls.${DOMAIN}` | TXT | 3600 | `v=TLSRPTv1; rua=mailto:tlsrpt@${DOMAIN}` |

Serve `https://mta-sts.${DOMAIN}/.well-known/mta-sts.txt`:

```
version: STSv1
mode: enforce
mx: sg1.example.com
mx: us1.example.com
max_age: 604800
```

**Both MX hostnames must be listed**, or senders honouring MTA-STS will refuse
to deliver to the omitted node. Bump the `id` every time the policy changes.

### 1.9 SRV — client autodiscovery

| Name | Type | TTL | Priority | Weight | Port | Target |
|---|---|---|---|---|---|---|
| `_imaps._tcp.${DOMAIN}` | SRV | 3600 | 0 | 1 | 993 | `mail.${DOMAIN}.` |
| `_submission._tcp.${DOMAIN}` | SRV | 3600 | 0 | 1 | 587 | `mail.${DOMAIN}.` |
| `_submissions._tcp.${DOMAIN}` | SRV | 3600 | 0 | 1 | 465 | `mail.${DOMAIN}.` |
| `_sieve._tcp.${DOMAIN}` | SRV | 3600 | 0 | 1 | 4190 | `mail.${DOMAIN}.` |
| `_autodiscover._tcp.${DOMAIN}` | SRV | 3600 | 0 | 1 | 443 | `autodiscover.${DOMAIN}.` |

Explicitly refuse POP3 (this cluster does not offer it):

| Name | Type | Priority | Weight | Port | Target |
|---|---|---|---|---|---|
| `_pop3._tcp.${DOMAIN}` | SRV | 0 | 0 | 0 | `.` |
| `_pop3s._tcp.${DOMAIN}` | SRV | 0 | 0 | 0 | `.` |

### 1.10 CAA — limit who may issue certificates

| Name | Type | Flags | Tag | Value |
|---|---|---|---|---|
| `${DOMAIN}` | CAA | 0 | `issue` | `letsencrypt.org` |
| `${DOMAIN}` | CAA | 0 | `iodef` | `mailto:security@${DOMAIN}` |

---

## 2. Reverse DNS (PTR) in the Linode Cloud Manager

PTR is set by the **address owner**, not in your zone. Missing or mismatched
reverse DNS causes deferrals and rejections at several large providers, and the
failure is completely invisible from your side.

### Prerequisite

The forward record must exist first. Linode validates that
`${NODE_A_HOSTNAME}` resolves to `${NODE_A_IP}` before it will accept the PTR.
Publish §1.1 and let it propagate (a few minutes) before continuing.

### Steps — Cloud Manager

Repeat for **each** node:

1. Sign in to <https://cloud.linode.com/>.
2. **Linodes** → select the instance (e.g. the Singapore one).
3. Open the **Network** tab.
4. In the **IP Addresses** table, find the public IPv4 row.
5. Click the **⋯** menu at the right of that row → **Edit RDNS**.
6. In **Enter a domain name**, type the node's FQDN exactly:
   - Singapore: `sg1.example.com`
   - United States: `us1.example.com`
7. **Save**.

If Linode rejects it with *"Please ensure the domain resolves to this IP"*, the
forward A record is missing, wrong, or not yet propagated. Fix §1.1 and retry.

### Steps — Linode CLI

```bash
# Find the IP object
linode-cli networking ips-list --json | jq -r '.[] | "\(.address)\t\(.rdns)"'

# Set it
linode-cli networking ip-update 203.0.113.10 --rdns sg1.example.com
linode-cli networking ip-update 198.51.100.20 --rdns us1.example.com
```

### Verify forward-confirmed reverse DNS

FCrDNS means the PTR resolves to a name whose A record points back to the same
address. Both halves must hold:

```bash
dig +short -x 203.0.113.10          # → sg1.example.com.
dig +short A sg1.example.com        # → 203.0.113.10

dig +short -x 198.51.100.20         # → us1.example.com.
dig +short A us1.example.com        # → 198.51.100.20
```

`hamail-health.sh` performs exactly this check on every run.

### IPv6

If you enable IPv6 (`NODE_A_IP6` / `NODE_B_IP6`), you must set RDNS for the
IPv6 address **and** add it to SPF (`ip6:…`) and to the AAAA records.
Gmail in particular requires valid reverse DNS for IPv6 senders and will reject
outright without it. If you are not going to do all three, leave IPv6 unset —
`main.cf` ships with `inet_protocols = ipv4` for exactly this reason.

---

## 3. Ready-to-edit zone file

```zone
$ORIGIN example.com.
$TTL 3600

; ---- node hostnames (one address each) ------------------------------------
sg1             IN A     203.0.113.10
us1             IN A     198.51.100.20

; ---- inbound mail: dual MX, equal priority --------------------------------
@               IN MX    10 sg1.example.com.
@               IN MX    10 us1.example.com.

; ---- client-facing service names: dual A, low TTL -------------------------
mail            300 IN A 203.0.113.10
mail            300 IN A 198.51.100.20
webmail         300 IN A 203.0.113.10
webmail         300 IN A 198.51.100.20
autoconfig      300 IN A 203.0.113.10
autoconfig      300 IN A 198.51.100.20
autodiscover    300 IN A 203.0.113.10
autodiscover    300 IN A 198.51.100.20
mta-sts         300 IN A 203.0.113.10
mta-sts         300 IN A 198.51.100.20

; ---- admin portal: SINGLE node (write leader) -----------------------------
admin           300 IN A 203.0.113.10

; ---- SPF: one record, both nodes ------------------------------------------
@               IN TXT   "v=spf1 ip4:203.0.113.10 ip4:198.51.100.20 -all"

; ---- DKIM: one selector per node ------------------------------------------
sg._domainkey   IN TXT   "v=DKIM1; k=rsa; p=REPLACE_WITH_NODE_A_PUBLIC_KEY"
us._domainkey   IN TXT   "v=DKIM1; k=rsa; p=REPLACE_WITH_NODE_B_PUBLIC_KEY"
_domainkey      IN TXT   "o=~; r=postmaster@example.com"

; ---- DMARC: start at p=none ------------------------------------------------
_dmarc          IN TXT   "v=DMARC1; p=none; rua=mailto:dmarc@example.com; ruf=mailto:dmarc@example.com; fo=1; adkim=r; aspf=r; pct=100"

; ---- MTA-STS and TLS reporting --------------------------------------------
_mta-sts        IN TXT   "v=STSv1; id=20260101000000Z"
_smtp._tls      IN TXT   "v=TLSRPTv1; rua=mailto:tlsrpt@example.com"

; ---- client autodiscovery --------------------------------------------------
_imaps._tcp        IN SRV 0 1 993  mail.example.com.
_submission._tcp   IN SRV 0 1 587  mail.example.com.
_submissions._tcp  IN SRV 0 1 465  mail.example.com.
_sieve._tcp        IN SRV 0 1 4190 mail.example.com.
_autodiscover._tcp IN SRV 0 1 443  autodiscover.example.com.
_pop3._tcp         IN SRV 0 0 0    .
_pop3s._tcp        IN SRV 0 0 0    .

; ---- certificate issuance authority ---------------------------------------
@               IN CAA   0 issue "letsencrypt.org"
@               IN CAA   0 iodef "mailto:security@example.com"
```

---

## 4. Verification

Run from a machine that is **not** one of the nodes:

```bash
D=example.com
A=203.0.113.10
B=198.51.100.20

echo "--- MX (expect both, priority 10) ---"
dig +short MX  $D

echo "--- service names (expect both IPs) ---"
dig +short A   mail.$D
dig +short A   webmail.$D

echo "--- admin (expect ONE IP) ---"
dig +short A   admin.$D

echo "--- SPF (expect exactly one v=spf1 line, both IPs) ---"
dig +short TXT $D | grep spf1

echo "--- DKIM (expect a p= value on each) ---"
dig +short TXT sg._domainkey.$D
dig +short TXT us._domainkey.$D

echo "--- DMARC ---"
dig +short TXT _dmarc.$D

echo "--- FCrDNS both directions ---"
dig +short -x $A ; dig +short A "$(dig +short -x $A | sed 's/\.$//')"
dig +short -x $B ; dig +short A "$(dig +short -x $B | sed 's/\.$//')"
```

Then send a message from a mailbox on **each** node to a checking service such
as `check-auth@verifier.port25.com` or mail-tester.com, and confirm the reply
shows `SPF: pass`, `DKIM: pass` and `DMARC: pass` **for both nodes**. Testing
only one node is the single most common way a cluster ships with half its mail
failing authentication.

To force a message out of a specific node:

```bash
swaks --server sg1.example.com:587 --auth --auth-user alice@example.com \
      --tls --to check-auth@verifier.port25.com --from alice@example.com

swaks --server us1.example.com:587 --auth --auth-user alice@example.com \
      --tls --to check-auth@verifier.port25.com --from alice@example.com
```

---

## 5. Adding another domain

Run `hamail-add-domain.sh newdomain.tld` on **both** nodes — it generates each
node's DKIM key, reloads rspamd, issues the certificate on the leader, and
prints the exact record set to publish. Then add the domain in the admin
portal. No configuration file changes, no restarts.
