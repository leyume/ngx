#!/bin/sh
# Boots pebble + mock DNS + app + web; checks native + wildcard certs, proxy, static, redirect, unknown host, HSTS, renewal.
set -eu
cd "$(dirname "$0")"
trap 'docker compose down -v >/dev/null 2>&1' EXIT
docker compose up -d --build --quiet-pull
r() { docker compose exec -T web "$@"; }
get() { h=$1; shift; r curl -sfk --resolve "$h:443:127.0.0.1" "https://$h/" "$@"; }

# ponytail: first ACME attempt can race pebble's startup; the module retries after ~1 min
for i in $(seq 60); do
  get site.test >/dev/null 2>&1 && get files.test >/dev/null 2>&1 && break
  sleep 2
done
r curl -svk --resolve site.test:443:127.0.0.1 https://site.test/ 2>&1 | grep 'issuer: CN=Pebble'
get site.test  | grep -q '^Hostname:';                                       echo "ok proxy"
get files.test | grep -q 'Welcome to nginx';                                 echo "ok static"
r curl -sI http://localhost/x -H 'Host: site.test' | grep -q 'Location: https://site.test/x'; echo "ok redirect"
if get nope.test >/dev/null 2>&1; then exit 1; fi;                         echo "ok unknown host rejected"
get site.test -I | grep -qi 'strict-transport';                              echo "ok hsts"
get any.wild.test | grep -q '^Hostname:';                                 echo "ok wildcard"
serial() { r curl -svk --resolve any.wild.test:443:127.0.0.1 https://any.wild.test/ 2>&1 | grep -E 'serial|start date'; }
before=$(serial)
r /opt/acme.sh/acme.sh --home /opt/acme.sh --config-home /var/cache/nginx/acme/dns --renew -d wild.test --force >/dev/null
sleep 2
[ "$(serial)" != "$before" ];                                                 echo "ok wildcard renew + reload"
echo PASS
