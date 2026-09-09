-- ###########################################################################
-- ha-mail :: virtual mail schema (PostfixAdmin 3.3.x compatible)
--
-- APPLY THIS ON NODE A ONLY. It is DDL; it travels to Node B through the
-- replication stream. Running it independently on both nodes creates two
-- unrelated table histories and is the fastest way to break a fresh cluster.
--
-- Everything is CREATE TABLE IF NOT EXISTS so the file is idempotent, and
-- scripts/45-db-schema.sh runs PostfixAdmin's own upgrade.php immediately
-- afterwards to reconcile any drift against the exact upstream definition and
-- to stamp the correct `config.version` row.
--
-- Engine/charset notes
--   * InnoDB everywhere: MyISAM has no transactions and no crash safety, and
--     a non-transactional table in a ROW-binlog replica is a divergence bomb.
--   * utf8mb4 so display names and non-Latin domains survive intact.
-- ###########################################################################

SET NAMES utf8mb4;
SET SESSION sql_mode = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION';

CREATE DATABASE IF NOT EXISTS `${DB_NAME}`
    CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- binlog_do_db filters on the session's default database. This USE is what
-- makes every statement below replicate.
USE `${DB_NAME}`;

-- ---------------------------------------------------------------------------
-- admin : people who can log in to the admin portal.
-- Natural primary key (the login address), so no auto_increment and therefore
-- no cross-node key contention on this table at all.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `admin` (
    `username`       VARCHAR(255)  NOT NULL DEFAULT '',
    `password`       VARCHAR(255)  NOT NULL DEFAULT '',
    `superadmin`     TINYINT(1)    NOT NULL DEFAULT 0,
    `phone`          VARCHAR(30)   NOT NULL DEFAULT '',
    `email_other`    VARCHAR(255)  NOT NULL DEFAULT '',
    `token`          VARCHAR(255)  NOT NULL DEFAULT '',
    `token_validity` DATETIME      NOT NULL DEFAULT '2000-01-01 00:00:00',
    `created`        DATETIME      NOT NULL DEFAULT '2000-01-01 00:00:00',
    `modified`       DATETIME      NOT NULL DEFAULT '2000-01-01 00:00:00',
    `active`         TINYINT(1)    NOT NULL DEFAULT 1,
    PRIMARY KEY (`username`),
    KEY `idx_admin_active` (`active`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Virtual admins';

-- ---------------------------------------------------------------------------
-- domain : every domain this cluster is authoritative for.
-- The magic row domain='ALL' is how PostfixAdmin marks a superadmin in
-- domain_admins; Postfix's virtual_mailbox_domains query excludes it.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `domain` (
    `domain`      VARCHAR(255)  NOT NULL DEFAULT '',
    `description` VARCHAR(255)  NOT NULL DEFAULT '',
    `aliases`     INT(10)       NOT NULL DEFAULT 0,
    `mailboxes`   INT(10)       NOT NULL DEFAULT 0,
    `maxquota`    BIGINT(20)    NOT NULL DEFAULT 0,
    `quota`       BIGINT(20)    NOT NULL DEFAULT 0,
    `transport`   VARCHAR(255)  NOT NULL DEFAULT 'virtual',
    `backupmx`    TINYINT(1)    NOT NULL DEFAULT 0,
    `created`     DATETIME      NOT NULL DEFAULT '2000-01-01 00:00:00',
    `modified`    DATETIME      NOT NULL DEFAULT '2000-01-01 00:00:00',
    `active`      TINYINT(1)    NOT NULL DEFAULT 1,
    PRIMARY KEY (`domain`),
    KEY `idx_domain_active` (`active`),
    KEY `idx_domain_backupmx` (`backupmx`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Virtual domains';

-- ---------------------------------------------------------------------------
-- domain_admins : which admin may manage which domain.
-- No surrogate key; the (username, domain) pair is the identity. A duplicate
-- grant issued simultaneously on both nodes is idempotent rather than a
-- primary-key collision, which is exactly what we want in a multi-master ring.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `domain_admins` (
    `username` VARCHAR(255) NOT NULL DEFAULT '',
    `domain`   VARCHAR(255) NOT NULL DEFAULT '',
    `created`  DATETIME     NOT NULL DEFAULT '2000-01-01 00:00:00',
    `active`   TINYINT(1)   NOT NULL DEFAULT 1,
    PRIMARY KEY (`username`, `domain`),
    KEY `idx_domain_admins_username` (`username`),
    KEY `idx_domain_admins_domain` (`domain`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Domain admin mapping';

-- ---------------------------------------------------------------------------
-- alias : forwards, distribution lists and catch-alls.
-- A catch-all is simply address = '@domain.tld'.
-- `goto` is a comma-separated list of destinations, matching Postfix's
-- virtual_alias_maps expectations.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `alias` (
    `address`  VARCHAR(255) NOT NULL DEFAULT '',
    `goto`     TEXT         NOT NULL,
    `domain`   VARCHAR(255) NOT NULL DEFAULT '',
    `created`  DATETIME     NOT NULL DEFAULT '2000-01-01 00:00:00',
    `modified` DATETIME     NOT NULL DEFAULT '2000-01-01 00:00:00',
    `active`   TINYINT(1)   NOT NULL DEFAULT 1,
    PRIMARY KEY (`address`),
    KEY `idx_alias_domain` (`domain`),
    KEY `idx_alias_active` (`active`),
    KEY `idx_alias_domain_active` (`domain`, `active`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Virtual aliases';

-- ---------------------------------------------------------------------------
-- alias_domain : domain-level aliasing (everything@a.tld -> everything@b.tld)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `alias_domain` (
    `alias_domain`  VARCHAR(255) NOT NULL DEFAULT '',
    `target_domain` VARCHAR(255) NOT NULL DEFAULT '',
    `created`       DATETIME     NOT NULL DEFAULT '2000-01-01 00:00:00',
    `modified`      DATETIME     NOT NULL DEFAULT '2000-01-01 00:00:00',
    `active`        TINYINT(1)   NOT NULL DEFAULT 1,
    PRIMARY KEY (`alias_domain`),
    KEY `idx_alias_domain_target` (`target_domain`),
    KEY `idx_alias_domain_active` (`active`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Domain aliases';

-- ---------------------------------------------------------------------------
-- mailbox : the actual accounts.
-- `maildir` is stored relative to VMAIL_ROOT and always ends in a slash, which
-- is what makes Dovecot treat it as Maildir++ rather than mbox.
-- `quota` is in BYTES (PostfixAdmin multiplies the MB shown in the UI).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `mailbox` (
    `username`        VARCHAR(255) NOT NULL DEFAULT '',
    `password`        VARCHAR(255) NOT NULL DEFAULT '',
    `name`            VARCHAR(255) NOT NULL DEFAULT '',
    `maildir`         VARCHAR(255) NOT NULL DEFAULT '',
    `quota`           BIGINT(20)   NOT NULL DEFAULT 0,
    `local_part`      VARCHAR(255) NOT NULL DEFAULT '',
    `domain`          VARCHAR(255) NOT NULL DEFAULT '',
    `created`         DATETIME     NOT NULL DEFAULT '2000-01-01 00:00:00',
    `modified`        DATETIME     NOT NULL DEFAULT '2000-01-01 00:00:00',
    `active`          TINYINT(1)   NOT NULL DEFAULT 1,
    `phone`           VARCHAR(30)  NOT NULL DEFAULT '',
    `email_other`     VARCHAR(255) NOT NULL DEFAULT '',
    `token`           VARCHAR(255) NOT NULL DEFAULT '',
    `token_validity`  DATETIME     NOT NULL DEFAULT '2000-01-01 00:00:00',
    `password_expiry` DATETIME     NOT NULL DEFAULT '2000-01-01 00:00:00',
    PRIMARY KEY (`username`),
    KEY `idx_mailbox_domain` (`domain`),
    KEY `idx_mailbox_active` (`active`),
    KEY `idx_mailbox_domain_active` (`domain`, `active`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Virtual mailboxes';

-- ---------------------------------------------------------------------------
-- log : the admin portal's audit trail.
--
-- MULTI-MASTER FIX (not upstream): PostfixAdmin ships this table with NO
-- primary key. Under ROW-based replication a table without a PK forces the
-- replica to full-scan the table for every single row event, which turns an
-- append-only audit log into an O(n) cost per write and eventually stalls the
-- SQL thread. We add a surrogate BIGINT AUTO_INCREMENT key; it inherits the
-- auto_increment_offset so Node A writes odd ids and Node B even ones.
-- PostfixAdmin only ever INSERTs and SELECTs here, so the extra column is
-- transparent to the application.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `log` (
    `id`        BIGINT(20)   NOT NULL AUTO_INCREMENT,
    `timestamp` DATETIME     NOT NULL DEFAULT '2000-01-01 00:00:00',
    `username`  VARCHAR(255) NOT NULL DEFAULT '',
    `domain`    VARCHAR(255) NOT NULL DEFAULT '',
    `action`    VARCHAR(255) NOT NULL DEFAULT '',
    `data`      TEXT         NOT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_log_timestamp` (`timestamp`),
    KEY `idx_log_domain` (`domain`),
    KEY `idx_log_username` (`username`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Admin audit log (PK added for ROW replication efficiency)';

-- ---------------------------------------------------------------------------
-- vacation / vacation_notification : autoresponder state.
-- vacation_notification is written by the Sieve vacation extension on whichever
-- node delivered the message. Its composite natural key means the same
-- notification recorded on both nodes converges instead of colliding.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `vacation` (
    `email`         VARCHAR(255) NOT NULL,
    `subject`       VARCHAR(255) NOT NULL DEFAULT '',
    `body`          TEXT         NOT NULL,
    `cache`         TEXT         NOT NULL,
    `domain`        VARCHAR(255) NOT NULL DEFAULT '',
    `created`       DATETIME     NOT NULL DEFAULT '2000-01-01 00:00:00',
    `activefrom`    DATETIME     NOT NULL DEFAULT '2000-01-01 00:00:00',
    `activeuntil`   DATETIME     NOT NULL DEFAULT '2100-01-01 00:00:00',
    `active`        TINYINT(1)   NOT NULL DEFAULT 1,
    `interval_time` INT(11)      NOT NULL DEFAULT 0,
    PRIMARY KEY (`email`),
    KEY `idx_vacation_domain` (`domain`),
    KEY `idx_vacation_active` (`active`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Vacation/autoresponder';

CREATE TABLE IF NOT EXISTS `vacation_notification` (
    `on_vacation` VARCHAR(255) NOT NULL,
    `notified`    VARCHAR(255) NOT NULL,
    `notified_at` TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`on_vacation`, `notified`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Vacation notification suppression';

-- ---------------------------------------------------------------------------
-- quota / quota2 : Dovecot quota dictionary backends.
--
-- BOTH TABLES ARE EXCLUDED FROM REPLICATION (see replicate_ignore_table in
-- 50-server.cnf). Each node maintains its own counters for the same mail,
-- which is correct because dsync keeps the mail itself identical. Replicating
-- them would make every single delivery a cross-node write conflict on a
-- 180ms link.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `quota` (
    `username`     VARCHAR(255) NOT NULL,
    `path`         VARCHAR(100) NOT NULL,
    `current`      BIGINT(20)   NOT NULL DEFAULT 0,
    PRIMARY KEY (`username`, `path`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Dovecot quota (legacy dict, node-local)';

CREATE TABLE IF NOT EXISTS `quota2` (
    `username` VARCHAR(255) NOT NULL,
    `bytes`    BIGINT(20)   NOT NULL DEFAULT 0,
    `messages` INT(11)      NOT NULL DEFAULT 0,
    PRIMARY KEY (`username`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Dovecot quota dict (node-local, not replicated)';

-- ---------------------------------------------------------------------------
-- fetchmail : optional remote-account polling driven from the portal.
-- Has a real AUTO_INCREMENT id, so it is a direct beneficiary of the
-- increment/offset scheme.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `fetchmail` (
    `id`              INT(11)      NOT NULL AUTO_INCREMENT,
    `mailbox`         VARCHAR(255) NOT NULL DEFAULT '',
    `src_server`      VARCHAR(255) NOT NULL DEFAULT '',
    `src_auth`        ENUM('password','kerberos_v5','kerberos','kerberos_v4',
                           'gssapi','cram-md5','otp','ntlm','msn','ssh','any')
                                   DEFAULT NULL,
    `src_user`        VARCHAR(255) NOT NULL DEFAULT '',
    `src_password`    VARCHAR(255) NOT NULL DEFAULT '',
    `src_folder`      VARCHAR(255) NOT NULL DEFAULT '',
    `poll_time`       INT(11)      NOT NULL DEFAULT 10,
    `fetchall`        TINYINT(1)   NOT NULL DEFAULT 0,
    `keep`            TINYINT(1)   NOT NULL DEFAULT 0,
    `protocol`        ENUM('POP3','IMAP','POP2','ETRN','AUTO') DEFAULT NULL,
    `usessl`          TINYINT(1)   NOT NULL DEFAULT 0,
    `extra_options`   TEXT         DEFAULT NULL,
    `returned_text`   TEXT         DEFAULT NULL,
    `mda`             VARCHAR(255) NOT NULL DEFAULT '',
    `date`            TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
                                   ON UPDATE CURRENT_TIMESTAMP,
    `sslcertck`       TINYINT(1)   NOT NULL DEFAULT 0,
    `sslcertpath`     VARCHAR(255) DEFAULT '',
    `sslfingerprint`  VARCHAR(255) DEFAULT '',
    `domain`          VARCHAR(255) DEFAULT '',
    `active`          TINYINT(1)   NOT NULL DEFAULT 0,
    PRIMARY KEY (`id`),
    KEY `idx_fetchmail_mailbox` (`mailbox`),
    KEY `idx_fetchmail_domain` (`domain`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Remote account fetching';

-- ---------------------------------------------------------------------------
-- tls_policy : per-destination outbound TLS policy for Postfix
-- (smtp_tls_policy_maps). Not part of upstream PostfixAdmin; it lives here so
-- that "force TLS to this partner domain" replicates like everything else
-- instead of being a file you forget to copy to the second node.
--
--   policy : none | may | encrypt | dane | dane-only | fingerprint | verify | secure
--   params : optional, e.g. "protocols=!SSLv2:!SSLv3" or "match=mail.partner.tld"
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `tls_policy` (
    `domain` VARCHAR(255) NOT NULL,
    `policy` VARCHAR(32)  NOT NULL DEFAULT 'may',
    `params` VARCHAR(255) NOT NULL DEFAULT '',
    `active` TINYINT(1)   NOT NULL DEFAULT 1,
    PRIMARY KEY (`domain`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Per-destination outbound TLS policy';

-- ---------------------------------------------------------------------------
-- config : PostfixAdmin's schema-version marker.
-- scripts/45-db-schema.sh deliberately does NOT insert a version here; it lets
-- upgrade.php stamp the value that matches the deployed PostfixAdmin release.
-- Hard-coding a guess would make a future upgrade skip its own migrations.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `config` (
    `id`    INT(11)     NOT NULL AUTO_INCREMENT,
    `name`  VARCHAR(20) NOT NULL DEFAULT '',
    `value` VARCHAR(20) NOT NULL DEFAULT '',
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_config_name` (`name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='PostfixAdmin schema version';

-- ---------------------------------------------------------------------------
-- The 'ALL' pseudo-domain. PostfixAdmin grants a superadmin by inserting
-- (username, 'ALL') into domain_admins, so this row must exist. Its
-- backupmx/active values are irrelevant; the Postfix domain query filters it
-- out explicitly (`WHERE domain != 'ALL'`).
-- ---------------------------------------------------------------------------
INSERT INTO `domain` (`domain`, `description`, `transport`, `active`, `created`, `modified`)
SELECT 'ALL', 'PostfixAdmin superadmin marker', '', 0, NOW(), NOW()
WHERE NOT EXISTS (SELECT 1 FROM `domain` WHERE `domain` = 'ALL');

-- ---------------------------------------------------------------------------
-- The primary domain for this deployment.
-- ---------------------------------------------------------------------------
INSERT INTO `domain`
    (`domain`, `description`, `aliases`, `mailboxes`, `maxquota`, `quota`,
     `transport`, `backupmx`, `created`, `modified`, `active`)
SELECT '${DOMAIN}', 'Primary domain', ${DEFAULT_DOMAIN_ALIASES},
       ${DEFAULT_DOMAIN_MAILBOXES}, ${MAX_QUOTA_MB}, ${DEFAULT_QUOTA_MB},
       'virtual', 0, NOW(), NOW(), 1
WHERE NOT EXISTS (SELECT 1 FROM `domain` WHERE `domain` = '${DOMAIN}');

-- ---------------------------------------------------------------------------
-- Grants.
--
-- Three accounts, three blast radii:
--   ${DB_USER}      full DML on the mail schema  -> PostfixAdmin (web writes)
--   ${DB_RO_USER}   SELECT only                  -> Postfix + Dovecot maps
--   ${DB_REPL_USER} REPLICATION SLAVE only       -> the peer node
--
-- The application accounts are bound to 'localhost' so they can ONLY arrive
-- over the UNIX socket. The replication account is bound to the peer's
-- WireGuard address and nothing else - it is unusable from the public IP even
-- if a firewall rule is later mis-edited.
-- ---------------------------------------------------------------------------
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT SELECT, INSERT, UPDATE, DELETE ON `${DB_NAME}`.* TO '${DB_USER}'@'localhost';

CREATE USER IF NOT EXISTS '${DB_RO_USER}'@'localhost' IDENTIFIED BY '${DB_RO_PASS}';
GRANT SELECT ON `${DB_NAME}`.* TO '${DB_RO_USER}'@'localhost';
-- Dovecot's quota dict is the one place a map user must write.
GRANT INSERT, UPDATE, DELETE ON `${DB_NAME}`.`quota2` TO '${DB_RO_USER}'@'localhost';
GRANT INSERT, UPDATE, DELETE ON `${DB_NAME}`.`quota`  TO '${DB_RO_USER}'@'localhost';

CREATE USER IF NOT EXISTS '${DB_REPL_USER}'@'${NODE_A_WG_IP}' IDENTIFIED BY '${DB_REPL_PASS}';
GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '${DB_REPL_USER}'@'${NODE_A_WG_IP}';

CREATE USER IF NOT EXISTS '${DB_REPL_USER}'@'${NODE_B_WG_IP}' IDENTIFIED BY '${DB_REPL_PASS}';
GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '${DB_REPL_USER}'@'${NODE_B_WG_IP}';

-- ---------------------------------------------------------------------------
-- Roundcube schema + account. Contacts, identities and saved searches
-- replicate; sessions and caches are filtered out at the replica.
-- The tables themselves are created by Roundcube's own installto/initdb during
-- scripts/90-roundcube.sh, which must therefore run on NODE A FIRST.
-- ---------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS `${RC_DB_NAME}`
    CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '${RC_DB_USER}'@'localhost' IDENTIFIED BY '${RC_DB_PASS}';
GRANT ALL PRIVILEGES ON `${RC_DB_NAME}`.* TO '${RC_DB_USER}'@'localhost';
-- Roundcube's password plugin writes straight into the mail schema.
GRANT SELECT, UPDATE ON `${DB_NAME}`.`mailbox` TO '${RC_DB_USER}'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON `${DB_NAME}`.`vacation` TO '${RC_DB_USER}'@'localhost';

FLUSH PRIVILEGES;
