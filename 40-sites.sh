#!/bin/sh
# Caddy-style config from env (or /etc/ngx/ngx.env, which overrides it):
#   SITES="example.com,www.example.com=app:3000  static.example.com=/srv/www"
# Entry: domain[,domain][/path]=target
#   target  /dir                           static files: SPA fallback to /index.html, dotfiles (.git, .env) hidden
#           host:port, http(s)://host[:port][/prefix]   reverse proxy; https upstreams are verified
#           https+insecure://host[:port]   same, without verifying the upstream's certificate
#           fastcgi://host:port/docroot    PHP: files from docroot, *.php to php-fpm (WordPress-style permalinks)
#   /path   only that exact request path (path* = prefix) goes to target, which must be a proxy;
#           the domain needs its own entry too. e.g. "app.test=/srv/app app.test/api*=api:8080"
# TLS: public domains get Let's Encrypt via nginx's ACME module (http-01); wildcards use DNS-01 via acme.sh,
#   needing DNS_PROVIDER (acme.sh name, e.g. dns_cf) + that provider's env vars (e.g. CF_Token).
#   Local domains (localhost, *.localhost, .test, .local, .internal, .home.arpa) and those in TLS_INTERNAL
#   ("a.dev b.dev", or "*" for all) get certificates from a local CA instead: offline, no DNS, wildcards too.
#   LOCAL_CA_CERT + LOCAL_CA_KEY sign with your own CA (one browsers already trust); otherwise one is
#   generated in /var/cache/nginx/acme/local/ca.crt. LOCAL_CERT_DAYS (90) = leaf lifetime, renewed at 1/3 left.
# ACME_EMAIL, ACME_URL (default Let's Encrypt prod), ACME_CA (CA file for private ACME servers),
#   DNS_SLEEP (fixed propagation wait instead of acme.sh's public-DNS check)
# HTTPS_REDIRECT=off also serves sites on :80; HTTPS_PORT=8443 points the :80 redirect at that port.
# No SITES = no generated config; drop your own files in /etc/nginx/conf.d or /etc/nginx/templates instead.
#
# Modes: (none)     boot: build the config; if that fails, fall back to the last one that worked (or none),
#                    so nginx always starts. In a container, also starts --watch.
#        --apply    build, nginx -t, hot reload; on failure the running config is kept
#        --watch    --apply whenever ngx.env changes (checked every second), a 12h renewal pass,
#                   and a retry every 5 min while the last apply failed or had warnings
#        --health   container healthcheck: nginx alive and answering; restarts the watcher if it died
#        --generate internal: write the config from ngx.env, nothing else
# Every apply writes "<sha256 of ngx.env> ok" or "... error: <why>" to $NGX_STATUS (/etc/ngx/ngx.status),
# followed by one line per warning, so whatever wrote ngx.env can tell when and whether it took effect.
set -eu
env_file=/etc/ngx/ngx.env
out=/etc/nginx/conf.d/sites.conf
state=/var/cache/nginx/acme
good=$state/last-good.conf  # on the state volume, so it survives the container being recreated
status=${NGX_STATUS:-/etc/ngx/ngx.status}
pidfile=/run/nginx.pid

envsum() { sha256sum "$env_file" 2>/dev/null | cut -d' ' -f1; }
report() { (umask 022; printf '%s\n' "$@" | sed '/^$/d' > "$status.tmp" && mv "$status.tmp" "$status") 2>/dev/null || true; }
acmesh() { /opt/acme.sh/acme.sh --home /opt/acme.sh --config-home "$state/dns" "$@"; }
# File sharing (Docker Desktop, Kiri) can keep a stale entry after ngx.env is replaced by a rename:
# it "exists" but can't be opened, sometimes for many seconds. Listing the directory refreshes it.
refresh() { for _ in "${env_file%/*}"/*; do :; done; }
nginx_up() { [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; }

# Returns 0 = applied, 3 = applied with warnings, 1 = rejected (previous config kept).
apply() {  # $1: reload | boot
    # Read ngx.env once: the checksum we report and the config we build come from the same bytes,
    # even if the file changes (or is caught half-written) while we work.
    snap=$(mktemp)
    refresh
    if [ -e "$env_file" ]; then
        if ! cat "$env_file" > "$snap" 2>/dev/null; then  # never build from a file we couldn't read
            rm -f "$snap"; echo "40-sites.sh: can't read $env_file; config unchanged" >&2; return 1
        fi
        sum=$(sha256sum < "$snap" | cut -d' ' -f1)
    else sum=; fi
    cp -p "$out" "$out.prev" 2>/dev/null || rm -f "$out.prev"
    if log=$(NGX_ENV_SNAPSHOT=$snap "$0" --generate 2>&1 && nginx -t 2>&1 && { [ "$1" = boot ] || nginx -s reload 2>&1; }); then
        rm -f "$snap"
        rm -f "$out.prev"
        if [ -f "$out" ]; then cp -p "$out" "$good"; else rm -f "$good"; fi
        warn=$(echo "$log" | sed -n 's/^40-sites.sh: warning: //p')
        report "$sum ok" "$warn"
        echo "$log" | grep '^40-sites.sh' || :
        [ -z "$warn" ] || return 3
        return 0
    fi
    rm -f "$snap"
    why=$(echo "$log" | grep -v -e '^40-sites.sh: wrote' -e 'syntax is ok$' -e 'is successful$' | tr '\n' ' ')
    if [ -f "$out.prev" ]; then mv "$out.prev" "$out"
    elif [ -f "$good" ]; then cp -p "$good" "$out"; fi  # boot: the last config that worked
    # never leave nginx unable to start: an unusable fallback is dropped, nginx then serves no sites
    [ "$1" != boot ] || nginx -t >/dev/null 2>&1 || rm -f "$out"
    report "$sum error: $why"
    echo "40-sites.sh: not applied, serving the previous config: $why" >&2
    return 1
}

case ${1:-} in
--apply)
    # one apply at a time (native: the path unit and `systemctl reload` can overlap)
    exec 9>"${TMPDIR:-/tmp}/ngx-apply.lock"
    if command -v flock >/dev/null; then flock 9; fi
    rc=0; apply reload || rc=$?
    exit $rc ;;
--watch)
    # Polls every 0.1s: inotify never sees writes made through Docker Desktop's or Kiri's file sharing.
    # Reading the file with `read` keeps each poll free of subprocesses.
    until nginx_up; do sleep 0.1; done  # a reload before nginx runs would fail and lose the change
    # One `read` of the whole file: a redirection that fails on a compound command (a while loop)
    # kills a non-interactive shell, and file sharing briefly shows a renamed file as missing.
    readenv() {
        c=; IFS= read -r -d '' c 2>/dev/null < "$env_file" || :
        [ -n "$c" ] || { refresh; IFS= read -r -d '' c 2>/dev/null < "$env_file" || :; }
    }
    # nap = sleep without starting a process: `read -t` on a pipe nobody writes to
    fifo=$(mktemp -u); mkfifo "$fifo"; exec 8<>"$fifo"; rm -f "$fifo"
    nap() { read -t "$1" _ <&8 || :; }
    readenv; seen=$c
    [ "$(envsum)" = "${2:-}" ] || "$0" --apply || :  # changed while booting ("" = always catch up)
    ticks=0 period=432000  # 0.1s ticks: 12h
    while nap 0.1; do
        ticks=$((ticks + 1)); readenv
        # an empty read (file missing, or caught mid-replace) is never a change: it would remove every site
        [ -n "$c" ] || [ -z "$seen" ] || continue
        if [ "$c" != "$seen" ]; then
            # a file still being written reads differently a moment later: wait until it holds still
            held=$c; nap 0.03; readenv; [ "$c" = "$held" ] || continue
        elif [ $ticks -lt $period ]; then continue
        fi
        [ $ticks -lt 432000 ] || [ ! -d "$state/dns" ] || acmesh --cron >/dev/null || :  # wildcard renewals
        seen=$c; ticks=0
        rc=0; "$0" --apply || rc=$?  # also renews local certificates nearing expiry
        period=432000; [ $rc = 0 ] || period=3000  # retry failures and warnings every 5 min
    done ;;
--health)
    nginx_up || { echo "nginx is not running"; exit 1; }
    # with no sites (none configured yet, or a broken first config) nothing listens, and that's fine
    [ ! -f "$out" ] || curl -s -o /dev/null --max-time 5 http://127.0.0.1/ || { echo "nginx is not answering on :80"; exit 1; }
    if [ "${NGX_RENEW_LOOP:-1}" = 1 ] && ! pgrep -f '40-sites.sh --watch' >/dev/null; then
        # the watcher keeps config changes and renewals flowing: bring it back, catching up on what it missed
        setsid "$0" --watch "" </dev/null >/proc/1/fd/1 2>&1 &
        echo "40-sites.sh: watcher was not running; restarted" | tee /proc/1/fd/1
    fi
    exit 0 ;;
--generate) ;;
"")
    if [ "${NGX_RENEW_LOOP:-1}" = 1 ]; then  # container boot
        rm -f "$pidfile"  # a stale one from before a restart would make the watcher start too early
        boot=$(envsum)
        apply boot || :
        "$0" --watch "$boot" &
    else
        apply boot || :  # native ExecStartPre: same fallback, systemd runs the renewals and reloads
    fi
    exit 0 ;;
*) echo "usage: 40-sites.sh [--apply|--watch|--health]" >&2; exit 2 ;;
esac

# --generate: everything below reads ngx.env and writes $out, nothing else
src=${NGX_ENV_SNAPSHOT:-$env_file}
if [ -s "$src" ]; then set -a; . "$src"; set +a; fi
if [ -z "${SITES:-}" ]; then  # SITES removed -> drop the old generated config too
    rm -f "$out"; exit 0
fi
set -f  # no globbing while splitting SITES
# docker entrypoint exports NGINX_LOCAL_RESOLVERS; natively, read resolv.conf (IPv6 needs [brackets])
: "${NGINX_LOCAL_RESOLVERS:=$(awk '/^nameserver/ { print ($2 ~ ":") ? "[" $2 "]" : $2 }' /etc/resolv.conf | xargs)}"
certs=$state/certs local=$state/local
mkdir -p "$certs" "$local"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
: > "$tmp/ups"; : > "$tmp/servers"
wildcard= public= n=0 cabundle=
days=${LOCAL_CERT_DAYS:-90}
# local leaves due for renewal (1/3 of their life left), found in one pass instead of an openssl per site
stale=" $(find "$local" -name '*.crt' -mtime +$((days - days / 3 - 1)) 2>/dev/null | tr '\n' ' ') "
for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
    if [ -f "$f" ]; then cabundle=$f; break; fi
done

die() { echo "40-sites.sh: $*" >&2; exit 1; }
warn() { echo "40-sites.sh: warning: $*" >&2; }

is_local() {
    case $1 in localhost|*.localhost|*.test|*.local|*.internal|*.home.arpa) return 0 ;; esac
    case " ${TLS_INTERNAL:-} " in *" * "*|*" $1 "*) return 0 ;; esac
    return 1
}

# DNS-01 needs no running web server, so the first issue happens here, before nginx starts.
issue_dns() {
    : "${DNS_PROVIDER:?wildcard in SITES needs DNS_PROVIDER, e.g. dns_cf (see acme.sh dnsapi wiki)}"
    set --
    for d in $domains; do set -- "$@" -d "$d"; done
    rc=0
    ACCOUNT_EMAIL=${ACME_EMAIL:-} acmesh --issue --dns "$DNS_PROVIDER" "$@" \
        --server "${ACME_URL:-letsencrypt}" ${ACME_CA:+--ca-bundle "$ACME_CA"} ${DNS_SLEEP:+--dnssleep "$DNS_SLEEP"} || rc=$?
    [ $rc = 0 ] || [ $rc = 2 ] || return 1  # 2 = not due yet
    acmesh --install-cert -d "$first" --key-file "$certs/$first.key" --fullchain-file "$certs/$first.crt" \
        --reloadcmd 'nginx -s reload 2>/dev/null || true'
}

# Local CA leaf for the entry's domains, reissued when missing, renamed, older than the CA, or 1/3 from expiry.
local_cert() {
    ca=${LOCAL_CA_CERT:-$local/ca.crt} cakey=${LOCAL_CA_KEY:-$local/ca.key}
    if [ ! -f "$cakey" ]; then
        [ -z "${LOCAL_CA_KEY:-}" ] || die "LOCAL_CA_KEY $cakey not found"
        (umask 077; openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
            -subj "/CN=ngx local CA" -addext basicConstraints=critical,CA:TRUE \
            -addext keyUsage=critical,keyCertSign,cRLSign -keyout "$cakey" -out "$ca" 2>/dev/null)
        chmod 644 "$ca"
        echo "40-sites.sh: created local CA $ca; trust it to avoid browser warnings" >&2
    fi
    leaf=$local/$file names=
    [ ! -f "$leaf.names" ] || read -r names < "$leaf.names"
    if [ -f "$leaf.crt" ] && [ "$names" = "$domains" ] && [ "$ca" -ot "$leaf.crt" ]; then
        case $stale in *" $leaf.crt "*) ;; *) return 0 ;; esac
    fi
    san=; for d in $domains; do san="$san${san:+,}DNS:$d"; done
    printf '%s\n' "subjectAltName=$san" extendedKeyUsage=serverAuth keyUsage=critical,digitalSignature \
        basicConstraints=critical,CA:FALSE authorityKeyIdentifier=keyid subjectKeyIdentifier=hash > "$tmp/ext"
    (umask 077; openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$first" \
        -keyout "$tmp/key" -out "$tmp/csr" 2>/dev/null)
    openssl x509 -req -in "$tmp/csr" -CA "$ca" -CAkey "$cakey" -set_serial "0x$(openssl rand -hex 16)" \
        -days "$days" -extfile "$tmp/ext" -out "$tmp/crt" 2>/dev/null || die "local CA could not sign $first"
    # ponytail: always append the signer; clients ignore a root in the chain, and an intermediate is needed
    cat "$tmp/crt" "$ca" > "$leaf.crt.new"
    mv "$tmp/key" "$leaf.key"; mv "$leaf.crt.new" "$leaf.crt"; echo "$domains" > "$leaf.names"
}

# Sets $loc for a proxy target and adds its upstream (re-resolved at runtime, so nginx boots
# even when the app is down, and keeps backend connections alive).
proxy_loc() {
    case $1 in
        https+insecure://*) scheme=https port=443 verify= ;;
        https://*)          scheme=https port=443 verify=1 ;;
        *)                  scheme=http port=80 verify= ;;
    esac
    hp=${1#*://} path=
    case $hp in */*) path=/${hp#*/}; hp=${hp%%/*} ;; esac
    case $hp in *:*) ;; *) hp=$hp:$port ;; esac
    n=$((n + 1))
    echo "upstream up$n { zone up$n 64k; server $hp resolve; keepalive 32; }" >> "$tmp/ups"
    # a /prefix goes in front of the whole original URI (Caddy's `rewrite * /prefix{uri}`)
    path=${path%/}
    loc="proxy_pass $scheme://up$n${path:+$path\$request_uri};"
    if [ $scheme = https ]; then loc="$loc proxy_ssl_server_name on; proxy_ssl_name ${hp%:*};"; fi
    if [ -n "$verify" ]; then
        loc="$loc proxy_ssl_verify on; proxy_ssl_verify_depth 4; proxy_ssl_trusted_certificate ${cabundle:?no CA bundle to verify https upstreams};"
    fi
}

bad=$(printf '%s\n' $SITES | grep -Ev '^[A-Za-z0-9.,*-]+(/[A-Za-z0-9._~/-]*\*?)?=[A-Za-z0-9._:/+~-]+$' | head -1 || :)
[ -z "$bad" ] || die "bad SITES entry '$bad' (want domain[,domain][/path]=target)"

# path entries first: their locations go into the server block of the domain's own entry
for site in $SITES; do
    key=${site%%=*} target=${site#*=}
    case $key in */*) ;; *) continue ;; esac
    first=${key%%[,/]*} at=/${key#*/}
    case $target in /*|fastcgi://*) die "'$site': a /path entry needs a proxy target" ;; esac
    proxy_loc "$target"
    case $at in
        *\*) echo "    location ^~ ${at%\*} { $loc }" ;;
        *)   echo "    location = $at { $loc }" ;;
    esac >> "$tmp/loc.$first"
done

redirect="https://\$host\$request_uri"
[ "${HTTPS_PORT:-443}" = 443 ] || redirect="https://\$host:$HTTPS_PORT\$request_uri"
plain=; [ "${HTTPS_REDIRECT:-on}" != off ] || plain="listen 80;"
hide='location ~ /\.(?!well-known(/|$)) { return 404; }  # .git, .env, ...: 404 tells a scanner less than 403'
# /dir -> /dir/ when it holds an index file (as Caddy does), so the page's relative links resolve.
# Server level on purpose: an `if` inside a location turns off that location's try_files.
slash() { echo 'set $dir_index ""; if ($uri !~ /$) { set $dir_index $request_filename/'"$1"'; } if (-f $dir_index) { return 308 $uri/$is_args$args; }'; }
slash_html=$(slash index.html) slash_php=$(slash index.php)

for site in $SITES; do
    key=${site%%=*} target=${site#*=}
    case $key in */*) continue ;; esac
    first=${key%%,*}
    IFS=,; set -- $key; IFS=' 	
'; domains="$*"  # a,b -> "a b" without a subprocess
    case $first in \**) file=_${first#\*} ;; *) file=$first ;; esac
    case $target in
        /*) body="root $target;
    $slash_html
    $hide
    location / { try_files \$uri \$uri/ /index.html =404; }" ;;
        fastcgi://*)
            hp=${target#fastcgi://}; root=/${hp#*/}; hp=${hp%%/*}
            case $root in /|"/$hp") die "'$site': fastcgi target needs a docroot, e.g. fastcgi://php:9000/var/www" ;; esac
            n=$((n + 1))
            echo "upstream up$n { zone up$n 64k; server $hp resolve; keepalive 8; }" >> "$tmp/ups"
            body="root $root;
    index index.php index.html;
    $slash_php
    $hide
    location / { try_files \$uri \$uri/ /index.php\$is_args\$args; }
    location ~ [^/]\.php(/|\$) {
        fastcgi_split_path_info ^(.+?\.php)(/.*)\$;
        set \$path_info \$fastcgi_path_info;  # try_files clears it
        try_files \$fastcgi_script_name =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$path_info;
        fastcgi_buffer_size 64k;
        fastcgi_buffers 16 16k;
        fastcgi_read_timeout 1h;
        fastcgi_keep_conn on;
        fastcgi_pass up$n;
    }" ;;
        *) proxy_loc "$target"; body="location / { $loc }" ;;
    esac
    skip=
    if is_local "$first"; then
        local_cert
        tls="ssl_certificate $local/$file.crt;
    ssl_certificate_key $local/$file.key;"
    else
        case $key in
            *\**) wildcard=1
                 # A DNS provider outage must not block every other site's change: keep serving the
                 # certificate we have, or leave just this site out until a retry succeeds.
                 if ! issue_dns >&2; then  # stdout is the conf file
                     if [ -f "$certs/$first.crt" ]; then warn "DNS-01 for $domains failed; serving its existing certificate"
                     else warn "DNS-01 for $domains failed; site left out until a retry succeeds"; skip=1; fi
                 fi
                 tls="ssl_certificate $certs/$first.crt;
    ssl_certificate_key $certs/$first.key;" ;;
            *)   public=1
                 tls="acme_certificate main;
    ssl_certificate \$acme_certificate;
    ssl_certificate_key \$acme_certificate_key;
    ssl_certificate_cache max=2;" ;;
        esac
    fi
    paths=
    for d in $domains; do
        [ -f "$tmp/loc.$d" ] || continue
        paths="$paths$(cat "$tmp/loc.$d")
"
        rm "$tmp/loc.$d"
    done
    [ -z "$skip" ] || continue
cat >> "$tmp/servers" <<EOF

server {
    listen 443 ssl;
    listen 443 quic;
    $plain
    http2 on;
    server_name $domains;

    $tls

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header Alt-Svc 'h3=":443"; ma=86400' always;

$paths    $body
}
EOF
done
left=$(ls "$tmp" | sed -n 's/^loc\.//p' | xargs)
[ -z "$left" ] || die "path entries for $left have no site entry of their own"

{
echo "resolver ${NGINX_LOCAL_RESOLVERS:?no resolver found} valid=30s;"
echo "resolver_timeout 5s;"
[ -z "$public" ] || cat <<EOF

acme_issuer main {
    uri ${ACME_URL:-https://acme-v02.api.letsencrypt.org/directory};
    state_path $state;
    accept_terms_of_service;
${ACME_EMAIL:+    contact $ACME_EMAIL;}
${ACME_CA:+    ssl_trusted_certificate $ACME_CA;}
}
EOF
cat <<'EOF'

server_tokens off;
absolute_redirect off;  # relative Location headers stay right behind remapped ports

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

# Caddy-like proxy defaults: no upload limit, long requests and idle websockets survive,
# responses stream (SSE) instead of buffering, big cookie/JWT headers fit.
client_max_body_size 0;
large_client_header_buffers 4 32k;
proxy_connect_timeout 5s;  # a dead backend fails fast instead of hanging for nginx's default 60s
proxy_read_timeout 1h;
proxy_send_timeout 1h;
proxy_buffering off;
proxy_buffer_size 64k;
proxy_buffers 16 16k;  # with 64k above, so nginx accepts the busy-buffers default
proxy_http_version 1.1;
proxy_set_header Host $http_host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $remote_addr;  # replace, not append: a client-sent X-Forwarded-For is spoofable
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host $http_host;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;
map $http_upgrade $connection_upgrade { default upgrade; '' ''; }  # '' = no header, so backend keepalive works

# unknown hostnames: drop the TLS handshake instead of leaking a cert
server {
    listen 443 ssl default_server;
    listen 443 quic reuseport default_server;
    ssl_reject_handshake on;
}
EOF
cat <<EOF

# :80 -> https (ACME http-01 challenges are answered by the module before this)
server {
    listen 80 default_server;
    location / { return 301 $redirect; }
}
EOF
cat "$tmp/ups" "$tmp/servers"
} > "$out.new"
mv "$out.new" "$out"
echo "40-sites.sh: wrote $out for: $SITES"
