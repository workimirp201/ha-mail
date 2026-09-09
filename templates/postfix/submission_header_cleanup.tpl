# ha-mail :: /etc/postfix/submission_header_cleanup
#
# Applied ONLY to mail submitted by authenticated users on 587/465, through
# the dedicated "submission-cleanup" service in master.cf.
#
# WHY THIS EXISTS
# Postfix stamps a Received: header naming the submitting client. For a user on
# hotel wifi that header contains their private RFC1918 address, the hotel's
# public IP and often their machine's hostname. That is:
#   - a privacy leak to every recipient
#   - a deliverability liability (many filters score private IPs in the chain)
# Stripping it means the only hop a recipient sees is ${SELF_IP} - the address
# the SPF record authorises and the address with correct reverse DNS.
#
# IMPORTANT: this file is NOT applied to port 25. Inbound mail keeps its
# complete Received: chain, which you need for abuse investigation and which
# the recipient's own SPF/DMARC evaluation depends on.
#
# Format: regexp:(5) - PCRE-style, one rule per line, ACTION after whitespace.

# The Received: header stamped for an authenticated submission. ESMTPSA is
# "ESMTP + STARTTLS + AUTH", ESMTPA is "ESMTP + AUTH" (no TLS - shouldn't
# happen here since 587 is smtpd_tls_security_level=encrypt, but match it in
# case a future config change relaxes that).
/^Received:.*with E?SMTPS?A[; ]/                     IGNORE

# Client-supplied headers that expose the submitter's network or software.
/^X-Originating-IP:/                                 IGNORE
/^X-Enigmail-Version:/                               IGNORE
/^X-Mailer:/                                         IGNORE
/^User-Agent:/                                       IGNORE

# Normalise the Message-ID's right-hand side to the sending domain. A
# Message-ID that ends in "@alices-macbook.local" is both an information leak
# and a well-known spam signal.
/^Message-ID:\s*<(.+)@[^>]+>/     REPLACE Message-ID: <$1@${DOMAIN}>
