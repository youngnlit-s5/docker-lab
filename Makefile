# Convenience wrapper around the stand
.PHONY: certs auth up down logs backup ps

certs:
	mkdir -p nginx/certs
	openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
		-keyout nginx/certs/lab.key -out nginx/certs/lab.crt \
		-subj "/CN=lab.local" \
		-addext "subjectAltName=DNS:status.lab.local,DNS:registry.lab.local"

auth:
	mkdir -p nginx/certs
	docker run --rm httpd:2.4-alpine \
		htpasswd -Bbn ilija-s change-me > nginx/certs/htpasswd

up:
	docker compose up -d

down:
	docker compose down

ps:
	docker compose ps

logs:
	docker compose logs -f --tail=100

backup:
	docker compose run --rm backup /bin/sh -c 'RETENTION_DAYS=7 INTERVAL=0 sh /backup/backup.sh & sleep 3; kill %1'
