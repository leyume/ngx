#!/bin/sh
# Boots pebble + mock DNS + apps + web, then checks every feature; prints PASS or stops at the first failure.
set -eu
cd "$(dirname "$0")"
# fixtures: created here because a .git directory can't be committed inside the repo
rm -rf run; mkdir -p run/www/docs run/www/.git run/php/wp-admin run/ngx
echo '<p>spa index</p>' > run/www/index.html
echo '<p>docs index</p>' > run/www/docs/index.html
echo 'secret' > run/www/.git/config; echo 'SECRET=1' > run/www/.env
echo '<?php echo "php ok ", $_SERVER["REQUEST_URI"], " pi=", $_SERVER["PATH_INFO"] ?? "";' > run/php/index.php
echo '<?php echo "admin";' > run/php/wp-admin/index.php
echo '<?php echo strlen(file_get_contents("php://input"));' > run/php/upload.php
[ -n "${KEEP:-}" ] || trap 'docker compose down -v >/dev/null 2>&1; rm -rf run' EXIT
docker compose up -d --build --quiet-pull
r() { docker compose exec -T web "$@"; }
get() { h=$1 p=$2; shift 2; r curl -sfk --resolve "$h:443:127.0.0.1" "https://$h$p" "$@"; }
code() { r curl -sk -o /dev/null -w '%{http_code}' --resolve "$1:443:127.0.0.1" "https://$1$2"; }
ok() { echo "ok $*"; }

# ponytail: first ACME attempt can race pebble's startup; the module retries after ~1 min
for i in $(seq 60); do
  get site.example / >/dev/null 2>&1 && get files.example / >/dev/null 2>&1 && break
  sleep 2
done
r curl -svk --resolve site.example:443:127.0.0.1 https://site.example/ 2>&1 | grep -q 'issuer: CN=Pebble'; ok "acme cert"
get site.example / | grep -q '^Hostname:';                                     ok "proxy"
get files.example / | grep -q 'Welcome to nginx';                              ok "static"
r curl -sI http://localhost/x -H 'Host: site.example' | grep -q 'Location: https://site.example/x'; ok "redirect"
if get nope.example / >/dev/null 2>&1; then exit 1; fi;                       ok "unknown host rejected"
get site.example / -I | grep -qi 'strict-transport';                           ok "hsts"
get any.wild.example / | grep -q '^Hostname:';                                 ok "wildcard"
serial() { r curl -svk --resolve any.wild.example:443:127.0.0.1 https://any.wild.example/ 2>&1 | grep -E 'serial|start date'; }
before=$(serial)
r /opt/acme.sh/acme.sh --home /opt/acme.sh --config-home /var/cache/nginx/acme/dns --renew -d wild.example --force >/dev/null
sleep 2
[ "$(serial)" != "$before" ];                                                  ok "wildcard renew + reload"

# local CA: .test is served from it, and the cert verifies against that CA (no -k)
r curl -sf --cacert /var/cache/nginx/acme/local/ca.crt --resolve local.test:443:127.0.0.1 https://local.test/ | grep -q '^Hostname:'; ok "local CA"
get spa.test /deep/link | grep -q 'spa index';                                 ok "spa fallback"
[ "$(code spa.test /.git/config)" = 404 ] && [ "$(code spa.test /.env)" = 404 ]; ok "dotfiles hidden"
r curl -skI --resolve spa.test:443:127.0.0.1 https://spa.test/docs | grep -qi '^location: /docs/'; ok "dir redirect"
get spa.test /docs/ | grep -q 'docs index';                                    ok "dir index"
get php.test /index.php/extra | grep -q 'php ok /index.php/extra pi=/extra';   ok "php + path info"
get php.test /some/permalink | grep -q 'php ok /some/permalink';               ok "php permalink"
r curl -skI --resolve php.test:443:127.0.0.1 https://php.test/wp-admin | grep -qi '^location: /wp-admin/'; ok "php dir redirect"
[ "$(code php.test /.env)" = 404 ];                                            ok "php dotfiles hidden"
app2=$(docker compose ps -q app2 | cut -c1-12)
get paths.test /exact | grep -q "Hostname: $app2";                             ok "exact path route"
get paths.test /exact/more | grep -vq "Hostname: $app2";                       ok "exact means exact"
get paths.test /pre/x?q=1 | grep -q "GET /v1/pre/x?q=1";                       ok "prefix path route + upstream prefix"
[ "$(code verify.test /dir)" = 502 ];                                          ok "https upstream verified (untrusted cert refused)"
get insecure.test /dir | grep -q newNonce;                                        ok "https+insecure upstream"
get site.example / -H 'X-Forwarded-For: 6.6.6.6' | grep -q 'X-Forwarded-For: 6.6.6.6' && exit 1; ok "client X-Forwarded-For replaced"
ws=$(r curl -sk --http1.1 --max-time 3 -o /dev/null -w '%{http_code}' --resolve site.example:443:127.0.0.1 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' https://site.example/echo || :)
[ "$ws" = 101 ];                                                               ok "websocket upgrade"
r sh -c 'head -c 5000000 /dev/zero > /tmp/big'
[ "$(get php.test /upload.php --max-time 30 --data-binary @/tmp/big)" = 5000000 ];  ok "5 MB upload"

# live reload: ngx.env changes apply within seconds; a bad one is reported and the old config keeps serving
sha() { sha256sum run/ngx/ngx.env | cut -d' ' -f1; }
wait_status() { for i in $(seq 60); do grep -q "^$(sha) " run/ngx/ngx.status 2>/dev/null && break; sleep 1; done; cat run/ngx/ngx.status; }
echo "SITES='new.test=app:80'" > run/ngx/ngx.env
wait_status | grep -q ' ok$';                                                  ok "reload reported"
get new.test / | grep -q '^Hostname:';                                         ok "new site live"
if get site.example / >/dev/null 2>&1; then exit 1; fi;                       ok "removed site gone"
# fast: an atomic write is live in well under a second
echo "SITES='new.test=app:80 fast.test=app2:80'" > run/ngx/ngx.env.tmp; h=$(sha256sum run/ngx/ngx.env.tmp | cut -d' ' -f1)
t0=$(date +%s%N); mv run/ngx/ngx.env.tmp run/ngx/ngx.env
until grep -q "^$h ok" run/ngx/ngx.status 2>/dev/null; do sleep 0.01; [ $(( ($(date +%s%N)-t0)/1000000 )) -lt 5000 ] || break; done
ms=$(( ($(date +%s%N)-t0)/1000000 )); [ $ms -lt 1000 ];                         ok "change applied in ${ms} ms"
# a missing ngx.env is never read as "no sites"
mv run/ngx/ngx.env run/ngx/ngx.env.away; sleep 1
get fast.test / | grep -q "Hostname: $app2";                                   ok "missing ngx.env leaves sites up"
mv run/ngx/ngx.env.away run/ngx/ngx.env
echo "SITES='new.test=app:80 bad=entry=x'" > run/ngx/ngx.env
wait_status | grep -q ' error: .*bad SITES entry';                             ok "bad config reported"
get new.test / | grep -q '^Hostname:';                                         ok "previous config still served"

# --- resilience ---------------------------------------------------------------
# a DNS provider outage leaves out only the wildcard site that needs it; the rest of the change applies
docker compose stop challtestsrv >/dev/null 2>&1
echo "SITES='new.test=app:80 other.test=app2:80 down.example,*.down.example=app:80'" > run/ngx/ngx.env
st=$(wait_status)
echo "$st" | head -1 | grep -q ' ok$' && echo "$st" | grep -q 'down.example failed; site left out'; ok "dns outage: warning, only that site left out"
get other.test / | grep -q "Hostname: $app2";                                  ok "rest of the change applied"
docker compose start challtestsrv >/dev/null 2>&1

# the watcher dies -> the healthcheck brings it back, and it catches up on what it missed
r pkill -f '40-sites.sh --watch'
echo "SITES='new.test=app2:80'" > run/ngx/ngx.env
sleep 3; if grep -q "^$(sha) " run/ngx/ngx.status; then exit 1; fi             # nothing applies while it's dead
r /docker-entrypoint.d/40-sites.sh --health | grep -q 'restarted';             ok "health restarts a dead watcher"
wait_status | grep -q ' ok$' && get new.test / | grep -q "Hostname: $app2";    ok "revived watcher caught up"

# boot with a broken ngx.env: nginx still starts, on the last config that worked
echo "SITES='new.test=app:80 bad=entry=x'" > run/ngx/ngx.env
docker compose restart web >/dev/null 2>&1
up() { for i in $(seq 30); do r /docker-entrypoint.d/40-sites.sh --health >/dev/null 2>&1 && return; sleep 1; done; return 1; }
up;                                                                            ok "broken config at boot: nginx up"
get new.test / | grep -q "Hostname: $app2";                                    ok "  ...serving the last config that worked"
wait_status | grep -q ' error: .*bad SITES entry';                             ok "  ...and the error is reported"
# no good config to fall back to either: nginx starts with no sites, and the next fix applies
r rm -f /var/cache/nginx/acme/last-good.conf /etc/nginx/conf.d/sites.conf
docker compose restart web >/dev/null 2>&1
up;                                                                            ok "broken config, nothing to fall back to: nginx up"
echo "SITES='new.test=app:80'" > run/ngx/ngx.env
wait_status | grep -q ' ok$' && get new.test / | grep -q '^Hostname:';         ok "  ...and a fixed config applies"
# a backend that never answers fails in ~5s (nginx's default would hang for 60s)
echo "SITES='new.test=app:80 dead.test=10.255.255.1:80'" > run/ngx/ngx.env
wait_status | grep -q ' ok$'
t=$(r curl -sk -o /dev/null -w '%{http_code} %{time_total}' --max-time 30 --resolve dead.test:443:127.0.0.1 https://dead.test/)
case $t in 50[24]\ [0-7].*) ;; *) echo "dead backend took: $t"; exit 1 ;; esac;  ok "dead backend fails fast ($t s)"
echo PASS
