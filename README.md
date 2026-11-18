# ngx

The official `nginx:mainline-alpine` image plus one entrypoint script. HTTPS is configured from a single env var, the way Caddy does it.
Certificates are issued and renewed by nginx's own `ngx_http_acme_module`, with no certbot and no cron.

```yaml
environment:
  SITES: "example.com,www.example.com=app:3000 static.example.com=/srv/www"
  ACME_EMAIL: you@example.com   # optional
```

## Install

On a Linux server with systemd (Debian, Ubuntu, RHEL/Rocky/Alma, Amazon Linux), the installer sets up native nginx from nginx.org's packages. On macOS or anything else, it runs the Docker image `leyume/ngx`:

```sh
curl -fsSL https://raw.githubusercontent.com/leyume/ngx/main/install.sh \
  | sudo SITES="example.com=127.0.0.1:3000" ACME_EMAIL=you@example.com sh
```

| | native (Linux + systemd) | `--docker` (macOS, others) |
|---|---|---|
| config | `/etc/ngx/ngx.env` | `~/.ngx/ngx.env` |
| apply changes | `sudo systemctl reload nginx` (zero downtime) | `docker restart ngx` |
| app on the same machine | `127.0.0.1:3000` | `host.docker.internal:3000` |
| wildcard renewals | `ngx-renew.timer` (daily) | built-in loop |

- Re-running the installer is safe: it keeps `ngx.env` and backs up an existing `nginx.conf` once.
- In Docker mode, if ports 80/443 are busy on a dev machine, set `NGX_HTTP_PORT` / `NGX_HTTPS_PORT`.

## Docker

```sh
docker run -d -p 80:80 -p 443:443 -p 443:443/udp -v ngx-acme:/var/cache/nginx/acme \
  -e SITES="example.com=app:3000" leyume/ngx
```

Or use `compose.yml`.

`SITES` takes space-separated `domain[,domain]=target` entries. A target starting with `/` is served as static files. `host:port` or `http(s)://url` is reverse-proxied.

Included:
- Let's Encrypt certificates issued and renewed automatically (HTTP-01). Keep `/var/cache/nginx/acme` on a volume.
- Wildcards: `example.com,*.example.com=app:3000` goes through DNS-01 via [acme.sh](https://github.com/acmesh-official/acme.sh/wiki/dnsapi), the same approach as Caddy's DNS plugins.
  Set `DNS_PROVIDER` plus that provider's credentials, e.g. Cloudflare: `DNS_PROVIDER=dns_cf CF_Token=...`.
  The first certificate is issued before nginx starts. Renewal is checked every 12h, followed by a hot reload.
- HTTP redirects to HTTPS, HSTS, HTTP/2 and HTTP/3 (publish `443/udp`)
- Proxying with WebSocket upgrade and `X-Forwarded-*` / `X-Real-IP` headers
- Upstreams resolved per request, so nginx boots even when an app is down
- gzip and `server_tokens off`
- Performance tuning, which matches or beats a hand-tuned raw nginx:
  - Access log batched into 4 KB writes instead of one `write()` per request to the Docker log pipe. That alone was worth +70% req/s on small files.
  - `open_file_cache` for static files
  - TLS session cache, so returning visitors skip the full handshake
  - `worker_connections 8192`
  - kTLS, which lets `sendfile` work over HTTPS for large files. It needs `modprobe tls` on the Linux host; persist it with `echo tls > /etc/modules-load.d/tls.conf`. Without the module it silently falls back to normal TLS.
- TLS handshake rejected for unknown hostnames, so no certificate leaks to scanners
- Escape hatch: anything in `/etc/nginx/conf.d/*.conf` or `/etc/nginx/templates/*.template` (envsubst) is still loaded

| env | default |
|---|---|
| `SITES` | unset: script does nothing, bring your own conf |
| `ACME_EMAIL` | none |
| `ACME_URL` | Let's Encrypt production. Staging: `https://acme-staging-v02.api.letsencrypt.org/directory` |
| `ACME_CA` | CA file for a private ACME server (step-ca, pebble) |
| `DNS_PROVIDER` | required for wildcard entries: acme.sh hook name (`dns_cf`, `dns_route53`, `dns_gd`, …) |
| `DNS_SLEEP` | unset: acme.sh checks propagation over public DoH. Set to a number of seconds for a fixed wait instead |

DNS for each domain must point at the host, and ports 80 and 443 must be reachable.

Test: `sh test/run.sh` issues real certificates against Pebble, Let's Encrypt's test CA.
