# Развёртывание в Yandex Cloud

> Процедура описана по документации Yandex Cloud и проверена только «сухо»: `terraform fmt`,
> `terraform validate`, `tflint`, `helm lint/template` с `values-yc.yaml`, `kubeconform`. Облачного
> аккаунта у автора нет, `terraform apply` и облачные команды не выполнялись.

## Что создаёт Terraform (`terraform/`)

| Файл | Ресурсы |
| --- | --- |
| `versions.tf` | провайдеры `yandex-cloud/yandex ~> 0.230`, `hashicorp/random`; S3-бекенд (частичная конфигурация) |
| `network.tf` | VPC, NAT-шлюз + таблица маршрутов, подсети в `ru-central1-a/b/d`, группы безопасности: служебный трафик кластера (healthchecks балансировщика, master↔nodes, pod↔pod), доступ к API, NodePort для балансировщика, PostgreSQL только из подсетей |
| `iam.tf` | SA мастера (`k8s.clusters.agent`, `vpc.publicAdmin`, `load-balancer.admin`, `logging.writer`), SA нод (`container-registry.images.puller`), SA Object Storage (`storage.editor`) + статический ключ, SA ESO + авторизованный ключ, SA наблюдаемости (`monitoring.editor`, `logging.writer`) + API-ключ и авторизованный ключ, KMS-ключ для секретов кластера |
| `main.tf` | Managed Kubernetes (зональный мастер с публичным IP, Calico, KMS, логи мастера в Cloud Logging) и node group (`node_count`, по умолчанию 2, без публичных IP, прерываемые ВМ, обновление по одной ноде) |
| `postgres.tf` | Managed PostgreSQL 16, пользователь и БД `bulletins`, пароль `random_password` |
| `storage.tf` | бакет картинок без публичного доступа |
| `lockbox.tf` | секрет Lockbox с параметрами БД и S3, право `lockbox.payloadViewer` для SA ESO |
| `logging.tf` | лог-группа с retention 72h |
| `outputs.tf` | ID кластера и нод-группы, endpoint, kubeconfig (токен — `yc k8s create-token`), параметры БД, бакет и ключи S3, ID Lockbox, ключи SA ESO/Fluent Bit, API-ключ Prometheus, ID лог-группы |

## Пошагово

### 1. Подготовка

```bash
yc init                                       # облако, каталог, зона ru-central1-a
export YC_TOKEN=$(yc iam create-token)        # токен живёт 12 часов
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# cloud_id  = yc config get cloud-id
# folder_id = yc config get folder-id
```

Проверка: `yc config list` показывает cloud-id и folder-id.

### 2. Бакет для state

```bash
make tf-bootstrap      # scripts/tf-bootstrap.sh: SA + бакет + ключ -> terraform/backend.hcl
make tf-init           # terraform init -backend-config=backend.hcl
```

Проверка: `terraform -chdir=terraform state list` выполняется без ошибок (пустой список).

### 3. Инфраструктура

```bash
make tf-plan           # ~40 ресурсов к созданию
make tf-apply          # кластер и БД создаются 10–20 минут
make tf-output
```

Проверка: `yc managed-kubernetes cluster list`, `yc managed-kubernetes node-group list` (2 ноды
RUNNING), `yc managed-postgresql cluster list` (ALIVE), `yc lockbox secret list`.

### 4. Доступ к кластеру

```bash
make yc-kubeconfig     # yc managed-kubernetes cluster get-credentials --external
kubectl get nodes      # 2 ноды Ready
```

Или без yc в PATH на другой машине: `terraform -chdir=terraform output -raw kubeconfig > kubeconfig.yaml`.

### 5. Аддоны

```bash
make addons-yc         # ingress-nginx (Service LoadBalancer), External Secrets Operator, Reloader
kubectl -n ingress-nginx get svc ingress-nginx-controller   # EXTERNAL-IP
make yc-eso-auth       # Secret yc-auth с ключом SA ESO
```

metrics-server в Managed Kubernetes уже установлен.

### 6. Образ и приложение

```bash
make image-login GHCR_USER=... GHCR_TOKEN=...
make build push TAG=1.0.0
make helm-install ENV=yc TAG=1.0.0 INGRESS_HOST=bulletin-board.<EXTERNAL-IP>.nip.io
```

Если пакет GHCR приватный — `kubectl -n bulletin-board create secret docker-registry ghcr ...` и
`imagePullSecrets` в `values-yc.yaml` (или сделать пакет публичным в настройках GitHub).

Проверка: `make eso-status` (SecretSynced), `make rollout-status`,
`curl http://bulletin-board.<EXTERNAL-IP>.nip.io/api/bulletins`.

### 7. Мониторинг и логи

```bash
YC_PROMETHEUS_WORKSPACE_ID=<id> make monitoring-yc
```

Подробности — [monitoring.md](monitoring.md).

### 8. Ротация секрета

```bash
make yc-rotate         # новый пароль в PostgreSQL и Lockbox -> ESO -> Reloader
```

Подробности — [secrets.md](secrets.md).

### 9. Удаление

```bash
helm -n bulletin-board uninstall bulletin-board
helm -n ingress-nginx uninstall ingress-nginx      # освобождает балансировщик и публичный IP
make tf-destroy
```

Бакет со state удаляется вручную (`yc storage bucket delete`) после `tf-destroy`.

## Стоимость

Самое дорогое — мастер Managed Kubernetes и Managed PostgreSQL; ноды прерываемые
(`node_preemptible = true`). Для учебного стенда удаляйте инфраструктуру после проверки.
