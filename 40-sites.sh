#!/bin/sh
# Caddy-style config from env:
#   SITES="example.com,www.example.com=app:3000  static.example.com=/srv/www"
#   target: /path -> static files, host:port or http(s)://url -> reverse proxy
#   ACME_EMAIL (optional), ACME_URL (default Let's Encrypt prod), ACME_CA (CA file for private ACME servers)
# Wildcards: "example.com,*.example.com=app:3000" -> DNS-01 via acme.sh, needs
#   DNS_PROVIDER (acme.sh name, e.g. dns_cf) + that provider's env vars (e.g. CF_Token)
#   DNS_SLEEP (optional): fixed wait in seconds instead of acme.sh's public-DNS propagation check
# No SITES = no-op; drop your own files in /etc/nginx/conf.d or /etc/nginx/templates instead.
# Settings can also live in /etc/ngx/ngx.env (shell syntax; written by install.sh) and override env vars.
set -eu
if [ -f /etc/ngx/ngx.env ]; then set -a; . /etc/ngx/ngx.env; set +a; fi
out=/etc/nginx/conf.d/sites.conf
[ -n "${SITES:-}" ] || { rm -f "$out"; exit 0; }  # SITES removed -> drop the old generated config too
set -f  # no globbing while splitting SITES
# docker entrypoint exports NGINX_LOCAL_RESOLVERS; natively, read resolv.conf (IPv6 needs [brackets])
: "${NGINX_LOCAL_RESOLVERS:=$(awk '/^nameserver/ { print ($2 ~ ":") ? "[" $2 "]" : $2 }' /etc/resolv.conf | xargs)}"

acmesh() { /opt/acme.sh/acme.sh --home /opt/acme.sh --config-home /var/cache/nginx/acme/dns "$@"; }
# DNS-01 needs no running web server, so the first issue happens here, before nginx starts.
issue_dns() {
    : "${DNS_PROVIDER:?wildcard in SITES needs DNS_PROVIDER, e.g. dns_cf (see acme.sh dnsapi wiki)}"
    first=$1; set --
    for d in $domains; do set -- "$@" -d "$d"; done
    rc=0
    ACCOUNT_EMAIL=${ACME_EMAIL:-} acmesh --issue --dns "$DNS_PROVIDER" "$@" \
        --server "${ACME_URL:-letsencrypt}" ${ACME_CA:+--ca-bundle "$ACME_CA"} ${DNS_SLEEP:+--dnssleep "$DNS_SLEEP"} || rc=$?
    [ $rc = 0 ] || [ $rc = 2 ] || { echo "40-sites.sh: DNS-01 issue failed for $domains" >&2; exit 1; }  # 2 = not due yet
    acmesh --install-cert -d "$first" --key-file "$certs/$first.key" --fullchain-file "$certs/$first.crt" \
        --reloadcmd 'nginx -s reload 2>/dev/null || true'
}
certs=/var/cache/nginx/acme/certs
mkdir -p "$certs"
wildcard=
n=0

{
cat <<EOF
resolver ${NGINX_LOCAL_RESOLVERS:?no resolver found} valid=30s;

acme_issuer main {
    uri ${ACME_URL:-https://acme-v02.api.letsencrypt.org/directory};
    state_path /var/cache/nginx/acme;
    accept_terms_of_service;
${ACME_EMAIL:+    contact $ACME_EMAIL;}
${ACME_CA:+    ssl_trusted_certificate $ACME_CA;}
}
EOF
cat <<'EOF'

server_tokens off;

# skip open()/stat() per static request; 10s revalidation so deploys show up quickly
open_file_cache max=10000 inactive=60s;
open_file_cache_valid 10s;
# TLS resumption across workers (returning visitors skip the full handshake)
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1d;
# kernel TLS: lets sendfile work over HTTPS. Needs `modprobe tls` on the host; silently falls back otherwise.
ssl_conf_command Options KTLS;

gzip on;
gzip_vary on;
gzip_proxied any;
gzip_types text/plain text/css text/xml application/json application/javascript application/xml image/svg+xml;

proxy_http_version 1.1;
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;
map $http_upgrade $connection_upgrade { default upgrade; '' ''; }  # '' = no header, so backend keepalive works

# :80 -> https (ACME http-01 challenges are answered by the module before this)
server {
    listen 80 default_server;
    location / { return 301 https://$host$request_uri; }
}

# unknown hostnames: drop the TLS handshake instead of leaking a cert
server {
    listen 443 ssl default_server;
    listen 443 quic reuseport default_server;
    ssl_reject_handshake on;
}
EOF

for site in $SITES; do
    echo "$site" | grep -Eq '^[A-Za-z0-9.,*-]+=[A-Za-z0-9._:/-]+$' \
        || { echo "40-sites.sh: bad SITES entry '$site' (want domain[,domain]=target)" >&2; exit 1; }
    domains=$(echo "${site%%=*}" | tr , ' ')
    target=${site#*=}
    n=$((n + 1)); ups=
    case $target in
        /*) loc="root $target; try_files \$uri \$uri/ =404;" ;;
        *)  # upstream + resolve: re-resolved at runtime (boots even if the app is down) AND keeps backend connections alive
            case $target in https://*) scheme=https port=443 ;; *) scheme=http port=80 ;; esac
            hp=${target#*://}; path=
            case $hp in */*) path=/${hp#*/}; hp=${hp%%/*} ;; esac
            case $hp in *:*) ;; *) hp=$hp:$port ;; esac
            ups="upstream up$n { zone up$n 64k; server $hp resolve; keepalive 32; }"
            loc="proxy_pass $scheme://up$n$path;"
            [ $scheme = http ] || loc="$loc proxy_ssl_server_name on; proxy_ssl_name ${hp%:*};" ;;
    esac
    case $site in
        *\**) first=${site%%[,=]*}
              issue_dns "$first" >&2  # stdout is the conf file
              wildcard=1
              tls="ssl_certificate $certs/$first.crt;
    ssl_certificate_key $certs/$first.key;" ;;
        *)    tls="acme_certificate main;
    ssl_certificate \$acme_certificate;
    ssl_certificate_key \$acme_certificate_key;
    ssl_certificate_cache max=2;" ;;
    esac
cat <<EOF

$ups
server {
    listen 443 ssl;
    listen 443 quic;
    http2 on;
    server_name $domains;

    $tls

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header Alt-Svc 'h3=":443"; ma=86400' always;

    location / { $loc }
}
EOF
done
} > "$out"

# ponytail: plain sleep loop instead of crond; acme.sh renews at ~60 days and reloads nginx itself
# (native installs set NGX_RENEW_LOOP=0 and use a systemd timer instead)
if [ -n "$wildcard" ] && [ "${NGX_RENEW_LOOP:-1}" = 1 ]; then
    (while sleep 43200; do acmesh --cron; done) &
fi

echo "40-sites.sh: wrote $out for: $SITES"
