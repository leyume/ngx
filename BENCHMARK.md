# nginx vs Caddy vs Ferron — benchmark report

_Run 2026-11-17 on a MacBook (10 cores, 16 GB) inside a podman machine (libkrun VM, 5 vCPU, 6 GiB, arm64)._

| Server | Version | Image |
|---|---|---|
| nginx | 1.31.8 | `docker.io/library/nginx:alpine` |
| Caddy | 2.11.9 | `docker.io/library/caddy:2-alpine` |
| Ferron | 2.8.1 | `docker.io/ferronserver/ferron:2` |

## TL;DR

- **nginx is the fastest in every test except two.** It beats Caddy and Ferron by 3–5× on small files, is fastest on large files, and stays under ~25 MiB of RAM. (In the HTTP/1.1 tests it didn't even use all of its CPU, so the load generator, not nginx, was the limit.)
- **Caddy is consistent but slow**, at about 30–36k req/s on HTTP/1.1. **Turning on HTTP/2 roughly halves its speed**, and its HTTP/2 reverse proxy collapses to 4.8k req/s, with the slowest 1% of requests taking about 220 ms.
- **Ferron is the strongest proxy after nginx.** It ties nginx as an HTTP/2 proxy and is the fastest at setting up new TLS connections. But it **serves large files very slowly** (about 2k req/s for 100 KB) and keeps about 55–120 MiB of RAM after load stops.
- **Where the certificate comes from (Let's Encrypt-style ACME vs self-signed) doesn't affect speed.** Results stay within ±10%.

## Method

- **Isolation.** I tested one server at a time. Each server container was pinned to **2 cores (cpuset 0,1)** with a **512 MB** memory limit. The load generator **oha** was pinned to cores 2,3. The reverse-proxy backend, a minimal nginx returning a 19-byte body, ran on core 4. Everything was on a private podman network with no host ports.
- **Content.** A 1 KB and a 100 KB static file, served from a podman volume on the VM's disk (not a host mount), plus `/proxy` going to the backend.
- **Server config.** Defaults apart from what the test needed: access logs off, no compression (oha doesn't send `Accept-Encoding`). nginx had `sendfile on`, upstream keep-alive and `worker_processes auto`.
- **Runs.** A 3 s warm-up, then a 15 s measured run. CPU and memory were sampled from `podman stats` about once a second. "CPU %" is out of a possible 200% (2 cores).
- **"Errors".** The only errors were requests still in flight when the 15 s window closed, at most one per open connection.

## 1. Plain HTTP/1.1

| Test (req/s · p99) | nginx | Caddy | Ferron |
|---|---|---|---|
| 1 KB, 100 conn | **145k** · 1.7 ms | 33k · 11.8 ms | 31k · 5.4 ms |
| 1 KB, 1000 conn | **136k** · 18.8 ms | 33k · 61.6 ms | 29k · 61.3 ms |
| 100 KB, 100 conn | **74k** · 3.1 ms | 14k · 30 ms | ⚠️ 2.1k · 73 ms |
| Reverse proxy, 100 conn | **122k** · 2.5 ms | 12k · 54 ms | 50k · 3.8 ms |
| CPU used (of 200%) | 106–127% | 120–151% | 126–163% |
| req/s per 1% CPU (1 KB) | **~1,370** | ~270 | ~240 |
| RAM idle | 13.9 MiB | 13.6 MiB | **2.4 MiB** |
| RAM peak | **23 MiB** | 81 MiB | 97 MiB |
| RAM after load | **15 MiB** | 61 MiB | 93 MiB |

I re-ran Ferron's 100 KB result separately and it came out the same: 1.0k req/s at 10 connections and 2.1k at 100. This could be a slow file-read path in Ferron 2.8.1; I didn't confirm the cause.

## 2. HTTPS, HTTP/1.1, self-signed certificate

TLS 1.3 with a self-signed ECDSA P-256 certificate (no intermediate). Each cell shows HTTPS with the plain-HTTP figure in brackets.

| Test (req/s · p99) | nginx | Caddy | Ferron |
|---|---|---|---|
| 1 KB, 100 conn | **112k** · 2.2 ms (145k) | 36k · 10.4 ms (33k) | 26k · 10.6 ms (31k) |
| 1 KB, 1000 conn | **94k** · 21 ms (136k) | 32k · 85 ms (33k) | 23k · 133 ms (29k) |
| 100 KB, 100 conn | **19.0k** · 9.6 ms (74k) | 17.2k · 18 ms (14k) | ⚠️ 1.9k · 112 ms (2.1k) |
| Reverse proxy, 100 conn | **90k** · 3.2 ms (122k) | 12.6k · 43 ms (12k) | 42k · 6.4 ms (50k) |
| New TLS handshake per request (no keep-alive, 50 conn) | 5.4k · 13 ms | 4.4k · 31 ms | **6.4k** · 29 ms |
| RAM idle → peak | **14 → 56 MiB** | 50 → 134 MiB | 20 → 126 MiB |
| RAM after load | **14 MiB** | 74 MiB | 118 MiB |

- **TLS slows nginx the most:** about 25% on small files and 75% on 100 KB files. Over HTTPS it can't use `sendfile` to send files straight from disk, because every byte has to be encrypted first.
- **Caddy barely slows down with TLS**, so encryption isn't its bottleneck; its own request handling is.
- **The handshake row is probably limited by the load generator** (no server went above ~160% CPU). Treat it as a rough ranking only.

## 3. HTTPS with Let's Encrypt-style (ACME) certificates, HTTP/1.1 and HTTP/2

Real Let's Encrypt can't reach a private network, so I used **[Pebble](https://github.com/letsencrypt/pebble)**, Let's Encrypt's own ACME test server. Each server got its certificate automatically, and Pebble really checked each challenge: it looked up `*.bench.test` through podman's DNS and connected back on port 80/443.

| Server | How it got the certificate | Time to issue |
|---|---|---|
| nginx | Official `ngx_http_acme_module`, which is **already in `nginx:alpine`** (no certbot), http-01 challenge | 3–5 s |
| Caddy | Built-in ACME (`acme_ca` + `acme_ca_root`) | 3 s |
| Ferron | Built-in ACME (`auto_tls_directory`), tls-alpn-01 challenge | 2–4 s |

All three ended up with the same chain, shaped like a real Let's Encrypt one: an ECDSA P-256 leaf certificate (name in the SAN only, empty subject) plus an ECDSA P-256 intermediate.

### HTTP/2 (req/s · p99)

"Streams" means requests in flight at once: 100 streams = 10 connections × 10 streams each, 1000 = 100 × 10.

| Test | nginx | Caddy | Ferron |
|---|---|---|---|
| 1 KB, 100 streams | **106k** · 2.4 ms | 17k · 15 ms | 29k · 9.7 ms |
| 1 KB, 1000 streams | **114k** · 17 ms | 16k · 231 ms | 35k · 56 ms |
| 100 KB, 100 streams | **17k** · 10 ms | 7.3k · 35 ms | ⚠️ 2.0k · 76 ms |
| Reverse proxy, 100 streams | **51k** · 3.9 ms | 4.8k · 221 ms | **52k** · 5.2 ms |
| RAM idle → peak | **12 → 19 MiB** | 12 → 59 MiB | **3** → 56 MiB |
| RAM after load | **17 MiB** | 52 MiB | 55 MiB |

### HTTP/1.1: ACME certificate vs self-signed (req/s)

| Test | nginx | Caddy | Ferron |
|---|---|---|---|
| 1 KB, 100 conn | 109k (was 112k) | 32k (was 36k) | 22k (was 26k) |
| New TLS handshake per request | 5.3k (was 5.4k) | 4.7k (was 4.4k) | **7.2k** (was 6.4k) |

- **The certificate source doesn't matter for speed.** Every difference is within normal run-to-run variation.
- **nginx performs about the same on HTTP/2 as on HTTP/1.1** for files. As a proxy it roughly halves (90k → 51k), because each client stream becomes its own request to the backend.
- **Caddy's HTTP/2 path is its weakest point:** it drops to about half its HTTP/1.1 speed, and the proxy falls to 4.8k req/s with a 221 ms p99.
- **Ferron is the only one that gets faster on HTTP/2** (22k → 29–35k), and as an HTTP/2 proxy it ties nginx.
- I dropped one test, "new handshake per request over HTTP/2", because oha ignores `--disable-keepalive` when `--http2` is on, so it didn't measure handshakes at all.

## Caveats

- This ran on a podman VM on macOS, not bare-metal Linux. Absolute numbers will be higher on real hardware. The rankings are the useful part.
- In the HTTP/1.1 tests, nginx never used its full 2 cores, so its real maximum is higher than shown.
- Every server ran with its default settings, apart from what's listed in Method. Tuning would narrow the gaps.
- Each test ran once for 15 s. Treat differences under about 10% as noise.
- HTTP/3 wasn't tested.

## Takeaways for choosing a front proxy

- **nginx** is the fastest choice and uses the least memory. With `ngx_http_acme_module` it now gets certificates automatically too. What it lacks is a runtime admin API: config changes mean rewriting files and running `nginx -s reload`.
- **Caddy** is the easiest to run (automatic HTTPS, JSON admin API). If you stay on it, its HTTP/2 proxy is the slow spot. Limiting proxied sites to HTTP/1.1 recovered about 2.5× proxy speed in these tests (12.6k vs 4.8k req/s).
- **Ferron** looks promising as an HTTP/2 proxy and at handling new TLS connections. Its slow large-file serving and the memory it keeps after load make it the riskiest choice for now.

## Reproducing

The harness (bash + podman + oha) has three scripts:
- `run.sh` runs the plain HTTP tests; `SCHEME=https bash run.sh` runs the self-signed HTTPS tests.
- `acme.sh` starts Pebble, gets a certificate for each server, then runs the HTTP/2 + ACME tests (`acme.sh issue` only does the certificate step).
- `summary.py <results-dir>` prints the summary table.
