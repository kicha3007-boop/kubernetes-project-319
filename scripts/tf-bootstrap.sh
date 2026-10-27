#!/usr/bin/env bash
# Один раз перед terraform init: бакет для state и сервисный аккаунт с ключом к нему.
# State не может храниться в бакете, который создаёт сам этот Terraform, поэтому
# бакет создаётся через yc CLI. Результат — terraform/backend.hcl (в .gitignore).
# ВНИМАНИЕ: скрипт не запускался — облачного аккаунта у автора нет.
set -euo pipefail

FOLDER_ID="${FOLDER_ID:-$(yc config get folder-id)}"
PREFIX="${PREFIX:-bulletin-board}"
SUFFIX="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 6)"
BUCKET="${PREFIX}-tfstate-${SUFFIX}"
SA="${PREFIX}-tfstate"

yc iam service-account create --name "$SA" --folder-id "$FOLDER_ID" >/dev/null 2>&1 || true
SA_ID="$(yc iam service-account get --name "$SA" --folder-id "$FOLDER_ID" --format json | jq -r .id)"
yc resource-manager folder add-access-binding "$FOLDER_ID" \
  --role storage.editor --subject "serviceAccount:${SA_ID}" >/dev/null

yc storage bucket create --name "$BUCKET" --folder-id "$FOLDER_ID" \
  --default-storage-class standard --max-size 1073741824 >/dev/null
yc storage bucket update --name "$BUCKET" --versioning versioning-enabled >/dev/null

KEY_JSON="$(yc iam access-key create --service-account-id "$SA_ID" --format json)"
cat > terraform/backend.hcl <<EOF
bucket     = "${BUCKET}"
key        = "${PREFIX}/terraform.tfstate"
access_key = "$(echo "$KEY_JSON" | jq -r .access_key.key_id)"
secret_key = "$(echo "$KEY_JSON" | jq -r .secret)"
EOF
echo "Создан бакет ${BUCKET}; параметры бекенда записаны в terraform/backend.hcl"
