#!/usr/bin/env bash
# Непрерывно опрашивает URL и считает коды ответов — проверка «релиз без простоя».
#   scripts/probe.sh <url> <секунд> [файл-лога] [Host-заголовок]
# Пример (kind):
#   scripts/probe.sh http://127.0.0.1:18080/api/bulletins 120 probe.log bulletin-board.localhost
# Итог: таблица «код -> количество». Любой 5xx или 000 (нет соединения) — простой.
set -euo pipefail

url="${1:?url}"
duration="${2:-60}"
log="${3:-probe.log}"
host="${4:-}"

: > "$log"
end=$(( $(date +%s) + duration ))
while [ "$(date +%s)" -lt "$end" ]; do
  if [ -n "$host" ]; then
    code=$(curl -s -o /dev/null -m 5 -H "Host: $host" -w '%{http_code}' "$url" || true)
  else
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$url" || true)
  fi
  echo "$(date +%H:%M:%S) ${code:-000}" >> "$log"
  sleep 0.1
done

total=$(wc -l < "$log")
echo "Запросов: $total"
awk '{print $2}' "$log" | sort | uniq -c | awk '{printf "  HTTP %s: %s\n", $2, $1}'
bad=$(awk '$2 !~ /^[23]/' "$log" | wc -l)
if [ "$bad" -gt 0 ]; then
  echo "Ошибок (не 2xx/3xx): $bad"
  exit 1
fi
echo "Ошибок нет"
