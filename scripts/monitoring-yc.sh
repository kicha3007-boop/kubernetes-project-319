#!/usr/bin/env bash
# Мониторинг и логи в Yandex Cloud:
#   - kube-prometheus-stack с remote_write в Managed Service for Prometheus;
#   - Fluent Bit с плагином Cloud Logging.
# Нужны: kubectl с контекстом кластера, helm, terraform outputs и переменная
# YC_PROMETHEUS_WORKSPACE_ID (воркспейс создаётся в консоли Monitoring -> Prometheus
# или `yc monitoring prometheus workspace create`, если команда доступна в вашей версии yc).
# ВНИМАНИЕ: скрипт не запускался — облачный стенд в этом проекте не разворачивался.
set -euo pipefail

TF_DIR="${TF_DIR:-terraform}"
WORKSPACE_ID="${YC_PROMETHEUS_WORKSPACE_ID:?Задайте YC_PROMETHEUS_WORKSPACE_ID}"
KPS_VERSION="${KPS_VERSION:-92.14.0}"
FLUENT_BIT_VERSION="${FLUENT_BIT_VERSION:-0.37.1}"

API_KEY="$(terraform -chdir="$TF_DIR" output -raw prometheus_api_key)"
LOG_GROUP_ID="$(terraform -chdir="$TF_DIR" output -raw logging_group_id)"
CLUSTER_ID="$(terraform -chdir="$TF_DIR" output -raw cluster_id)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl -n monitoring create secret generic yc-prometheus-api-key \
  --from-literal=api-key="$API_KEY" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n monitoring create secret generic yc-prometheus-api-key-env \
  --from-literal=YC_PROMETHEUS_API_KEY="$API_KEY" --dry-run=client -o yaml | kubectl apply -f -

sed "s/<WORKSPACE_ID>/${WORKSPACE_ID}/g" k8s/addons/kube-prometheus-stack-yc.yaml > "$tmp/kps.yaml"
helm upgrade --install kps prometheus-community/kube-prometheus-stack --version "$KPS_VERSION" \
  -n monitoring -f "$tmp/kps.yaml" --wait --timeout 15m

kubectl create namespace logging --dry-run=client -o yaml | kubectl apply -f -
terraform -chdir="$TF_DIR" output -raw fluentbit_sa_key_json > "$tmp/key.json"
kubectl -n logging create secret generic fluentbit-sa-key \
  --from-file=key.json="$tmp/key.json" --dry-run=client -o yaml | kubectl apply -f -

helm repo add fluent https://fluent.github.io/helm-charts >/dev/null 2>&1 || true
sed -e "s/<LOG_GROUP_ID>/${LOG_GROUP_ID}/g" -e "s/<CLUSTER_ID>/${CLUSTER_ID}/g" \
  k8s/addons/fluent-bit-yc.yaml > "$tmp/fluent-bit.yaml"
helm upgrade --install fluent-bit fluent/fluent-bit --version "$FLUENT_BIT_VERSION" \
  -n logging -f "$tmp/fluent-bit.yaml" --wait --timeout 10m

echo "Метрики: Monitoring -> Prometheus -> воркспейс ${WORKSPACE_ID}"
echo "Логи:    Cloud Logging -> лог-группа ${LOG_GROUP_ID}"
