##############################################################################
# ha-mail :: /etc/nginx/snippets/hamail-security-headers.conf
#
# NOTE the `always` flag on every header: without it nginx omits the header on
# error responses (4xx/5xx), which is exactly where a clickjacking or MIME
# sniffing attack wants to live.
##############################################################################

add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "0" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "geolocation=(), microphone=(), camera=(), payment=(), usb=()" always;
add_header Cross-Origin-Opener-Policy "same-origin" always;

# Content-Security-Policy.
#
# 'unsafe-inline' for style-src and script-src is required by both Roundcube
# and PostfixAdmin: they emit inline handlers and inline <style> blocks
# throughout. Removing it breaks the UI outright. The remaining directives
# still deliver the two things that matter most here:
#   * frame-ancestors 'self'  - clickjacking protection that X-Frame-Options
#                               cannot express as precisely
#   * form-action 'self'      - a stored-XSS payload cannot post the session
#                               or a password-change form to an attacker host
add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob: cid:; font-src 'self' data:; connect-src 'self'; frame-ancestors 'self'; form-action 'self'; base-uri 'self'; object-src 'none'" always;
