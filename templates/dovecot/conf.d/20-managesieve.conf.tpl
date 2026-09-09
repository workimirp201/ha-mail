##############################################################################
# ha-mail :: /etc/dovecot/conf.d/20-managesieve.conf
# ManageSieve (RFC 5804) so Roundcube's filter UI can edit server-side rules.
##############################################################################

service managesieve-login {
  inet_listener sieve {
    port = 4190
  }
  service_count = 1
  process_min_avail = 1
  vsz_limit = 64M
}

service managesieve {
  process_limit = 256
}

protocol sieve {
  managesieve_max_line_length = 65536
  managesieve_implementation_string = Dovecot Pigeonhole
  # Cap what a user can upload. An unbounded script is both a DoS vector and,
  # because scripts live in the user's home and are replicated by dsync, a way
  # to push arbitrary bulk across the tunnel.
  managesieve_max_compile_errors = 5
  managesieve_notify_capability = mailto
  managesieve_sieve_capability = fileinto reject envelope encoded-character vacation subaddress comparator-i;ascii-numeric relational regex imap4flags copy include variables body enotify environment mailbox date index ihave duplicate mime foreverypart extracttext
}
