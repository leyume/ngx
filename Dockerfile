# ponytail: nginx ships a native ACME module (auto-issue + auto-renew), so no certbot/cron.
FROM nginx:mainline-alpine

# acme.sh = DNS-01 for wildcards only (the native module has no DNS-01); ~150 DNS providers built in
# coreutils: GNU date, so acme.sh can read cert expiry (busybox date cannot) and schedule renewals from it
ARG ACMESH=3.1.6
RUN rm /etc/nginx/conf.d/default.conf \
 && mkdir -p /var/cache/nginx/acme /opt/acme.sh && chown nginx:nginx /var/cache/nginx/acme \
 && apk add --no-cache openssl coreutils \
 && curl -fsSL https://github.com/acmesh-official/acme.sh/archive/refs/tags/$ACMESH.tar.gz \
    | tar -xz -C /opt/acme.sh --strip-components=1 acme.sh-$ACMESH/acme.sh acme.sh-$ACMESH/dnsapi

COPY nginx.conf /etc/nginx/nginx.conf
COPY 40-sites.sh /docker-entrypoint.d/

# official entrypoint exports $NGINX_LOCAL_RESOLVERS from /etc/resolv.conf
ENV NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1
VOLUME /var/cache/nginx/acme
EXPOSE 80 443 443/udp
# unhealthy when nginx is down or not answering; also restarts the config watcher if it ever died
HEALTHCHECK --interval=30s --timeout=10s --start-period=5m CMD ["/docker-entrypoint.d/40-sites.sh", "--health"]
