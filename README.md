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

![docker version](docs/screenshots/docker-version.png)

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

# Troubleshooting log

Notes from actually standing this up on a fresh box, including two config bugs that
only show up once you run it for real, and one genuinely confusing networking case
that turned out to have nothing to do with Docker at all.

## Two services stuck `unhealthy` on first boot

`docker compose up -d` pulled everything and started fine, but a couple of minutes in,
`proxy` and `registry` flipped to `unhealthy` in `docker compose ps` even though both
were serving requests correctly.

**`proxy`.** Its healthcheck is `wget -qO- http://localhost/healthz`. Inside the
container, `/etc/hosts` resolves `localhost` to `::1` before `127.0.0.1`, but the nginx
config only binds `0.0.0.0` (IPv4). So the healthcheck's own connection attempt hit a
port nothing was listening on and got "connection refused", while the actual service
was completely fine on IPv4. Confirmed it with:

```bash
docker exec proxy wget -qO- http://localhost/healthz   # connection refused
docker exec proxy wget -qO- http://127.0.0.1/healthz   # ok
```

Fix: point the healthcheck at `127.0.0.1` explicitly instead of `localhost`.

**`registry`.** Its healthcheck hits `/v2/` with no credentials. That's fine for a
registry with no auth, but this one runs with `REGISTRY_AUTH=htpasswd`, which protects
`/v2/` too — so the healthcheck's own probe was getting rejected with 401, forever:

```bash
docker logs registry --tail 40
# "error authorizing context: basic authentication challenge for realm
#  \"Registry Realm\": invalid authorization credential" ... "GET /v2/ ... 401"
```

Fix: send the same Basic Auth credentials the registry itself uses, as a header on the
healthcheck request (`Authorization: Basic <base64 of ilija-s:change-me>`).

Both are one-line changes in `docker-compose.yml`, and both are the kind of thing that
only shows up once the stand is actually running rather than just reading the compose
file — the services themselves were never broken, only the checks watching them.

![compose ps](docs/screenshots/compose-ps.png)

## Push failing on a self-signed certificate

`docker login` and `docker tag` worked, but `docker push` failed with:

```
tls: failed to verify certificate: x509: certificate signed by unknown authority
```

Expected, since `make certs` generates a self-signed cert and the Docker daemon
doesn't trust it by default. The fix is the standard one for a private registry with
its own CA — drop the cert where the daemon looks for per-registry trust:

```bash
mkdir -p /etc/docker/certs.d/registry.lab.local
cp nginx/certs/lab.crt /etc/docker/certs.d/registry.lab.local/ca.crt
```

After that, `docker push registry.lab.local/alpine:3.20` went through cleanly, and
`curl -sk -u ilija-s:change-me https://registry.lab.local/v2/_catalog` confirmed the
image landed in the registry.

![registry push](docs/screenshots/registry-push.png)

## The confusing one: `status.lab.local` refused to load in the browser, but `curl` was fine

This is the case worth writing down in detail, because every symptom pointed at the
stand itself and none of it was actually the stand's fault.

Once the containers were healthy, `curl -vk https://status.lab.local` came back clean
every single time — full TLS 1.3 handshake, valid HTTP/2 response, a 302 redirect to
`/dashboard` (Uptime Kuma's normal behavior). But opening the same URL in an actual
browser gave `PR_END_OF_FILE_ERROR` in Firefox and `ERR_CONNECTION_CLOSED` in Chrome —
in both cases, a connection that appears to start and then gets dropped with no data.

The first instinct is a certificate problem, but that doesn't fit: a cert issue would
show the usual "your connection is not private" interstitial, not a raw connection
error, and `curl` was proving the TLS handshake itself was fine.

Capturing traffic on the loopback interface while reloading the page in the browser
made it clear this wasn't even a TLS problem:

```bash
tcpdump -i any -n port 443
```

Zero packets to `127.0.0.1:443` during the failed browser attempts. The browser wasn't
failing a connection — it wasn't making one. That ruled out the certificate, the nginx
config, and the container entirely: none of them ever saw the request.

The actual cause turned out to be a system-wide HTTPS proxy configured for the desktop
(used for unrelated traffic-shaping on this machine), with an exception list that only
covered plain IP ranges (`127.0.0.0/8`, `::1`), not hostnames. Proxy exceptions get
matched against the hostname as typed, before DNS resolution — so `status.lab.local`,
despite resolving to `127.0.0.1` via `/etc/hosts`, didn't match any exception and was
still routed through the proxy. The proxy had no idea what `status.lab.local` was (it
does its own resolution and doesn't read the local machine's hosts file), so it closed
the connection immediately — which is exactly the "connection appears to open, then
dies with nothing" symptom both browsers reported. `curl` was unaffected because it
doesn't go through that proxy by default, which is why it looked like the stand itself
was fine while the browser insisted otherwise.

Fix: add both lab hostnames explicitly to the proxy's exception list, so they resolve
and connect directly instead of being routed through it. Nothing about the proxy setup
itself needed to change — it was working exactly as configured, just not for hostnames
it had never been told to skip.

## Setting up the status page

With the network issue out of the way, `https://status.lab.local` loaded the Uptime
Kuma setup screen normally. Created the admin account, added an HTTP(s) monitor for
`http://proxy/healthz` (reachable by container name on the internal `web` network),
and it came up green within a minute.

![kuma dashboard](docs/screenshots/kuma-dashboard.png)

## Final state

```bash
docker compose ps
# backup    Up ...
# kuma      Up ... (healthy)
# proxy     Up ... (healthy)
# registry  Up ... (healthy)

curl -s http://localhost/healthz                                    # -> ok
curl -sk -u ilija-s:change-me https://registry.lab.local/v2/_catalog # -> {"repositories":["alpine"]}
```

![final verification](docs/screenshots/final-verification.png)
