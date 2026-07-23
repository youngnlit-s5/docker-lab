# Runbook — bring up docker-lab and capture screenshots

Run these on any Linux box (or WSL2). Each numbered block ends with the screenshot
worth capturing for the README.

## 0. Install Docker (Debian/Ubuntu)

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc >/dev/null
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
| sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo usermod -aG docker "$USER"   # log out/in afterwards

docker --version && docker compose version
```

screenshot 1 -> docs/screenshots/docker-version.png (versions printed)

## 1. Prepare the stand

```bash
cd docker-lab
cp .env.example .env
make certs
make auth
echo "127.0.0.1 status.lab.local registry.lab.local" | sudo tee -a /etc/hosts
```

## 2. Validate + bring it up

```bash
docker compose config -q && echo "compose OK"
make up
make ps         # wait until every service shows (healthy)
```

screenshot 2 -> docs/screenshots/compose-ps.png

## 3. Prove it works

```bash
curl -s http://localhost/healthz            # -> ok
docker login registry.lab.local             # ilija-s / change-me
docker tag alpine:3.20 registry.lab.local/alpine:3.20
docker push registry.lab.local/alpine:3.20
```

screenshot 3 -> docs/screenshots/registry-push.png
screenshot 4 -> docs/screenshots/kuma-dashboard.png (open https://status.lab.local, add monitors, wait green)

## Capturing a screenshot

- GUI: your OS screenshot tool on the browser / terminal window.
- Headless: `sudo apt-get install -y scrot && scrot docs/screenshots/compose-ps.png`
- Save PNGs into docs/screenshots/ with the exact names above.
