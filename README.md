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
| apply changes | save `ngx.env`: applied within a second, zero downtime | same |
| app on the same machine | `127.0.0.1:3000` | `host.docker.internal:3000` |
| wildcard + local cert renewals | `ngx-renew.timer` (daily) | built-in loop (12h) |

- Re-running the installer is safe: it keeps `ngx.env` and backs up an existing `nginx.conf` once.
- In Docker mode, if ports 80/443 are busy on a dev machine, set `NGX_HTTP_PORT` / `NGX_HTTPS_PORT`.

## Docker

```sh
docker run -d -p 80:80 -p 443:443 -p 443:443/udp -v ngx-acme:/var/cache/nginx/acme \
  -e SITES="example.com=app:3000" leyume/ngx
```

Or use `compose.yml`.

`SITES` takes space-separated `domain[,domain][/path]=target` entries:

| target | |
|---|---|
| `/srv/www` | static files. Unknown paths fall back to `/index.html` (single-page apps), `/dir` redirects to `/dir/`, and dotfiles (`.git`, `.env`, `.DS_Store`) answer 404 |
| `app:3000`, `http://app:3000/prefix` | reverse proxy. A `/prefix` goes in front of the whole request path |
| `https://origin.example.com` | reverse proxy to TLS, certificate verified against the system CAs |
| `https+insecure://app:8443` | same without verification, for self-signed backends |
| `fastcgi://php:9000/var/www` | PHP: files from the docroot, `*.php` to php-fpm, WordPress-style permalinks. Mount the docroot at the same path in both containers |

`app.example.com/api*=api:8080` sends only that path prefix (or, without `*`, that exact path) to another proxy target; `app.example.com` needs its own entry too.

**Live reload.** Edit `/etc/ngx/ngx.env` (mount the directory, not the file, and read-write): within a second the config is regenerated, checked with `nginx -t` and hot-reloaded. A rejected change leaves the running config in place. Programs should write it atomically (a temp file, then rename); ngx also waits for the file to stop changing, so a half-saved file is never applied. Either way `ngx.status` next to it gets `<sha256 of ngx.env> ok` or `... error: <why>`, so a program writing ngx.env can tell when its change is live.

**Local domains.** `localhost`, `*.localhost`, `.test`, `.local`, `.internal`, `.home.arpa`, and anything listed in `TLS_INTERNAL`, get certificates from a local CA: offline, no DNS, wildcards included. The CA is generated once at `/var/cache/nginx/acme/local/ca.crt` (trust it to remove browser warnings), or bring one your machines already trust with `LOCAL_CA_CERT` / `LOCAL_CA_KEY` (Caddy's root works: `~/Library/Application Support/Caddy/pki/authorities/local/root.{crt,key}`).

Included:
- Let's Encrypt certificates issued and renewed automatically (HTTP-01). Keep `/var/cache/nginx/acme` on a volume. The image builds the module with `acme/parallel.patch`, so up to 10 orders run at once: 10 new domains take about 5s instead of about 35s, and one failing domain doesn't hold up the others.
- Wildcards: `example.com,*.example.com=app:3000` goes through DNS-01 via [acme.sh](https://github.com/acmesh-official/acme.sh/wiki/dnsapi), the same approach as Caddy's DNS plugins.
  Set `DNS_PROVIDER` plus that provider's credentials, e.g. Cloudflare: `DNS_PROVIDER=dns_cf CF_Token=...`.
  The first certificate is issued before nginx starts. Renewal is checked every 12h, followed by a hot reload.
- HTTP redirects to HTTPS, HSTS, HTTP/2 and HTTP/3 (publish `443/udp`)
- Proxying with WebSocket upgrade and `X-Forwarded-*` / `X-Real-IP` headers. A client-sent `X-Forwarded-For` is replaced, not trusted
- Caddy-like proxy limits: no upload size limit, 1h read timeout (long polls, idle websockets), streamed responses (SSE), 32 KB request headers, 64 KB upstream headers
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
| `TLS_INTERNAL` | extra domains served from the local CA (`"a.dev b.dev"`, or `*` for all) |
| `LOCAL_CA_CERT`, `LOCAL_CA_KEY` | generated CA. Set both to sign with your own |
| `LOCAL_CERT_DAYS` | `90`; renewed with a third left |
| `HTTPS_REDIRECT` | `on`. `off` also serves every site over plain HTTP on :80 |
| `IPV6` | `on`: also listen on `[::]` when the host has IPv6. `off` listens on IPv4 only |
| `HTTPS_PORT` | `443`. Where the :80 redirect points when 443 is published elsewhere |

DNS for each domain must point at the host, and ports 80 and 443 must be reachable.

Test: `sh test/run.sh` issues real certificates against Pebble, Let's Encrypt's test CA, and checks every feature above end to end.
