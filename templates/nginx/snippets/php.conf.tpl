##############################################################################
# ha-mail :: /etc/nginx/snippets/hamail-php.conf
#
# Included INSIDE a location block that has already chosen an upstream via
# `set $hamail_php_pool`. Kept separate so the FastCGI hardening below is
# written once and cannot drift between the two applications.
##############################################################################

include fastcgi_params;

fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
fastcgi_param DOCUMENT_ROOT   $document_root;

# HTTPS=on is what makes PHP's session.cookie_secure and the applications'
# own "am I on TLS" checks behave correctly behind nginx.
fastcgi_param HTTPS on;
fastcgi_param SERVER_NAME $host;

# Refuse to pass a request for a .php file that does not exist. Without this,
# a request for /uploads/avatar.jpg/x.php is handed to PHP-FPM with
# SCRIPT_FILENAME pointing at the JPEG - the classic path-info RCE.
try_files $fastcgi_script_name =404;
fastcgi_split_path_info ^(.+\.php)(/.*)$;

fastcgi_index index.php;
fastcgi_intercept_errors off;
fastcgi_buffer_size 32k;
fastcgi_buffers 8 32k;
fastcgi_busy_buffers_size 64k;
fastcgi_read_timeout 120s;
fastcgi_connect_timeout 10s;
fastcgi_send_timeout 60s;

# Hide the PHP version from responses.
fastcgi_hide_header X-Powered-By;
