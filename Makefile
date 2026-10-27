# Доска объявлений (Kubernetes): образ, Terraform, kind, манифесты, Helm, секреты, мониторинг.
# make help — список целей.

SHELL := bash
.DEFAULT_GOAL := help

# --- Параметры -------------------------------------------------------------------
IMAGE       ?= ghcr.io/kicha3007-boop/bulletin-board
TAG         ?= 1.1.0
ENV         ?= local
RELEASE     ?= bulletin-board
NAMESPACE   ?= bulletin-board
CHART       := k8s/bulletin-board
KIND_NAME   ?= p319
KIND_CTX    := kind-$(KIND_NAME)
TF_DIR      := terraform
HOST_PORT   ?= 18080
APP_HOST    ?= bulletin-board.localhost
# Пароль локальной БД (kind) — заглушка, не секрет; см. k8s/local/postgres.yaml
LOCAL_DB_PASSWORD ?= local-dev-only

# Версии сторонних чартов
INGRESS_NGINX_VERSION    ?= 4.15.1
METRICS_SERVER_VERSION   ?= 3.14.0
ESO_VERSION              ?= 2.14.0
RELOADER_VERSION         ?= 2.2.18
KPS_VERSION              ?= 92.14.0
# kube-prometheus-stack берётся из OCI-реестра: index.yaml на github.io отвечает нестабильно
KPS_CHART                ?= oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack

# kind не должен передавать нодам прокси хоста (127.0.0.1:port внутри ноды недоступен)
NO_PROXY_ENV := env -u HTTP_PROXY -u HTTPS_PROXY -u NO_PROXY -u http_proxy -u https_proxy -u no_proxy

.PHONY: help
help: ## Показать список целей
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# --- Образ ---------------------------------------------------------------------------
.PHONY: build push image-login compose-up compose-down
build: ## Собрать образ IMAGE:TAG (без кеша)
	docker build --no-cache -t $(IMAGE):$(TAG) .

image-login: ## Логин в GHCR: GHCR_USER и GHCR_TOKEN (PAT со scope write:packages)
	@test -n "$(GHCR_TOKEN)" || (echo "Задайте GHCR_TOKEN и GHCR_USER" && exit 1)
	@echo "$(GHCR_TOKEN)" | docker login ghcr.io -u "$(GHCR_USER)" --password-stdin

push: ## Опубликовать образ IMAGE:TAG в реестр (нужен make image-login)
	docker push $(IMAGE):$(TAG)

compose-up: ## Запустить образ с PostgreSQL в docker compose (http://localhost:18090)
	docker compose up -d --build

compose-down: ## Остановить docker compose и удалить данные
	docker compose down -v

# --- Terraform (Yandex Cloud) ---------------------------------------------------------
.PHONY: tf-bootstrap tf-init tf-init-local tf-fmt tf-validate tf-plan tf-apply tf-destroy tf-output
tf-bootstrap: ## Создать бакет для state и ключ доступа к нему (yc CLI, один раз)
	bash scripts/tf-bootstrap.sh

tf-init: ## terraform init с S3-бекендом (terraform/backend.hcl)
	terraform -chdir=$(TF_DIR) init -backend-config=backend.hcl

tf-init-local: ## terraform init без бекенда (для validate/CI)
	terraform -chdir=$(TF_DIR) init -backend=false -input=false

tf-fmt: ## Проверить форматирование Terraform
	terraform -chdir=$(TF_DIR) fmt -check -recursive -diff

tf-validate: tf-init-local ## Проверить конфигурацию Terraform
	terraform -chdir=$(TF_DIR) validate

tf-plan: ## План изменений инфраструктуры
	terraform -chdir=$(TF_DIR) plan -out=tfplan

tf-apply: ## Применить план (создать/обновить облако)
	terraform -chdir=$(TF_DIR) apply tfplan

tf-destroy: ## Удалить всю облачную инфраструктуру
	terraform -chdir=$(TF_DIR) destroy

tf-output: ## Показать outputs (без секретов)
	terraform -chdir=$(TF_DIR) output

# --- Кластер ---------------------------------------------------------------------------
.PHONY: kind-up kind-down kind-load yc-kubeconfig helm-repos addons addons-yc probe
kind-up: ## Создать локальный кластер kind (1 control-plane + 2 worker)
	$(NO_PROXY_ENV) kind create cluster --config k8s/kind/cluster.yaml --wait 180s

kind-down: ## Удалить локальный кластер kind
	kind delete cluster --name $(KIND_NAME)

kind-load: ## Загрузить образ IMAGE:TAG в kind (вместо pull из реестра)
	kind load docker-image $(IMAGE):$(TAG) --name $(KIND_NAME)

yc-kubeconfig: ## Добавить Managed Kubernetes в ~/.kube/config
	yc managed-kubernetes cluster get-credentials --id $$(terraform -chdir=$(TF_DIR) output -raw cluster_id) --external --force

helm-repos: ## Подключить репозитории сторонних чартов
	helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
	helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
	helm repo add external-secrets https://charts.external-secrets.io
	helm repo add stakater https://stakater.github.io/stakater-charts
	helm repo update

addons: helm-repos ## kind: ingress-nginx, metrics-server, ESO, Reloader
	helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx --version $(INGRESS_NGINX_VERSION) \
	  -n ingress-nginx --create-namespace -f k8s/addons/ingress-nginx-kind.yaml --wait --timeout 10m
	helm upgrade --install metrics-server metrics-server/metrics-server --version $(METRICS_SERVER_VERSION) \
	  -n kube-system -f k8s/addons/metrics-server.yaml --wait --timeout 5m
	$(MAKE) eso-install

addons-yc: helm-repos ## Yandex Cloud: ingress-nginx (LoadBalancer), ESO, Reloader
	helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx --version $(INGRESS_NGINX_VERSION) \
	  -n ingress-nginx --create-namespace -f k8s/addons/ingress-nginx-yc.yaml --wait --timeout 10m
	$(MAKE) eso-install

# --- Kubernetes-манифесты (шаг 3–4) --------------------------------------------------------
.PHONY: db-local k8s-apply k8s-status k8s-delete
db-local: ## kind: PostgreSQL в кластере (замена Managed PostgreSQL)
	kubectl apply -f k8s/local/postgres.yaml
	kubectl -n bulletin-db rollout status statefulset/postgres --timeout=180s

k8s-apply: db-local ## Применить чистые манифесты k8s/manifests (без Helm)
	kubectl apply -f k8s/manifests/
	kubectl -n $(NAMESPACE) rollout status deploy/bulletin-board --timeout=300s

k8s-status: ## Состояние приложения в кластере
	kubectl -n $(NAMESPACE) get deploy,pods,svc,ingress,hpa,pdb -o wide

k8s-delete: ## Удалить ресурсы из k8s/manifests
	kubectl delete -f k8s/manifests/ --ignore-not-found

# --- Helm ------------------------------------------------------------------------------------
.PHONY: helm-lint helm-template helm-install helm-upgrade helm-rollback helm-history helm-test helm-uninstall rollout-status
helm-lint: ## Проверить чарт для всех окружений
	helm lint $(CHART)
	helm lint $(CHART) -f $(CHART)/values-local.yaml
	helm lint $(CHART) -f $(CHART)/values-yc.yaml --set externalSecrets.yandexlockbox.lockboxSecretId=placeholder

helm-template: ## Отрендерить чарт для ENV (local|yc)
	helm template $(RELEASE) $(CHART) -n $(NAMESPACE) -f $(CHART)/values-$(ENV).yaml $(HELM_EXTRA)

# Для ENV=yc идентификаторы берутся из terraform output, хост — из INGRESS_HOST
# (например bulletin-board.<EXTERNAL-IP ingress-nginx>.nip.io)
INGRESS_HOST ?=
ifeq ($(ENV),yc)
HELM_EXTRA ?= --set externalSecrets.yandexlockbox.lockboxSecretId=$$(terraform -chdir=$(TF_DIR) output -raw lockbox_secret_id) \
  --set env.STORAGE_S3_BUCKET=$$(terraform -chdir=$(TF_DIR) output -raw s3_bucket) \
  $(if $(INGRESS_HOST),--set ingress.host=$(INGRESS_HOST))
endif

helm-install: ## Установить/обновить релиз: make helm-install ENV=local|yc TAG=...
	helm upgrade --install $(RELEASE) $(CHART) -n $(NAMESPACE) --create-namespace \
	  -f $(CHART)/values-$(ENV).yaml --set image.tag=$(TAG) $(HELM_EXTRA) --wait --timeout 10m
	kubectl -n $(NAMESPACE) rollout status deploy/$(RELEASE) --timeout=300s

helm-upgrade: helm-install ## Синоним helm-install (новый TAG -> rolling update)

helm-rollback: ## Откат: make helm-rollback REVISION=N (без N — на предыдущую)
	helm -n $(NAMESPACE) rollback $(RELEASE) $(REVISION) --wait --timeout 10m
	kubectl -n $(NAMESPACE) rollout status deploy/$(RELEASE) --timeout=300s

helm-history: ## История релизов
	helm -n $(NAMESPACE) history $(RELEASE)

helm-test: ## helm test: сервис отвечает изнутри кластера
	helm -n $(NAMESPACE) test $(RELEASE)

helm-uninstall: ## Удалить релиз
	helm -n $(NAMESPACE) uninstall $(RELEASE)

rollout-status: ## kubectl rollout status для Deployment
	kubectl -n $(NAMESPACE) rollout status deploy/$(RELEASE)

probe: ## Опрашивать приложение через ingress 120 с и посчитать коды ответов
	bash scripts/probe.sh http://127.0.0.1:$(HOST_PORT)/api/bulletins 120 probe.log $(APP_HOST)

# --- Секреты ---------------------------------------------------------------------------------
.PHONY: eso-install eso-seed eso-status rotate-local yc-eso-auth yc-rotate
eso-install: ## External Secrets Operator + Reloader
	helm upgrade --install external-secrets external-secrets/external-secrets --version $(ESO_VERSION) \
	  -n external-secrets --create-namespace -f k8s/addons/external-secrets.yaml --wait --timeout 10m
	helm upgrade --install reloader stakater/reloader --version $(RELOADER_VERSION) \
	  -n reloader --create-namespace -f k8s/addons/reloader.yaml --wait --timeout 5m

eso-seed: ## kind: создать «эмулятор Lockbox» (Secret-источник для ESO)
	kubectl create namespace lockbox-emulator --dry-run=client -o yaml | kubectl apply -f -
	kubectl -n lockbox-emulator create secret generic bulletin-board-app \
	  --from-literal=SPRING_DATASOURCE_USERNAME=bulletins \
	  --from-literal=SPRING_DATASOURCE_PASSWORD=$(LOCAL_DB_PASSWORD) \
	  --from-literal=STORAGE_S3_ACCESSKEY= --from-literal=STORAGE_S3_SECRETKEY= \
	  --dry-run=client -o yaml | kubectl apply -f -

eso-status: ## Состояние синхронизации секретов
	kubectl -n $(NAMESPACE) get secretstore,externalsecret
	kubectl -n $(NAMESPACE) get secret $(RELEASE)-secrets -o jsonpath='{.metadata.annotations}' ; echo

rotate-local: ## kind: ротация пароля БД (NEW_PASSWORD=...) без простоя
	bash scripts/rotate-local.sh "$(NEW_PASSWORD)"

yc-eso-auth: ## YC: положить ключ SA ESO в Secret yc-auth (из terraform output)
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	terraform -chdir=$(TF_DIR) output -raw eso_sa_key_json > .eso-key.json
	kubectl -n $(NAMESPACE) create secret generic yc-auth --from-file=authorized-key=.eso-key.json \
	  --dry-run=client -o yaml | kubectl apply -f -
	rm -f .eso-key.json

yc-rotate: ## YC: ротация пароля БД через Lockbox (NEW_PASSWORD=...)
	bash scripts/rotate-yc.sh "$(NEW_PASSWORD)"

# --- Мониторинг ------------------------------------------------------------------------------
.PHONY: monitoring-install monitoring-yc grafana-password
monitoring-install: helm-repos ## kind: kube-prometheus-stack (Prometheus, Alertmanager, Grafana)
	helm upgrade --install kps $(KPS_CHART) --version $(KPS_VERSION) \
	  -n monitoring --create-namespace -f k8s/addons/kube-prometheus-stack-kind.yaml --wait --timeout 15m
	helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx --version $(INGRESS_NGINX_VERSION) \
	  -n ingress-nginx -f k8s/addons/ingress-nginx-kind.yaml \
	  --set controller.metrics.serviceMonitor.enabled=true --wait --timeout 10m

monitoring-yc: helm-repos ## YC: Prometheus с remote_write в Managed Prometheus + Fluent Bit в Cloud Logging
	bash scripts/monitoring-yc.sh

grafana-password: ## Пароль admin локальной Grafana
	@kubectl -n monitoring get secret kps-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo

# --- Всё сразу -----------------------------------------------------------------------------------
.PHONY: local-up local-down
local-up: kind-up addons build kind-load db-local eso-seed monitoring-install ## Поднять весь локальный стенд в kind
	$(MAKE) helm-install ENV=local
	@echo "Приложение: http://$(APP_HOST):$(HOST_PORT)  Grafana: http://grafana.localhost:$(HOST_PORT)"

local-down: kind-down ## Удалить локальный стенд
