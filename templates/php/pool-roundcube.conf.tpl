;#############################################################################
; ha-mail :: /etc/php/8.3/fpm/pool.d/roundcube.conf
;#############################################################################

[roundcube]
user = www-data
group = www-data
listen = /run/php/php-fpm-roundcube.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = dynamic
pm.max_children = 25
pm.start_servers = 4
pm.min_spare_servers = 2
pm.max_spare_servers = 8
pm.max_requests = 500

request_terminate_timeout = 300s
request_slowlog_timeout = 15s
slowlog = /var/log/php-fpm-roundcube-slow.log

php_admin_value[error_log] = /var/log/php-fpm-roundcube-error.log
php_admin_flag[log_errors] = on
php_admin_flag[display_errors] = off
php_admin_value[memory_limit] = 512M

; Must be >= nginx client_max_body_size, or a large attachment fails with a
; confusing "413" on one layer and a silent truncation on the other.
php_admin_value[upload_max_filesize] = 64M
php_admin_value[post_max_size] = 64M
php_admin_value[max_execution_time] = 300
php_admin_value[max_file_uploads] = 50

php_admin_value[open_basedir] = ${ROUNDCUBE_ROOT}:/tmp:/usr/share/php:/var/lib/php/sessions-roundcube
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen,parse_ini_file,show_source,dl,pcntl_exec

; ---------------------------------------------------------------------------
; SESSIONS ARE NODE-LOCAL FILES, NOT ROWS IN THE REPLICATED DATABASE.
; ---------------------------------------------------------------------------
; Roundcube can store sessions in SQL, and it is tempting to do that here so a
; user survives a failover mid-session. Do not:
;   * every page view becomes a write to a replicated table
;   * that write races with the same user's next request landing on the other
;     node, and the session row flip-flops
;   * the session holds the user's IMAP password, encrypted with
;     ROUNDCUBE_DES_KEY - replicating it doubles the number of places that
;     ciphertext exists
; The cost of this choice is one re-login after a failover. That is the right
; trade.
php_value[session.save_handler] = files
php_value[session.save_path] = /var/lib/php/sessions-roundcube
php_value[session.cookie_secure] = 1
php_value[session.cookie_httponly] = 1
php_value[session.cookie_samesite] = Strict
php_value[session.use_strict_mode] = 1
php_value[session.gc_maxlifetime] = 10800
php_admin_value[expose_php] = off
