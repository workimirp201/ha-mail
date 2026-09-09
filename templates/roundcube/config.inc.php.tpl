<?php
/*############################################################################
 * ha-mail :: ${ROUNDCUBE_ROOT}/config/config.inc.php
 * Node ${SELF_ROLE} - ${SELF_HOSTNAME}
 *
 * GENERATED FILE. Edit templates/roundcube/config.inc.php.tpl instead.
 * Mode 0640 root:www-data - it contains the database password and the DES key.
 *
 * DESIGN RULE FOR THIS FILE: Roundcube on Node ${SELF_ROLE} talks ONLY to
 * Node ${SELF_ROLE}'s Dovecot and Node ${SELF_ROLE}'s MariaDB replica. It has
 * no knowledge of ${PEER_HOSTNAME} at all. That is what makes webmail
 * genuinely active-active: a browser that DNS steers to either node gets a
 * complete, self-sufficient stack.
 *###########################################################################*/

$config = [];

/* ------------------------------------------------------------------------
 * DATABASE - local replica, UNIX socket.
 * ------------------------------------------------------------------------
 * unix() in the DSN selects the socket. Contacts, identities, saved searches
 * and responses live here and DO replicate, so a user's address book follows
 * them across a failover. Sessions and caches are excluded from replication
 * at the MariaDB layer (see 50-server.cnf replicate_ignore_table).
 * --------------------------------------------------------------------- */
$config['db_dsnw'] = 'mysql://${RC_DB_USER}:${RC_DB_PASS}@unix(/run/mysqld/mysqld.sock)/${RC_DB_NAME}';
$config['db_persistent'] = false;
$config['db_prefix'] = '';

/* ------------------------------------------------------------------------
 * IMAP - this node's own Dovecot.
 * ------------------------------------------------------------------------
 * Addressed by ${SELF_HOSTNAME} rather than 127.0.0.1 for one reason: the
 * node holds a real, publicly trusted certificate for that name, so the TLS
 * connection is FULLY VERIFIED. Pointing at 127.0.0.1 would force
 * verify_peer=false, and a config that disables certificate verification
 * "because it is only localhost" is exactly the config that stays disabled
 * after someone later points it somewhere else.
 * --------------------------------------------------------------------- */
$config['imap_host'] = 'ssl://${SELF_HOSTNAME}:993';
$config['imap_conn_options'] = [
    'ssl' => [
        'verify_peer'       => true,
        'verify_peer_name'  => true,
        'allow_self_signed' => false,
    ],
];
$config['imap_timeout'] = 30;
$config['imap_force_caps'] = false;

/* Ask Dovecot for its ID so the connection appears in Dovecot's logs tagged
 * as webmail on this node - useful when reconstructing a failover. */
$config['imap_id'] = ['name' => 'Roundcube', 'version' => 'ha-mail'];

/* ------------------------------------------------------------------------
 * SMTP - this node's own Postfix submission service.
 * --------------------------------------------------------------------- */
$config['smtp_host'] = 'ssl://${SELF_HOSTNAME}:465';
$config['smtp_user'] = '%u';
$config['smtp_pass'] = '%p';
$config['smtp_conn_options'] = [
    'ssl' => [
        'verify_peer'       => true,
        'verify_peer_name'  => true,
        'allow_self_signed' => false,
    ],
];
$config['smtp_timeout'] = 30;

/* ------------------------------------------------------------------------
 * IDENTITY
 * --------------------------------------------------------------------- */
$config['product_name'] = '${DOMAIN} Webmail';
$config['support_url'] = 'https://${WEBMAIL_HOST}/';
$config['useragent'] = 'Webmail';

/* Node marker. Visible in the page title, so during a failover drill a user
 * (or you) can see which server is actually serving the session. */
$config['skin_logo'] = null;
$config['login_username_filter'] = 'email';

/* ------------------------------------------------------------------------
 * DES KEY
 * ------------------------------------------------------------------------
 * Encrypts the user's IMAP password inside the session. It MUST be identical
 * on both nodes: a session cookie presented to the other node after a
 * failover is decrypted with this key, and a mismatch produces a silent
 * logout loop that looks exactly like a broken IMAP server.
 * Exactly 24 characters - validated by lib/common.sh at deploy time.
 * --------------------------------------------------------------------- */
$config['des_key'] = '${ROUNDCUBE_DES_KEY}';

/* ------------------------------------------------------------------------
 * SESSIONS
 * ------------------------------------------------------------------------
 * Node-local PHP files (path and cookie flags are set in the FPM pool).
 *
 * Storing sessions in the replicated database is tempting - it would survive
 * a failover - but it makes every page view a replicated write, races when
 * consecutive requests land on different nodes, and puts a second copy of the
 * encrypted IMAP password into the replication stream. One re-login after a
 * failover is the better trade. See templates/php/pool-roundcube.conf.tpl.
 * --------------------------------------------------------------------- */
$config['session_storage'] = 'php';
$config['session_lifetime'] = 60;
$config['session_samesite'] = 'Strict';
$config['ip_check'] = false;   /* mobile clients change IP constantly */
$config['referer_check'] = true;
$config['x_frame_options'] = 'sameorigin';

/* ------------------------------------------------------------------------
 * LOGIN SECURITY
 * --------------------------------------------------------------------- */
$config['login_rate_limit'] = 3;          /* per minute, per user */
$config['login_password_maxlen'] = 1024;
$config['password_charset'] = 'UTF-8';
$config['log_logins'] = true;             /* fail2ban reads these lines */
$config['log_driver'] = 'file';
$config['log_dir'] = '${ROUNDCUBE_ROOT}/logs/';
$config['temp_dir'] = '${ROUNDCUBE_ROOT}/temp/';
$config['log_date_format'] = 'd-M-Y H:i:s O';

/* Never let the installer run again on a live node. */
$config['enable_installer'] = false;

/* ------------------------------------------------------------------------
 * PLUGINS
 * --------------------------------------------------------------------- */
$config['plugins'] = [
    'archive',
    'zipdownload',
    'managesieve',
    'password',
    'newmail_notifier',
    'filesystem_attachments',
    'attachment_reminder',
    'emoticons',
];

/* --- managesieve: server-side filters ---------------------------------
 * The scripts live in the user's home directory, so dsync replicates them
 * with the mail. A filter created here is active on ${PEER_HOSTNAME} within
 * seconds, with no separate sync mechanism. */
$config['managesieve_host'] = 'tls://${SELF_HOSTNAME}:4190';
$config['managesieve_conn_options'] = [
    'ssl' => [
        'verify_peer'      => true,
        'verify_peer_name' => true,
    ],
];
$config['managesieve_usetls'] = true;
$config['managesieve_default'] = '/var/lib/dovecot/sieve/default.sieve';
$config['managesieve_kolab_master'] = false;
$config['managesieve_vacation'] = 1;

/* --- password: self-service password change ---------------------------
 * Writes straight into the replicated `mailbox` table, so a password changed
 * on Node ${SELF_ROLE} works on ${PEER_HOSTNAME} as soon as replication
 * catches up (sub-second on this link).
 *
 * The hash is produced by `doveadm pw`, the SAME binary PostfixAdmin uses.
 * Two different hashing paths writing the same column is how you end up with
 * accounts that can log in to webmail but not to IMAP. */
$config['password_driver'] = 'sql';
$config['password_algorithm'] = 'dovecot';
$config['password_dovecotpw'] = '/usr/bin/doveadm pw';
$config['password_dovecotpw_method'] = 'ARGON2ID';
$config['password_dovecotpw_with_method'] = true;
$config['password_db_dsn'] = 'mysql://${RC_DB_USER}:${RC_DB_PASS}@unix(/run/mysqld/mysqld.sock)/${DB_NAME}';
$config['password_query'] = "UPDATE mailbox SET password=%D, modified=NOW() WHERE username=%u LIMIT 1";
$config['password_confirm_current'] = true;
$config['password_minimum_length'] = 12;
$config['password_require_nonalpha'] = true;
$config['password_force_save'] = true;

/* --- newmail_notifier ------------------------------------------------- */
$config['newmail_notifier_basic'] = true;
$config['newmail_notifier_desktop'] = true;
$config['newmail_notifier_desktop_timeout'] = 10;

/* ------------------------------------------------------------------------
 * BEHAVIOUR
 * --------------------------------------------------------------------- */
$config['skin'] = 'elastic';
$config['language'] = 'en_US';
$config['timezone'] = '${TIMEZONE}';
$config['prefer_html'] = true;
$config['message_show_email'] = true;
$config['default_charset'] = 'UTF-8';
$config['mail_pagesize'] = 50;
$config['addressbook_pagesize'] = 50;
$config['spellcheck_engine'] = 'pspell';
$config['identities_level'] = 1;   /* users may edit, but not add, identities */

/* Special folders. These names match the special_use flags declared in
 * Dovecot's 15-mailboxes.conf. They MUST agree, or Roundcube creates its own
 * "Sent" alongside Dovecot's and dsync dutifully replicates both. */
$config['drafts_mbox'] = 'Drafts';
$config['junk_mbox'] = 'Junk';
$config['sent_mbox'] = 'Sent';
$config['trash_mbox'] = 'Trash';
$config['archive_mbox'] = 'Archive';
$config['default_folders'] = ['INBOX', 'Drafts', 'Sent', 'Junk', 'Trash', 'Archive'];
$config['create_default_folders'] = true;
$config['protect_default_folders'] = true;

/* Message cache OFF.
 * Roundcube's SQL message cache is excluded from replication, so each node
 * would build its own. That is correct but wasteful, and a stale cache after
 * a dsync-driven change is a support ticket ("a message I deleted came
 * back"). Dovecot's own indexes already make IMAP fast enough. */
$config['messages_cache'] = false;
$config['imap_cache'] = null;
$config['imap_cache_ttl'] = '10d';

/* Attachment size must line up with the FPM pool and nginx
 * (client_max_body_size) or the failure is silent and confusing. */
$config['max_message_size'] = '64M';
$config['max_group_members'] = 0;

/* Trust the reverse proxy header only from localhost; nginx sets it. */
$config['proxy_whitelist'] = ['127.0.0.1', '::1'];
