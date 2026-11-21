#!/bin/sh
# ngx installer: nginx + automatic Let's Encrypt, configured Caddy-style with one SITES line.
#
#   curl -fsSL https://raw.githubusercontent.com/leyume/ngx/main/install.sh \
#     | sudo SITES="example.com=127.0.0.1:3000" ACME_EMAIL=you@example.com sh
#
#   ./install.sh            Linux + systemd (Debian/Ubuntu/RHEL-family/Amazon Linux): native nginx.org packages
#   ./install.sh --docker   anywhere with Docker (default on macOS and other systems)
#                           NGX_HTTP_PORT / NGX_HTTPS_PORT remap host ports (Let's Encrypt still needs public 80)
#
# Config: /etc/ngx/ngx.env (native) or ~/.ngx/ngx.env (docker). Saved edits apply within a second with
# zero downtime; ngx.status next to it says "ok" or why a change was rejected (the old config keeps serving).
set -eu

RAW=${NGX_RAW:-https://raw.githubusercontent.com/leyume/ngx/main}
IMAGE=${NGX_IMAGE:-leyume/ngx:latest}
ACMESH=3.1.6
case $0 in *install.sh) here=$(cd "$(dirname "$0")" && pwd) ;; *) here= ;; esac  # empty when piped (curl | sh)

say() { printf '\033[1mngx:\033[0m %s\n' "$*"; }
die() { say "$*" >&2; exit 1; }

# local checkout if present (./install.sh), else download (curl | sh)
fetch() {
    if [ -f "$here/$1" ]; then cp "$here/$1" "$2"; else curl -fsSL "$RAW/$1" -o "$2"; fi
}

# first install: seed the env file from the caller's environment; never overwrite an existing one
write_env() {
    [ -f "$1" ] && { say "keeping existing $1"; return; }
    mkdir -p "$(dirname "$1")"
    umask 077  # may hold DNS API tokens
    {
        echo "# ngx config (shell syntax). Saved changes apply within a second; ngx.status says ok or why not."
        echo "# SITES: space-separated domain[,domain][/path]=target; target = host:port, http(s)://url, /static/dir,"
        echo "#   or fastcgi://php-fpm:9000/docroot. Local domains (.test, .localhost, ...) get certs from a local CA."
        echo "# Wildcards (*.example.com) need DNS_PROVIDER (acme.sh name, e.g. dns_cf) + its token, e.g. CF_Token=..."
        for k in SITES ACME_EMAIL ACME_URL ACME_CA DNS_PROVIDER DNS_SLEEP; do
            eval "v=\${$k:-}"
            if [ -n "$v" ]; then echo "$k=\"$v\""; else echo "#$k="; fi
        done
    } > "$1"
    umask 022
    say "wrote $1"
}

install_docker() {
    command -v docker >/dev/null || die "Docker not found. Install Docker Desktop, OrbStack or colima (macOS), or docker-ce (Linux)."
    conf=${NGX_CONF_DIR:-$HOME/.ngx}
    write_env "$conf/ngx.env"
    docker pull -q "$IMAGE" >/dev/null 2>&1 || docker image inspect "$IMAGE" >/dev/null || die "cannot pull $IMAGE"
    docker rm -f ngx >/dev/null 2>&1 || true
    # dir mount (not file) so editors that replace the file are still seen; rw: ngx writes ngx.status there
    docker run -d --name ngx --restart unless-stopped \
        -p "${NGX_HTTP_PORT:-80}:80" -p "${NGX_HTTPS_PORT:-443}:443" -p "${NGX_HTTPS_PORT:-443}:443/udp" \
        --add-host host.docker.internal:host-gateway \
        -v ngx-acme:/var/cache/nginx/acme -v "$conf":/etc/ngx \
        "$IMAGE" >/dev/null
    say "running container 'ngx' ($IMAGE). Apps on this machine: use host.docker.internal:PORT as the target."
    say "config: $conf/ngx.env   logs: docker logs -f ngx"
}

repo_debian() {
    if [ "$ID" = debian ] || [ "$ID" = ubuntu ]; then distro=$ID codename=$VERSION_CODENAME
    elif [ -n "${UBUNTU_CODENAME:-}" ]; then distro=ubuntu codename=$UBUNTU_CODENAME   # Mint, Pop!_OS, ...
    else distro=debian codename=$VERSION_CODENAME; fi
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl gnupg ca-certificates openssl >/dev/null
    curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor --yes -o /usr/share/keyrings/nginx-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/mainline/$distro $codename nginx" \
        > /etc/apt/sources.list.d/nginx.list
    printf 'Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n' > /etc/apt/preferences.d/99nginx
    apt-get update -qq
    apt-get install -y -qq nginx nginx-module-acme >/dev/null
}

repo_rhel() {
    case $ID in amzn) path=amzn/$VERSION_ID ;; *) path=centos/${VERSION_ID%%.*} ;; esac
    cat > /etc/yum.repos.d/nginx.repo <<EOF
[nginx-mainline]
name=nginx mainline repo
baseurl=https://nginx.org/packages/mainline/$path/\$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
EOF
    pm=$(command -v dnf || command -v yum)
    $pm install -y -q nginx nginx-module-acme openssl tar >/dev/null
}

install_native() {
    [ "$(id -u)" = 0 ] || die "native install needs root: run with sudo (or use --docker)"
    command -v systemctl >/dev/null && [ -d /run/systemd/system ] || die "native install needs systemd; use --docker"
    . /etc/os-release
    case "$ID ${ID_LIKE:-}" in
        fedora*) die "nginx.org has no Fedora packages; use --docker" ;;
        *debian*|*ubuntu*) say "installing nginx + ACME module from nginx.org ($ID)"; repo_debian ;;
        *rhel*|*centos*|*amzn*) say "installing nginx + ACME module from nginx.org ($ID)"; repo_rhel ;;
        *) die "unsupported distro '$ID'; use --docker" ;;
    esac

    # acme.sh: only used for wildcard certs (DNS-01); plain domains use nginx's own ACME module
    mkdir -p /opt/acme.sh /usr/local/lib/ngx /var/cache/nginx/acme
    curl -fsSL "https://github.com/acmesh-official/acme.sh/archive/refs/tags/$ACMESH.tar.gz" \
        | tar -xz -C /opt/acme.sh --strip-components=1 "acme.sh-$ACMESH/acme.sh" "acme.sh-$ACMESH/dnsapi"
    # root's: 40-sites.sh gives the ACME module its own module/ dir, the only part nginx's workers write

    fetch 40-sites.sh /usr/local/lib/ngx/40-sites.sh && chmod 755 /usr/local/lib/ngx/40-sites.sh
    fetch nginx.conf /tmp/ngx-nginx.conf
    if [ "$(cksum < /tmp/ngx-nginx.conf)" != "$(cksum < /etc/nginx/nginx.conf 2>/dev/null)" ]; then  # cksum: coreutils, always present (cmp isn't on minimal RHEL)
        [ -f /etc/nginx/nginx.conf ] && cp /etc/nginx/nginx.conf "/etc/nginx/nginx.conf.bak-$(date +%Y%m%d%H%M%S)"
        mv /tmp/ngx-nginx.conf /etc/nginx/nginx.conf
    else rm -f /tmp/ngx-nginx.conf; fi
    [ -f /etc/nginx/conf.d/default.conf ] && mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.disabled
    write_env /etc/ngx/ngx.env

    # generate config on every start/reload; reload = regenerate + nginx -t + zero-downtime HUP, keeping
    # the running config if the new one fails. ngx-apply.path reloads whenever ngx.env changes.
    mkdir -p /etc/systemd/system/nginx.service.d
    cat > /etc/systemd/system/nginx.service.d/ngx.conf <<'EOF'
[Service]
Environment=NGX_RENEW_LOOP=0
Restart=on-failure
RestartSec=2s
ExecStartPre=/usr/local/lib/ngx/40-sites.sh
ExecStartPre=/usr/sbin/nginx -t -q
ExecReload=
ExecReload=/usr/local/lib/ngx/40-sites.sh --apply
# first wildcard cert waits for DNS propagation
TimeoutStartSec=300
EOF
    cat > /etc/systemd/system/ngx-apply.path <<'EOF'
[Unit]
Description=ngx: apply /etc/ngx/ngx.env when it changes
[Path]
PathChanged=/etc/ngx/ngx.env
Unit=ngx-apply.service
[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/ngx-apply.service <<'EOF'
[Unit]
Description=ngx: regenerate and hot-reload nginx from /etc/ngx/ngx.env
[Service]
Type=oneshot
ExecStart=/usr/local/lib/ngx/40-sites.sh --apply
EOF
    cat > /etc/systemd/system/ngx-renew.service <<'EOF'
[Unit]
Description=ngx: renew wildcard (acme.sh) and local-CA certificates
[Service]
Type=oneshot
# "-": a failed wildcard renewal must not skip the local-CA renewals of the apply
ExecStart=-/opt/acme.sh/acme.sh --home /opt/acme.sh --config-home /var/cache/nginx/acme/dns --cron
ExecStart=/usr/local/lib/ngx/40-sites.sh --apply
EOF
    cat > /etc/systemd/system/ngx-renew.timer <<'EOF'
[Unit]
Description=ngx: daily wildcard certificate renewal check
[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable -q nginx ngx-renew.timer ngx-apply.path
    systemctl start ngx-renew.timer ngx-apply.path
    systemctl restart nginx || { journalctl -u nginx -n 30 --no-pager; die "nginx failed to start"; }
    say "nginx $(nginx -v 2>&1 | cut -d/ -f2) running with ngx config"
    say "config: /etc/ngx/ngx.env (applied on save)   logs: journalctl -u nginx -u ngx-apply, /var/log/nginx/"
}

case "${1:-}" in
    --docker) install_docker ;;
    "") if [ "$(uname -s)" = Linux ] && [ -d /run/systemd/system ] && [ -f /etc/os-release ]; then install_native; else install_docker; fi ;;
    *) die "usage: install.sh [--docker]" ;;
esac
