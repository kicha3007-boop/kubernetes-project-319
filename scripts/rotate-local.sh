#!/usr/bin/env bash
# Ротация пароля БД на локальном стенде (kind) по той же схеме, что в облаке:
#   1. меняем пароль пользователя в PostgreSQL;
#   2. кладём новое значение в источник секретов («эмулятор Lockbox»);
#   3. ESO за refreshInterval обновляет Secret bulletin-board-secrets;
#   4. Reloader видит изменение Secret и перезапускает Deployment RollingUpdate-ом.
# Старые поды продолжают работать на уже открытых соединениях пула, новые
# поднимаются с новым паролем — простоя нет.
#   scripts/rotate-local.sh [новый-пароль]
set -euo pipefail

NEW_PASSWORD="${1:-}"
if [ -z "$NEW_PASSWORD" ]; then
  NEW_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
fi
NS="${NAMESPACE:-bulletin-board}"
RELEASE="${RELEASE:-bulletin-board}"

echo "1) PostgreSQL: ALTER USER bulletins"
kubectl -n bulletin-db exec statefulset/postgres -- \
  psql -v ON_ERROR_STOP=1 -U bulletins -d bulletins -c "ALTER USER bulletins WITH PASSWORD '${NEW_PASSWORD}';"
# Чтобы пароль совпадал и после пересоздания пода postgres
kubectl -n bulletin-db patch secret postgres-auth --type merge \
  -p "{\"stringData\":{\"POSTGRES_PASSWORD\":\"${NEW_PASSWORD}\"}}"

echo "2) Источник секретов: новая версия значения"
kubectl -n lockbox-emulator patch secret bulletin-board-app --type merge \
  -p "{\"stringData\":{\"SPRING_DATASOURCE_PASSWORD\":\"${NEW_PASSWORD}\"}}"

echo "3) Ждём, пока ESO обновит Secret ${RELEASE}-secrets"
for _ in $(seq 1 60); do
  current="$(kubectl -n "$NS" get secret "${RELEASE}-secrets" -o jsonpath='{.data.SPRING_DATASOURCE_PASSWORD}' | base64 -d)"
  [ "$current" = "$NEW_PASSWORD" ] && break
  sleep 2
done
[ "$current" = "$NEW_PASSWORD" ] || { echo "ESO не обновил Secret"; exit 1; }
kubectl -n "$NS" get externalsecret "$RELEASE"

echo "4) Reloader перезапускает поды"
sleep 5
kubectl -n "$NS" rollout status "deploy/${RELEASE}" --timeout=300s
echo "Готово: поды работают с новым паролем"
