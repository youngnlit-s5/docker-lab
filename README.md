# docker-lab

A small, self-contained Docker Compose stand that mirrors how I run internal web
services in a homelab: **one nginx reverse proxy in front, TLS everywhere, a private
registry, a status page, and automated backups** of the stateful volumes.

Everything is reachable through a single entry point (nginx). Only ports 80/443 are
published to the host — the application containers stay on an internal bridge network.

![architecture](docs/architecture.svg)

## Services

| Service | Image | Role | URL |
|---|---|---|---|
| `proxy` | `nginx:1.27-alpine` | Reverse proxy, TLS termination, `/healthz` | `:80`, `:443` |
| `kuma` | `louislam/uptime-kuma:1` | Uptime / status monitoring | `https://status.lab.local` |
| `registry` | `registry:2` | Private Docker registry (basic-auth) | `https://registry.lab.local` |
| `backup` | `alpine:3.20` | Nightly `tar.gz` of named volumes + retention prune | — |

## Layout

```
docker-lab/
├── docker-compose.yml
├── Makefile              # certs / auth / up / down / logs helpers
├── .env.example
├── nginx/
│   └── conf.d/
│       └── default.conf  # proxy + two vhosts (status, registry)
├── backup/
│   └── backup.sh         # loop-based nightly backup with prune
└── docs/
    ├── architecture.svg
    └── RUN.md            # step-by-step: install docker, run, screenshot
```

## Setup

```bash
cp .env.example .env
make certs      # self-signed cert (status.lab.local + registry.lab.local)
make auth       # registry basic-auth (ilija-s / change-me)
echo "127.0.0.1 status.lab.local registry.lab.local" | sudo tee -a /etc/hosts
make up         # docker compose up -d
make ps         # all services should report (healthy)
```

See [`docs/RUN.md`](docs/RUN.md) for the full walkthrough including Docker install.

## Verify

```bash
curl -s http://localhost/healthz            # -> ok
docker login registry.lab.local             # ilija-s / change-me
docker tag alpine:3.20 registry.lab.local/alpine:3.20
docker push registry.lab.local/alpine:3.20
```

## Backups

The `backup` container archives `kuma-data` and `registry-data` once every `INTERVAL`
seconds (24h by default) into `backup/out/*.tar.gz` and prunes anything older than
`RETENTION_DAYS`. Run a one-off with `make backup`.

## Notes

- Certificates and `backup/out/` are git-ignored — the repo ships configuration only.
- The same layout scales to a multi-host setup, which is what
  [`ansible-lab`](https://github.com/youngnlit-s5/ansible-lab) provisions automatically.

---

# Deployment log

Detailed notes on standing this up: where I started, which bugs only showed up on a
real run (rather than by reading the config), and one genuinely confusing networking
case that looked like a problem with the stand itself but had nothing to do with
Docker at all.

## 1. Starting point

The box was a plain Linux desktop (Ubuntu 24.04, systemd), not a disposable sandbox,
so the first step was checking what was already there:

```bash
uname -a
cat /etc/os-release
docker --version
```

Docker Engine was completely absent — no daemon, no CLI, no compose plugin. Installed
everything from the official `download.docker.com` repo (apt repo, GPG key,
`docker-ce` + `docker-ce-cli` + `containerd.io` + `docker-compose-plugin`), then
started and enabled the service:

```bash
systemctl start docker
systemctl enable docker
docker --version && docker compose version
```

Ended up with **Docker 29.6.2** and **Docker Compose v5.3.1**. The only hiccup was one
of the system's apt mirrors being unreachable over the network, but Docker's own
official repo resolved and worked fine, so it didn't affect the install.

![docker version](docs/screenshots/docker-version.png)

## 2. Preparing the stand

Next, following `Setup`: copy `.env`, generate a self-signed cert and htpasswd for the
registry, and add the stand's domains to `/etc/hosts`:

```bash
cp .env.example .env
make certs
make auth
echo "127.0.0.1 status.lab.local registry.lab.local" >> /etc/hosts
```

`make certs` runs `openssl req -x509` and drops `lab.crt` / `lab.key` into
`nginx/certs/`, with a SAN covering both domains (`status.lab.local`,
`registry.lab.local`) at once. `make auth` spins up a throwaway
`httpd:2.4-alpine` container to generate the registry's `htpasswd` file, so there's
no need to install `apache2-utils` on the host.

## 3. First boot: two services came up `unhealthy`

```bash
docker compose config -q && echo "compose OK"
docker compose up -d
```

All four images pulled and started, but a couple of minutes in, `docker compose ps`
showed:

```
NAME       STATUS
kuma       Up ... (healthy)
proxy      Up ... (unhealthy)
registry   Up ... (unhealthy)
```

Both services were actually answering requests fine — it was the healthchecks
themselves that were broken, not the services. Dug into each separately.

**Bug #1 — `proxy`.** The healthcheck in `docker-compose.yml` was written as
`wget -qO- http://localhost/healthz`. Checked it by hand from inside the container:

```bash
docker exec proxy wget -qO- http://localhost/healthz
# wget: can't connect to remote host: Connection refused
docker exec proxy wget -qO- http://127.0.0.1/healthz
# ok
docker exec proxy cat /etc/hosts
# ::1  localhost ip6-localhost ip6-loopback
# 127.0.0.1 localhost
```

Inside the container, `/etc/hosts` resolves `localhost` to `::1` before
`127.0.0.1`, while the nginx config only binds `0.0.0.0` (plain IPv4, no `[::]`
listener). So the healthcheck was trying to reach nginx over IPv6, where nothing was
listening, and failing with "connection refused" — even though a real request over
IPv4 (from outside, through the published port) worked correctly the whole time. A
classic dual-stack trap: the service was alive, the probe was just hitting the wrong
address.

Fix: swap `localhost` for an explicit `127.0.0.1` in the healthcheck command.

**Bug #2 — `registry`.** Checked the logs:

```bash
docker logs registry --tail 40
```

```
level=warning msg="error authorizing context: basic authentication challenge
for realm \"Registry Realm\": invalid authorization credential" ...
"GET /v2/ ... 401"
```

This service runs with `REGISTRY_AUTH=htpasswd`, which means the `/v2/` endpoint
(the same one the healthcheck hits) requires authorization — not just for image
operations, but for a plain ping too. The healthcheck was hitting it with no
credentials at all, so every 30 seconds it got a 401 and stayed unhealthy forever,
even though the registry itself was behaving completely correctly (401 with no
credentials is the expected, correct response on its end).

Fix: send the same Basic Auth header the registry itself uses:

```bash
echo -n "ilija-s:change-me" | base64
# aWxpamEtczpjaGFuZ2UtbWU=
```

and pass it as `--header=Authorization: Basic aWxpamEtczpjaGFuZ2UtbWU=` on the
`wget` command. After recreating the containers, both services turned `healthy`
within the next 30 seconds — exactly one check interval.

Both fixes are one-line changes in `docker-compose.yml`, and both are the kind of
thing that's essentially impossible to catch just by reading the config file — you
have to actually bring the stand up and look at what's happening from inside the
containers.

![compose ps](docs/screenshots/compose-ps.png)

## 4. Registry push failing on the certificate

Login and tag went fine, but `docker push` failed:

```bash
docker login registry.lab.local   # Login Succeeded
docker tag alpine:3.20 registry.lab.local/alpine:3.20
docker push registry.lab.local/alpine:3.20
```

```
tls: failed to verify certificate: x509: certificate signed by unknown authority
```

Expected: `make certs` creates a self-signed certificate, and the Docker daemon
doesn't trust it by default — this isn't a bug in the stand, it's normal protection
against a spoofed registry. The standard way to make the daemon trust a specific
private registry, without disabling TLS verification globally, is to drop the CA
certificate exactly where Docker looks for it, per-host:

```bash
mkdir -p /etc/docker/certs.d/registry.lab.local
cp nginx/certs/lab.crt /etc/docker/certs.d/registry.lab.local/ca.crt
```

After that, `docker push` went through cleanly, and hitting the registry's API with
`curl` confirmed the image actually landed:

```bash
curl -sk -u ilija-s:change-me https://registry.lab.local/v2/_catalog
# {"repositories":["alpine"]}
```

![registry push](docs/screenshots/registry-push.png)

## 5. The confusing one: `status.lab.local` wouldn't load in the browser, but `curl` worked perfectly

This one is worth writing up in detail — every symptom pointed at the stand itself,
and none of them were actually its fault.

Once all the containers were healthy, `curl -vk https://status.lab.local` came back
clean every single time: a full TLS 1.3 handshake, a valid HTTP/2 response, a 302
redirect to `/dashboard` — exactly what you'd expect from Uptime Kuma. But opening
the same address in an actual browser gave `PR_END_OF_FILE_ERROR` in Firefox and
`ERR_CONNECTION_CLOSED` in Chrome. In both cases, the error is essentially "the
connection appeared to start and then dropped without a single byte of data."

First instinct is a certificate problem. But that doesn't add up: if it were the
certificate, the browser would show the familiar "connection is not private"
interstitial with a click-through button, not a bare connection-abort error. And
`curl` had already proven the TLS handshake itself was fine.

To see whether the browser's request was even reaching the server, captured traffic
on the loopback interface while reloading the page in the browser:

```bash
tcpdump -i any -n port 443
```

Across every failed attempt, **not a single packet** hit `127.0.0.1:443`. The
browser wasn't failing to connect — it wasn't trying to connect at all. That
immediately clears the certificate, the nginx config, and the container itself: none
of them ever saw this request, because it never reached them.

The actual cause turned out to be a system-wide HTTPS proxy configured on the
desktop (used for an unrelated traffic-shaping purpose on this machine), whose
exception list only contained plain IP ranges (`127.0.0.0/8`, `::1`), not hostnames.
The key detail: proxy exceptions are matched against the hostname **as typed**,
before any DNS resolution happens — so the fact that `status.lab.local` resolves to
`127.0.0.1` via `/etc/hosts` is completely irrelevant to that matching. As a result,
`status.lab.local` didn't match any exception and was routed through the proxy,
which had no idea what that domain was (it does its own DNS resolution and doesn't
read the local machine's hosts file) — and closed the connection immediately. That's
exactly the "connection seemed to open, then died with no data" symptom both
browsers reported. `curl` never hit this, because it doesn't go through the system
proxy by default — which is exactly why it looked like the stand was fine while the
browser insisted otherwise.

Fix: explicitly add both lab domains to the proxy's exception list, so they connect
directly instead of being routed through it:

```bash
gsettings set org.gnome.system.proxy ignore-hosts \
  "['localhost', '127.0.0.0/8', '::1', 'status.lab.local', 'registry.lab.local']"
```

The proxy itself didn't change at all and kept working exactly as before for
everything else — these two addresses just stopped existing as far as it was
concerned.

## 6. Setting up the status page

With the network issue out of the way, `https://status.lab.local` loaded normally
and showed Uptime Kuma's first-run setup screen. Created an admin account, added an
HTTP(s) monitor for `http://proxy/healthz` (the `proxy` container's address on the
internal `web` docker network, reachable by service name), and within a minute the
monitor turned "Up".

![kuma dashboard](docs/screenshots/kuma-dashboard.png)

## 7. Final check

```bash
docker compose ps
```
```
backup    Up ...
kuma      Up ... (healthy)
proxy     Up ... (healthy)
registry  Up ... (healthy)
```

```bash
curl -s http://localhost/healthz
# ok

curl -sk -u ilija-s:change-me https://registry.lab.local/v2/_catalog
# {"repositories":["alpine"]}
```

All four services are `healthy`, the health endpoint responds, `alpine:3.20` shows
up in the private registry's catalog, and the Uptime Kuma dashboard shows a live,
green monitor.

![final verification](docs/screenshots/final-verification.png)
