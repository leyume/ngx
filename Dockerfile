# nginx's native ACME module (auto-issue + auto-renew, no certbot/cron), rebuilt with acme/parallel.patch:
# upstream issues certificates one at a time (~3s each); patched, up to 10 run at once, like Caddy.
FROM nginx:mainline-alpine AS acme
ARG ACME=v0.4.2
RUN apk add --no-cache build-base cargo clang-dev git linux-headers openssl-dev pcre2-dev pkgconf zlib-dev \
 && cd /tmp && curl -fsSL https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz | tar -xz \
 && git clone -q --depth 1 -b $ACME https://github.com/nginx/nginx-acme \
 && cd nginx-acme && cargo fetch -q
COPY acme/parallel.patch /tmp/
# same nginx version and system OpenSSL as the final image, --with-compat: binary compatible with it
RUN cd /tmp/nginx-acme && git apply /tmp/parallel.patch \
 && cd /tmp/nginx-$NGINX_VERSION && ./configure --with-compat --with-http_ssl_module --add-dynamic-module=../nginx-acme \
 && make modules

FROM nginx:mainline-alpine
COPY --from=acme /tmp/nginx-$NGINX_VERSION/objs/ngx_http_acme_module.so /usr/lib/nginx/modules/

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
