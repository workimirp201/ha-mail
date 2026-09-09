<?php
/*############################################################################
 * ha-mail :: ${POSTFIXADMIN_ROOT}/config.local.php
 * Node ${SELF_ROLE} - ${SELF_HOSTNAME}
 *
 * GENERATED FILE. Edit templates/postfixadmin/config.local.php.tpl instead.
 *
 * config.local.php overrides config.inc.php and is never touched by a
 * PostfixAdmin upgrade, so upgrading the application never clobbers the
 * cluster's settings.
 *
 * Mode 0640 root:www-data - it contains the database password.
 *###########################################################################*/

/* ------------------------------------------------------------------------
 * Installation state
 * --------------------------------------------------------------------- */
$CONF['configured'] = true;

/* Hash of SETUP_PASS, produced by setup.php and injected by
 * scripts/85-postfixadmin.sh. Both nodes carry the SAME hash so that either
 * one can run setup after a rebuild. setup.php itself is firewalled off in
 * the nginx vhost once installation completes. */
$CONF['setup_password'] = '${SETUP_PASS_HASH}';

/* ------------------------------------------------------------------------
 * DATABASE
 * ------------------------------------------------------------------------
 * Connects to the LOCAL replica over the UNIX socket.
 *
 * This is the single most important line in the file for the HA design: the
 * admin portal on Node ${SELF_ROLE} writes to Node ${SELF_ROLE}'s database
 * and lets replication carry the change to ${PEER_HOSTNAME}. It NEVER writes
 * across the tunnel.
 *
 * Consequences, stated plainly:
 *   + A portal write completes in single-digit milliseconds instead of
 *     waiting ~180ms for a cross-ocean commit.
 *   + The portal keeps working when the tunnel is down.
 *   - The change is visible on the peer after replication lag (normally well
 *     under a second on this link), not instantly. The verification playbook
 *     in docs/TESTING.md measures exactly this.
 * --------------------------------------------------------------------- */
$CONF['database_type'] = 'mysqli';
$CONF['database_host'] = 'localhost';
$CONF['database_socket'] = '/run/mysqld/mysqld.sock';
$CONF['database_user'] = '${DB_USER}';
$CONF['database_password'] = '${DB_PASS}';
$CONF['database_name'] = '${DB_NAME}';
$CONF['database_prefix'] = '';

/* Table names left at their defaults so upgrade.php can find them. */

/* ------------------------------------------------------------------------
 * Identity
 * --------------------------------------------------------------------- */
$CONF['admin_email'] = '${ADMIN_EMAIL}';
$CONF['admin_name'] = '${DOMAIN} Mail Administration';
$CONF['default_language'] = 'en';
$CONF['language_hook'] = '';

/* Shown in the page title so an operator can tell at a glance WHICH node
 * they are administering. During a failover this is the difference between a
 * confident change and a guess. */
$CONF['page_title'] = 'Mail Admin - ${DOMAIN} [node ${SELF_ROLE}: ${SELF_SHORTNAME}]';

/* ------------------------------------------------------------------------
 * PASSWORD HASHING
 * ------------------------------------------------------------------------
 * Delegated to `doveadm pw` so that PostfixAdmin and Dovecot can never
 * disagree about the hash format. The alternative (PHP-side hashing) has
 * historically drifted from Dovecot's expectations and produces accounts that
 * are created successfully but cannot log in.
 *
 * ARGON2ID is memory-hard. That is deliberate even though it costs CPU on
 * every login: these are internet-facing mailbox passwords.
 * --------------------------------------------------------------------- */
$CONF['encrypt'] = 'dovecot:ARGON2ID';
$CONF['dovecotpw'] = '/usr/bin/doveadm pw';
$CONF['authlib_default_flavor'] = 'md5crypt';

$CONF['min_password_length'] = 12;
$CONF['password_validation'] = array(
    '/.{12,}/'                  => 'password_too_short 12',
    '/[a-z]/'                   => 'password_no_lowercase',
    '/[A-Z]/'                   => 'password_no_uppercase',
    '/[0-9]/'                   => 'password_no_digit',
);
$CONF['generate_password'] = 'YES';
$CONF['show_password'] = 'NO';

/* Expiry is off by default. If you enable it, note that the mailbox query in
 * dovecot-sql.conf.ext already honours password_expiry, so an expired
 * password stops IMAP and SMTP auth on BOTH nodes at the same instant. */
$CONF['password_expiration'] = 'NO';

/* ------------------------------------------------------------------------
 * SELF-SERVICE PASSWORD RESET
 * ------------------------------------------------------------------------
 * The reset token is written to mailbox.token/token_validity, which
 * replicates. So a token issued by Node A is redeemable on Node B - which
 * matters, because the user clicking the link in their mail may well be
 * steered to the other node by DNS.
 *
 * Token lifetime is deliberately short: it is a bearer credential sitting in
 * an inbox.
 * --------------------------------------------------------------------- */
$CONF['forgotten_user_password_reset'] = true;
$CONF['forgotten_admin_password_reset'] = true;
$CONF['password_reset_token_validity'] = 3600;
$CONF['recovery_email_address_can_be_local'] = false;

/* ------------------------------------------------------------------------
 * MAILBOX PATHS
 * ------------------------------------------------------------------------
 * These control what PostfixAdmin writes into mailbox.maildir.
 *
 * NOTE: in this deployment that column is effectively COSMETIC. Dovecot's
 * userdb query builds the real path from %d/%n itself
 * (see dovecot-sql.conf.ext), and Postfix hands delivery to Dovecot over
 * LMTP without ever reading the column. Deriving the path rather than trusting
 * a stored string means a row edited by hand cannot point a mailbox at
 * another user's directory.
 * --------------------------------------------------------------------- */
$CONF['domain_path'] = 'YES';
$CONF['domain_in_mailbox'] = 'NO';
$CONF['maildir_name_hook'] = false;

/* Dovecot creates the Maildir on first delivery/login, with the right owner
 * and the right index paths. PostfixAdmin must NOT create directories - as
 * www-data it would create them with the wrong ownership and Dovecot would
 * then refuse them. */
$CONF['create_mailbox_subdirs'] = array();
$CONF['create_mailbox_subdirs_host'] = '';

/* ------------------------------------------------------------------------
 * QUOTAS
 * ------------------------------------------------------------------------
 * The UI works in MiB; quota_multiplier converts to the bytes stored in the
 * mailbox.quota column and handed to Dovecot as userdb_quota_rule.
 *
 * The USAGE figure displayed comes from quota2, which is node-local and NOT
 * replicated (see 50-server.cnf). So the portal shows this node's view. Both
 * nodes hold the same mail, so both views agree; a brief divergence during a
 * replication catch-up is expected and harmless.
 * --------------------------------------------------------------------- */
$CONF['quota'] = 'YES';
$CONF['domain_quota'] = 'YES';
$CONF['quota_multiplier'] = '1048576';
$CONF['used_quotas'] = 'YES';
$CONF['new_quota_table'] = 'YES';

/* ------------------------------------------------------------------------
 * DEFAULTS FOR NEW DOMAINS
 * --------------------------------------------------------------------- */
$CONF['aliases'] = '${DEFAULT_DOMAIN_ALIASES}';
$CONF['mailboxes'] = '${DEFAULT_DOMAIN_MAILBOXES}';
$CONF['maxquota'] = '${MAX_QUOTA_MB}';
$CONF['transport'] = 'NO';
$CONF['transport_options'] = array('virtual');
$CONF['transport_default'] = 'virtual';

/* Standard RFC 2142 role addresses, created as aliases to the domain's
 * postmaster when a domain is added. abuse@ and postmaster@ are not optional
 * if you want your mail to be accepted by anyone. */
$CONF['default_aliases'] = array(
    'abuse'      => 'abuse@${DOMAIN}',
    'hostmaster' => 'hostmaster@${DOMAIN}',
    'postmaster' => 'postmaster@${DOMAIN}',
    'webmaster'  => 'webmaster@${DOMAIN}',
);

/* ------------------------------------------------------------------------
 * ALIASES / CATCH-ALL
 * --------------------------------------------------------------------- */
$CONF['alias_control'] = 'NO';
$CONF['alias_control_admin'] = 'YES';
$CONF['special_alias_control'] = 'NO';
$CONF['alias_domain'] = 'YES';

/* A catch-all is created in the UI as an alias with the address "@domain".
 * Postfix finds it automatically on its second lookup - see
 * templates/postfix/sql/mysql-virtual-alias-maps.cf.tpl.
 *
 * OPERATIONAL WARNING: a catch-all accepts mail for every conceivable local
 * part, which makes the domain a magnet for dictionary spam and defeats
 * recipient verification at the edge. Offer it, but not by default. */
$CONF['recipient_delimiter'] = '+';

/* ------------------------------------------------------------------------
 * VACATION / AUTORESPONDER
 * ------------------------------------------------------------------------
 * Implemented through Dovecot's Sieve vacation extension, not through a
 * separate vacation delivery agent. The suppression state lives in
 * vacation_notification, whose composite natural key converges cleanly if
 * both nodes happen to record the same notification.
 * --------------------------------------------------------------------- */
$CONF['vacation'] = 'YES';
$CONF['vacation_domain'] = 'autoreply.${DOMAIN}';
$CONF['vacation_control'] = 'YES';
$CONF['vacation_control_admin'] = 'YES';

/* ------------------------------------------------------------------------
 * FEATURES DELIBERATELY OFF
 * --------------------------------------------------------------------- */
/* fetchmail runs a polling daemon; on an active-active pair BOTH nodes would
 * poll the same remote account and each would deliver its own copy, so the
 * user gets every message twice. Enable it only after arranging for exactly
 * one node to run the poller. */
$CONF['fetchmail'] = 'NO';

/* The XML-RPC interface is an unauthenticated-by-default write surface. */
$CONF['xmlrpc_enabled'] = false;

/* ------------------------------------------------------------------------
 * AUDIT AND MAIL
 * --------------------------------------------------------------------- */
$CONF['logging'] = 'YES';
$CONF['sendmail'] = 'YES';
$CONF['emailcheck_resolve_domain'] = 'YES';
$CONF['show_status'] = 'YES';
$CONF['show_status_key'] = 'NO';
$CONF['show_undeliverable'] = 'YES';
$CONF['show_undeliverable_exceptions'] = array('${SELF_HOSTNAME}', '${PEER_HOSTNAME}');
$CONF['page_size'] = '50';

/* Welcome message sent to every newly created mailbox. It arrives via
 * Dovecot on whichever node created the account and then replicates, so the
 * user sees exactly one copy. */
$CONF['welcome_text'] = <<<EOM
Welcome to your new mailbox on ${DOMAIN}.

  Webmail   https://${WEBMAIL_HOST}/
  IMAP      ${MAIL_HOST}  port 993 (SSL/TLS)
  SMTP      ${MAIL_HOST}  port 465 (SSL/TLS) or 587 (STARTTLS)
  Username  your full email address

Your mail is stored on two servers in different regions and is kept in sync
automatically, so service continues if one of them is unavailable.

-- ${DOMAIN} mail administration
EOM;

/* ------------------------------------------------------------------------
 * SESSION AND TRANSPORT SECURITY
 * ------------------------------------------------------------------------
 * The cookie flags themselves are set in the PHP-FPM pool
 * (/etc/php/8.3/fpm/pool.d/postfixadmin.conf) so that they apply to every
 * script in the pool, including any that forgets to call session_start()
 * through the framework.
 * --------------------------------------------------------------------- */
$CONF['sessions'] = 'php';

/* Refuse to run over plain HTTP. Combined with the HSTS header from
 * hamail-tls.conf, this closes the downgrade path. */
if (!isset($_SERVER['HTTPS']) || $_SERVER['HTTPS'] !== 'on') {
    if (php_sapi_name() !== 'cli') {
        header('HTTP/1.1 403 Forbidden');
        exit('This interface requires HTTPS.');
    }
}
