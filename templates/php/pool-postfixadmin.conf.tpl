;#############################################################################
; ha-mail :: /etc/php/8.3/fpm/pool.d/postfixadmin.conf
;
; A dedicated pool for the admin portal, isolated from webmail. If Roundcube
; is being hammered, the admin portal still answers - which matters most
; precisely when you need to log in and fix something.
;#############################################################################

[postfixadmin]
user = www-data
group = www-data
listen = /run/php/php-fpm-postfixadmin.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
pm.max_requests = 500

; A PHP request that outlives this is stuck on a lock, not working.
request_terminate_timeout = 60s
request_slowlog_timeout = 10s
slowlog = /var/log/php-fpm-postfixadmin-slow.log

php_admin_value[error_log] = /var/log/php-fpm-postfixadmin-error.log
php_admin_flag[log_errors] = on
php_admin_flag[display_errors] = off
php_admin_value[memory_limit] = 256M
php_admin_value[upload_max_filesize] = 8M
php_admin_value[post_max_size] = 8M
php_admin_value[max_execution_time] = 60

; open_basedir confines this pool to its own tree. A file-read bug in the
; admin portal then cannot reach Roundcube's config - which holds the DES key
; that decrypts users' stored IMAP passwords.
php_admin_value[open_basedir] = ${POSTFIXADMIN_ROOT}:/tmp:/usr/share/php:/var/lib/php/sessions-postfixadmin

php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen,curl_multi_exec,parse_ini_file,show_source,dl,pcntl_exec

; Sessions are node-local files, in a directory only this pool can read.
php_value[session.save_handler] = files
php_value[session.save_path] = /var/lib/php/sessions-postfixadmin
php_value[session.cookie_secure] = 1
php_value[session.cookie_httponly] = 1
php_value[session.cookie_samesite] = Strict
php_value[session.use_strict_mode] = 1
php_value[session.gc_maxlifetime] = 3600
php_admin_value[expose_php] = off
