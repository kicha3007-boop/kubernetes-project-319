#!/usr/bin/env bash
# Ротация пароля БД в Yandex Cloud:
#   1. новый пароль пользователю Managed PostgreSQL;
#   2. новая версия секрета Lockbox (остальные ключи копируются из текущей версии);
#   3. ESO за refreshInterval (1m) обновляет Secret в кластере;
#   4. Reloader перезапускает поды RollingUpdate-ом — без простоя.
# Требуется: yc (авторизован), jq, kubectl с контекстом кластера, terraform outputs.
#   scripts/rotate-yc.sh [новый-пароль]
# ВНИМАНИЕ: скрипт не запускался — облачный стенд в этом проекте не разворачивался.
set -euo pipefail

TF_DIR="${TF_DIR:-terraform}"
NS="${NAMESPACE:-bulletin-board}"
RELEASE="${RELEASE:-bulletin-board}"
NEW_PASSWORD="${1:-}"
if [ -z "$NEW_PASSWORD" ]; then
  NEW_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)"
fi

SECRET_ID="$(terraform -chdir="$TF_DIR" output -raw lockbox_secret_id)"
DB_USER="$(terraform -chdir="$TF_DIR" output -raw db_user)"
PG_CLUSTER="$(yc managed-postgresql cluster list --format json | jq -r '.[] | select(.name | endswith("-pg")) | .id' | head -n1)"

echo "1) Managed PostgreSQL: новый пароль пользователя ${DB_USER}"
yc managed-postgresql user update "$DB_USER" --cluster-id "$PG_CLUSTER" --password "$NEW_PASSWORD"

echo "2) Lockbox: новая версия секрета ${SECRET_ID}"
payload="$(yc lockbox payload get --id "$SECRET_ID" --format json \
  | jq --arg p "$NEW_PASSWORD" '[.entries[] | {key: .key, text_value: (if .key == "SPRING_DATASOURCE_PASSWORD" then $p else .text_value end)}]')"
yc lockbox secret add-version --id "$SECRET_ID" --payload "$payload" --description "rotation $(date -u +%FT%TZ)"

echo "3) Ждём синхронизации ESO"
for _ in $(seq 1 60); do
  current="$(kubectl -n "$NS" get secret "${RELEASE}-secrets" -o jsonpath='{.data.SPRING_DATASOURCE_PASSWORD}' | base64 -d)"
  [ "$current" = "$NEW_PASSWORD" ] && break
  sleep 5
done
[ "$current" = "$NEW_PASSWORD" ] || { echo "ESO не обновил Secret"; exit 1; }

echo "4) Reloader перезапускает поды"
sleep 5
kubectl -n "$NS" rollout status "deploy/${RELEASE}" --timeout=600s
echo "Готово"
