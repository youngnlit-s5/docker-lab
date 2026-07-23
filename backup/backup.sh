#!/bin/sh
# Nightly backup of named volumes -> ./backup/out/*.tar.gz
set -eu
OUT_DIR="/backup/out"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
INTERVAL="${INTERVAL:-86400}"
mkdir -p "$OUT_DIR"
backup_once() {
    ts="$(date +%Y%m%d-%H%M%S)"
    for name in kuma registry; do
        src="/data/$name"
        [ -d "$src" ] || continue
        tar -czf "$OUT_DIR/${name}-${ts}.tar.gz" -C "$src" . 2>/dev/null || true
        echo "[$(date -u +%FT%TZ)] backed up $name -> ${name}-${ts}.tar.gz"
    done
    find "$OUT_DIR" -name '*.tar.gz' -mtime "+${RETENTION_DAYS}" -delete 2>/dev/null || true
}
echo "[backup] started, interval=${INTERVAL}s retention=${RETENTION_DAYS}d"
while true; do
    backup_once
    sleep "$INTERVAL"
done
