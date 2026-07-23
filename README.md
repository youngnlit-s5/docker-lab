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

# Журнал развёртывания

Ниже — подробные заметки о том, как этот стенд разворачивался на чистой машине:
с чего начинал, какие баги вылезли только при реальном запуске (а не при чтении
конфига), и один по-настоящему запутанный сетевой случай, который на первый взгляд
выглядел как проблема самого стенда, а на деле не имел к Docker никакого отношения.

## 1. С чего начинал

Машина была обычным Linux-десктопом (Ubuntu 24.04, systemd), а не одноразовой
песочницей, так что первым делом проверил, что вообще уже стоит:

```bash
uname -a
cat /etc/os-release
docker --version
```

Docker Engine отсутствовал полностью — ни демона, ни CLI, ни compose-плагина.
Поставил всё по официальной инструкции с `download.docker.com` (репозиторий apt,
GPG-ключ, `docker-ce` + `docker-ce-cli` + `containerd.io` + `docker-compose-plugin`),
запустил и включил сервис:

```bash
systemctl start docker
systemctl enable docker
docker --version && docker compose version
```

Получил **Docker 29.6.2** и **Docker Compose v5.3.1**. Единственная шероховатость —
одно из системных apt-зеркал было недоступно по сети, но сам официальный репозиторий
Docker резолвился и работал без проблем, так что на установку это не повлияло.

![docker version](docs/screenshots/docker-version.png)

## 2. Подготовка стенда

Дальше — по инструкции из `Setup`: копирование `.env`, генерация самоподписанного
сертификата и htpasswd для реестра, и добавление доменов стенда в `/etc/hosts`:

```bash
cp .env.example .env
make certs
make auth
echo "127.0.0.1 status.lab.local registry.lab.local" >> /etc/hosts
```

`make certs` вызывает `openssl req -x509` и кладёт `lab.crt` / `lab.key` в
`nginx/certs/`, с SAN сразу на оба домена (`status.lab.local`, `registry.lab.local`).
`make auth` поднимает временный контейнер `httpd:2.4-alpine`, чтобы сгенерировать
`htpasswd`-файл для basic-auth реестра, не устанавливая `apache2-utils` на хост.

## 3. Первый запуск: два сервиса встали в `unhealthy`

```bash
docker compose config -q && echo "compose OK"
docker compose up -d
```

Все четыре образа поднялись, но через пару минут `docker compose ps` показал:

```
NAME       STATUS
kuma       Up ... (healthy)
proxy      Up ... (unhealthy)
registry   Up ... (unhealthy)
```

При этом оба сервиса по факту прекрасно отвечали на запросы — ломались именно
healthcheck'и, а не сами сервисы. Разбирался с каждым отдельно.

**Баг №1 — `proxy`.** Healthcheck в `docker-compose.yml` был прописан как
`wget -qO- http://localhost/healthz`. Проверил вручную прямо внутри контейнера:

```bash
docker exec proxy wget -qO- http://localhost/healthz
# wget: can't connect to remote host: Connection refused
docker exec proxy wget -qO- http://127.0.0.1/healthz
# ok
docker exec proxy cat /etc/hosts
# ::1  localhost ip6-localhost ip6-loopback
# 127.0.0.1 localhost
```

Внутри контейнера `/etc/hosts` резолвит `localhost` в `::1` раньше, чем в
`127.0.0.1` — а конфиг nginx слушает только `0.0.0.0` (чистый IPv4, без `[::]`).
Получается, что healthcheck пытался достучаться по IPv6, куда нginx вообще не
слушает, и падал с «connection refused», хотя реальный, «человеческий» запрос по
IPv4 (снаружи, через опубликованный порт) отрабатывал штатно. Классическая ловушка
двух стеков: сервис жив, а проверка бьёт не в тот адрес.

Фикс — заменить `localhost` на явный `127.0.0.1` в healthcheck-команде.

**Баг №2 — `registry`.** Смотрю логи:

```bash
docker logs registry --tail 40
```

```
level=warning msg="error authorizing context: basic authentication challenge
for realm \"Registry Realm\": invalid authorization credential" ...
"GET /v2/ ... 401"
```

У этого сервиса `REGISTRY_AUTH=htpasswd` включён, а значит эндпоинт `/v2/` (тот
самый, который дёргает healthcheck) требует авторизацию — причём не только для
операций с образами, но и для простого пинга. Healthcheck же стучался туда вообще
без креденшлов, поэтому каждые 30 секунд получал 401 и уходил в unhealthy навечно,
хотя сам registry работал абсолютно правильно (401 без авторизации — это ожидаемое,
корректное поведение с его стороны).

Фикс — добавить в healthcheck тот же заголовок Basic Auth, что использует сам
реестр:

```bash
echo -n "ilija-s:change-me" | base64
# aWxpamEtczpjaGFuZ2UtbWU=
```

и подставить его как `--header=Authorization: Basic aWxpamEtczpjaGFuZ2UtbWU=` в
команду `wget`. После пересборки контейнеров оба сервиса стали `healthy` в течение
следующих 30 секунд — ровно один цикл проверки.

Оба фикса — однострочные правки в `docker-compose.yml`, и оба показательны тем, что
их совершенно невозможно было бы найти, просто читая файл конфигурации: нужно было
реально поднять стенд и посмотреть, что происходит изнутри контейнеров.

![compose ps](docs/screenshots/compose-ps.png)

## 4. Push в реестр падает на сертификате

Логин и тег прошли нормально, а `docker push` упал:

```bash
docker login registry.lab.local   # Login Succeeded
docker tag alpine:3.20 registry.lab.local/alpine:3.20
docker push registry.lab.local/alpine:3.20
```

```
tls: failed to verify certificate: x509: certificate signed by unknown authority
```

Ожидаемо: `make certs` создаёт самоподписанный сертификат, и Docker-демон по
умолчанию ему не доверяет — это не баг стенда, а нормальная защита от подмены
реестра. Стандартный способ подружить демон с конкретным приватным реестром — не
отключать проверку TLS глобально, а положить CA-сертификат именно для этого хоста
туда, где Docker его ищет:

```bash
mkdir -p /etc/docker/certs.d/registry.lab.local
cp nginx/certs/lab.crt /etc/docker/certs.d/registry.lab.local/ca.crt
```

После этого `docker push` прошёл чисто, а `curl` к API реестра подтвердил, что
образ реально долетел:

```bash
curl -sk -u ilija-s:change-me https://registry.lab.local/v2/_catalog
# {"repositories":["alpine"]}
```

![registry push](docs/screenshots/registry-push.png)

## 5. Загадочный случай: `status.lab.local` не открывается в браузере, хотя `curl` работает идеально

Вот это стоит расписать подробно — все симптомы указывали на сам стенд, но ни один
из них не был виной стенда.

Как только все контейнеры стали healthy, `curl -vk https://status.lab.local`
раз за разом отдавал безупречный результат: полное TLS 1.3 рукопожатие, валидный
HTTP/2-ответ, редирект 302 на `/dashboard` — ровно то, чего и следует ожидать от
Uptime Kuma. Но при открытии того же адреса в обычном браузере — `PR_END_OF_FILE_ERROR`
в Firefox и `ERR_CONNECTION_CLOSED` в Chrome. В обоих случаях это ошибки вида
«соединение как будто начало устанавливаться и тут же оборвалось без единого байта
данных».

Первая мысль — проблема с сертификатом. Но это не сходится: если бы дело было в
сертификате, браузер показал бы привычную страницу «соединение не защищено» с
кнопкой «всё равно перейти», а не голую ошибку обрыва соединения. К тому же `curl`
уже доказал, что само TLS-рукопожатие проходит нормально.

Чтобы понять, доходит ли запрос браузера вообще до сервера, снял трафик на
loopback-интерфейсе прямо во время перезагрузки страницы в браузере:

```bash
tcpdump -i any -n port 443
```

За всё время неудачных попыток на `127.0.0.1:443` не пришло **ни одного пакета**.
То есть браузер не «падал» на соединении — он его вообще не пытался установить.
Это сразу снимает подозрения с сертификата, конфига nginx и самого контейнера:
ни один из них ни разу не увидел этот запрос, потому что он до них не долетал.

Настоящая причина обнаружилась в системных сетевых настройках десктопа: на машине
был включён HTTPS-прокси (используется для другой, не связанной со стендом задачи
трафик-шейпинга), а список исключений для этого прокси состоял только из диапазонов
IP-адресов (`127.0.0.0/8`, `::1`), но не содержал имён хостов. Ключевая деталь:
исключения прокси сверяются с именем хоста **как оно набрано**, до какого-либо
DNS-резолвинга — то есть тот факт, что `status.lab.local` резолвится в `127.0.0.1`
через `/etc/hosts`, для матчинга исключений вообще не учитывается. В результате
`status.lab.local` не попадал ни под одно исключение и уходил через прокси, а тот
понятия не имел, что это за домен (у прокси свой собственный DNS-резолвинг, локальный
`/etc/hosts` машины он не читает) — и обрывал соединение сразу же. Это ровно
симптом «соединение будто открылось и тут же умерло без данных», который показывали
оба браузера. `curl` эту проблему не видел, потому что по умолчанию не ходит через
системный прокси — из-за этого и складывалось ощущение, что со стендом что-то не
так, хотя на деле он был полностью исправен с самого начала.

Фикс — явно добавить оба лаб-домена в список исключений прокси, чтобы для них
устанавливалось прямое соединение, минуя прокси:

```bash
gsettings set org.gnome.system.proxy ignore-hosts \
  "['localhost', '127.0.0.0/8', '::1', 'status.lab.local', 'registry.lab.local']"
```

Сам прокси при этом никак не менялся и продолжил работать как раньше для всего
остального трафика — просто эти два адреса теперь для него не существуют.

## 6. Настройка страницы статуса

После того как сетевая проблема была устранена, `https://status.lab.local`
открылся штатно и показал экран первичной настройки Uptime Kuma. Создал
администратора, добавил HTTP(s)-монитор на `http://proxy/healthz` (адрес
контейнера `proxy` во внутренней docker-сети `web`, доступный по имени сервиса) и
в течение минуты монитор перешёл в статус «Доступен».

![kuma dashboard](docs/screenshots/kuma-dashboard.png)

## 7. Итоговая проверка

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

Все четыре сервиса `healthy`, health-эндпоинт отвечает, образ `alpine:3.20` виден
в каталоге приватного реестра, а дашборд Uptime Kuma показывает живой зелёный
монитор.

![final verification](docs/screenshots/final-verification.png)
