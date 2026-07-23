# Журнал работ — развёртывание docker-lab

Полный лог того, что было сделано на реальной машине, включая все команды, найденные
баги и то, как именно снимались скриншоты. Ниже — хронологический порядок действий.

## 1. Разведка окружения

Машина оказалась не одноразовым контейнером, а обычным Linux-десктопом (Ubuntu 24.04,
systemd, реальная GNOME-сессия пользователя). Docker отсутствовал:

```bash
whoami; id; uname -a; cat /etc/os-release
docker --version          # -> command not found
systemctl status docker   # -> Unit docker.service could not be found
```

## 2. Установка Docker Engine + Compose plugin

По официальной инструкции Docker (репозиторий `download.docker.com`):

```bash
apt-get update
apt-get install -y ca-certificates curl
install -m0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

systemctl start docker
systemctl enable docker
docker --version && docker compose version
```

Результат: **Docker 29.6.2**, **Docker Compose v5.3.1**.

Побочная деталь: одно из системных зеркал (`ru.archive.ubuntu.com`) было недоступно по
сети — это не мешало установке, `download.docker.com` резолвился и работал напрямую.

## 3. Подготовка стенда

```bash
cd docker-lab
cp .env.example .env
make certs      # openssl req -x509 ... -> nginx/certs/lab.crt + lab.key
make auth       # docker run httpd:2.4-alpine htpasswd -Bbn ilija-s change-me > nginx/certs/htpasswd
echo "127.0.0.1 status.lab.local registry.lab.local" >> /etc/hosts
```

## 4. Первый запуск и обнаруженные баги

```bash
docker compose config -q && echo "compose OK"
docker compose up -d
```

Все образы поднялись, но после ~2 минут два сервиса из четырёх ушли в `unhealthy`:

```
NAME       STATUS
kuma       Up ... (healthy)
proxy      Up ... (unhealthy)
registry   Up ... (unhealthy)
```

### Баг 1 — `proxy`: healthcheck бьёт в `localhost`, а не в `127.0.0.1`

```bash
docker exec proxy wget -qO- http://localhost/healthz
# -> wget: can't connect to remote host: Connection refused
docker exec proxy wget -qO- http://127.0.0.1/healthz
# -> ok
docker exec proxy cat /etc/hosts
# ::1 стоит ПЕРВЫМ для "localhost", а nginx слушает только 0.0.0.0
```

Внутри контейнера `/etc/hosts` резолвит `localhost` сначала в `::1`, а nginx в конфиге
слушает только IPv4 (`listen 80 default_server;` без `[::]`). Отсюда — «Connection
refused» на healthcheck при полностью рабочем самом сервисе.

**Фикс** (`docker-compose.yml`, сервис `proxy`):

```yaml
healthcheck:
  test: ["CMD", "wget", "-qO-", "http://127.0.0.1/healthz"]
```

### Баг 2 — `registry`: healthcheck не передаёт Basic Auth

```bash
docker logs registry --tail 40
# level=warning msg="error authorizing context: basic authentication challenge
# for realm \"Registry Realm\": invalid authorization credential" ... "GET /v2/ ... 401"
```

С `REGISTRY_AUTH=htpasswd` эндпоинт `/v2/` требует авторизацию, а healthcheck дёргал
его без креденшлов -> вечный 401 -> unhealthy.

**Фикс** (`docker-compose.yml`, сервис `registry`):

```bash
echo -n "ilija-s:change-me" | base64
# -> aWxpamEtczpjaGFuZ2UtbWU=
```

```yaml
healthcheck:
  test: ["CMD", "wget", "-qO-", "--header=Authorization: Basic aWxpamEtczpjaGFuZ2UtbWU=", "http://127.0.0.1:5000/v2/"]
```

После пересоздания контейнеров (`docker compose up -d`) все 4 сервиса стали `healthy`
в течение ~30 секунд.

## 5. Проверка стенда

```bash
curl -sv http://localhost/healthz
# -> HTTP/1.1 200 OK ... ok

echo "change-me" | docker login registry.lab.local -u ilija-s --password-stdin
# -> Login Succeeded

docker tag alpine:3.20 registry.lab.local/alpine:3.20
docker push registry.lab.local/alpine:3.20
# -> tls: failed to verify certificate: x509: certificate signed by unknown authority
```

Push упал из-за самоподписанного сертификата, которому не доверяет Docker-демон.
Стандартное решение — положить CA-сертификат стенда в `/etc/docker/certs.d/`:

```bash
mkdir -p /etc/docker/certs.d/registry.lab.local
cp nginx/certs/lab.crt /etc/docker/certs.d/registry.lab.local/ca.crt
docker push registry.lab.local/alpine:3.20
# -> 3.20: digest: sha256:c64c687c... size: 1023
```

Проверка через API реестра:

```bash
curl -sk -u ilija-s:change-me https://registry.lab.local/v2/_catalog
# -> {"repositories":["alpine"]}
```

## 6. Как сделаны скриншоты (реальные, не рендер)

Три первых скриншота (`docker-version.png`, `compose-ps.png`, `registry-push.png`) —
настоящие снимки экрана реальной GNOME-сессии, а не сгенерированные картинки:

1. Установлен `scrot` (`apt-get install -y scrot`).
2. Пользователь `ilamo` добавлен в группу `docker` (`usermod -aG docker ilamo`), как
   и требует официальная инструкция Docker.
3. Через `sudo -u ilamo env DISPLAY=:1 XAUTHORITY=/run/user/1000/gdm/Xauthority
   DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus gnome-terminal --wait --
   <скрипт>` открывалось настоящее окно терминала в сессии пользователя, скрипт
   печатал реальный вывод команды и затем сам себя фотографировал:
   `scrot -u -o /tmp/<имя>.png` (`-u` — активное окно, `-o` — перезаписать файл).
4. Поскольку сразу после `usermod` группа ещё не подхватывалась запущенным
   `gnome-terminal-server` (он был запущен раньше), докер-команды внутри скрипта
   оборачивались в `sg docker -c '...'`, чтобы гарантированно получить нужную группу.

## 7. Диагностика: `status.lab.local` не открывается в браузере

После поднятия стенда `curl` работал идеально, а в браузере (Chrome, Firefox) —
`PR_END_OF_FILE_ERROR` / `ERR_CONNECTION_CLOSED`. Разбор по шагам:

```bash
curl -vk https://status.lab.local
# -> TLSv1.3 handshake OK, HTTP/2 302 -> /dashboard (сервер полностью исправен)
```

Реальный Firefox через `xdotool`/`gnome-terminal` открывал вкладку — `tcpdump` на
`lo` и на всех интерфейсах во время попытки показывал **ноль пакетов** на порт 443:

```bash
timeout 10 tcpdump -i any -n port 443 -c 30
# -> только фоновый трафик других приложений, ничего к 127.0.0.1
```

Проверили `zapret2` (DPI-обход) — его правила `nftables` жёстко привязаны к
Wi-Fi-интерфейсу (`oifname "wlx..."`), на loopback не действуют:

```bash
nft list ruleset | grep -B5 "queue num 300"
```

Настоящая причина нашлась в системных настройках прокси GNOME:

```bash
gsettings get org.gnome.system.proxy mode
# -> 'manual'
gsettings list-recursively org.gnome.system.proxy
# -> org.gnome.system.proxy.https host '127.0.0.1', port 10809
# -> ignore-hosts: ['localhost', '127.0.0.0/8', '::1']
```

Прокси-исключения матчатся **по имени хоста до резолвинга**, а не по итоговому IP —
поэтому `127.0.0.0/8` в списке исключений не спасает `status.lab.local`: браузер
всё равно шлёт `CONNECT status.lab.local:443` на локальный прокси (часть VPN-стека),
а тот не знает про этот локальный домен и рвёт соединение.

**Фикс** — добавить оба лаб-домена в исключения прокси (сам прокси/VPN не трогали):

```bash
gsettings set org.gnome.system.proxy ignore-hosts \
  "['localhost', '127.0.0.0/8', '::1', 'status.lab.local', 'registry.lab.local']"
```

После полного перезапуска браузера (важно — прокси-настройки читаются при старте)
страница открылась и дошла до предупреждения о самоподписанном сертификате, которое
было принято штатно через интерфейс браузера.

## 8. Настройка Uptime Kuma

- Создан админ-аккаунт на `https://status.lab.local/setup`.
- Добавлен монитор: тип HTTP(s), URL `http://proxy/healthz` (адрес контейнера
  `proxy` во внутренней docker-сети), интервал 60 секунд.
- Монитор перешёл в статус **Доступен** — подтверждено скриншотом
  `kuma-dashboard.png`.

## 9. Публикация в GitHub

Изначально `/opt/claude/gitproject` не было git-репозиторием. Целевой репозиторий
`https://github.com/youngnlit-s5/docker-lab` уже существовал и не был пустым (там
лежал более ранний аплоад через веб-интерфейс с тем же набором файлов, но с другим
логином реестра — `labuser` вместо `ilija-s`).

Авторизация `gh` CLI через device-flow (без пароля/токена в открытом виде):

```bash
gh auth login --hostname github.com --git-protocol https --web
# -> код вида XXXX-XXXX и ссылка https://github.com/login/device,
#    пользователь вводит код в браузере вручную
gh auth setup-git
```

Первый заход — слияние истории без потери старого коммита:

```bash
cd docker-lab
git init -b main
git add -A                       # .env, сертификаты, backup/out — не попадают (.gitignore)
git commit -m "Stand up docker-lab: fix healthchecks, add screenshots"
git remote add origin https://github.com/youngnlit-s5/docker-lab.git
git fetch origin
git merge origin/main --allow-unrelated-histories -m "Merge existing remote scaffold"
# -> конфликты add/add в Makefile, README.md, backup.sh, docker-compose.yml,
#    architecture.svg, screenshots/README.md, nginx/conf.d/default.conf
git checkout --ours -- Makefile README.md backup/backup.sh docker-compose.yml \
  docs/architecture.svg docs/screenshots/README.md nginx/conf.d/default.conf
git add -A
git commit --no-edit
git push -u origin main
```

По отдельному запросу история была затем полностью очищена (squash в один коммит)
и запушена поверх старой веткой `--force`:

```bash
git checkout --orphan clean-main
git add -A
git commit -m "docker-lab: nginx reverse proxy + TLS, private registry, Uptime Kuma, backups"
git branch -D main
git branch -m main
git push --force origin main
```

После этого README дополнительно обновлялся двумя коммитами: сначала добавлено
описание найденных багов и таблица со ссылками на скриншоты, затем ссылки заменены
на прямую вставку картинок (`![...](docs/screenshots/...)`).

## 10. Финальное состояние

```bash
docker compose ps
# backup    Up 17 hours
# kuma      Up 17 hours (healthy)
# proxy     Up 17 hours (healthy)
# registry  Up 17 hours (healthy)

curl -s http://localhost/healthz
# -> ok

curl -sk -u ilija-s:change-me https://registry.lab.local/v2/_catalog
# -> {"repositories":["alpine"]}
```

Скриншот этой финальной проверки: [`screenshots/final-verification.png`](screenshots/final-verification.png).
