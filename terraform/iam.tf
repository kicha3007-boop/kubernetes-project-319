# Сервисные аккаунты по принципу минимальных прав:
#   k8s_cluster — от его имени мастер управляет ресурсами (балансировщики, публичные IP);
#   k8s_nodes   — от его имени ноды скачивают образы;
#   storage     — владелец статических ключей S3 для приложения;
#   eso         — External Secrets Operator читает Lockbox;
#   observability — запись метрик в Managed Prometheus и логов в Cloud Logging.

resource "yandex_iam_service_account" "k8s_cluster" {
  name        = "${var.project}-k8s-cluster"
  description = "Сервисный аккаунт мастера Managed Kubernetes"
}

resource "yandex_iam_service_account" "k8s_nodes" {
  name        = "${var.project}-k8s-nodes"
  description = "Сервисный аккаунт нод (pull образов)"
}

resource "yandex_iam_service_account" "storage" {
  name        = "${var.project}-storage"
  description = "Доступ приложения к Object Storage"
}

resource "yandex_iam_service_account" "eso" {
  name        = "${var.project}-eso"
  description = "External Secrets Operator: чтение секрета Lockbox"
}

resource "yandex_iam_service_account" "observability" {
  name        = "${var.project}-observability"
  description = "Запись метрик (Managed Prometheus) и логов (Cloud Logging)"
}

locals {
  cluster_roles = [
    "k8s.clusters.agent",
    "vpc.publicAdmin",
    "load-balancer.admin",
    "logging.writer",
  ]
}

resource "yandex_resourcemanager_folder_iam_member" "k8s_cluster" {
  for_each = toset(local.cluster_roles)

  folder_id = var.folder_id
  role      = each.value
  member    = "serviceAccount:${yandex_iam_service_account.k8s_cluster.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "k8s_nodes_puller" {
  folder_id = var.folder_id
  role      = "container-registry.images.puller"
  member    = "serviceAccount:${yandex_iam_service_account.k8s_nodes.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "storage_editor" {
  folder_id = var.folder_id
  role      = "storage.editor"
  member    = "serviceAccount:${yandex_iam_service_account.storage.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "observability" {
  for_each = toset(["monitoring.editor", "logging.writer"])

  folder_id = var.folder_id
  role      = each.value
  member    = "serviceAccount:${yandex_iam_service_account.observability.id}"
}

# Ключ KMS для шифрования секретов Kubernetes в etcd
resource "yandex_kms_symmetric_key" "k8s" {
  name              = "${var.project}-k8s-secrets"
  description       = "Шифрование секретов Kubernetes"
  default_algorithm = "AES_256"
  rotation_period   = "8760h"
  labels            = var.labels
}

resource "yandex_kms_symmetric_key_iam_binding" "k8s" {
  symmetric_key_id = yandex_kms_symmetric_key.k8s.id
  role             = "kms.keys.encrypterDecrypter"
  members          = ["serviceAccount:${yandex_iam_service_account.k8s_cluster.id}"]
}

# Статический ключ S3: им пользуется приложение (через Lockbox) и им же создаётся бакет
resource "yandex_iam_service_account_static_access_key" "storage" {
  service_account_id = yandex_iam_service_account.storage.id
  description        = "Ключ приложения для Object Storage"
}

# Авторизованный ключ ESO: кладётся в Secret кластера (см. README, «Секреты»)
resource "yandex_iam_service_account_key" "eso" {
  service_account_id = yandex_iam_service_account.eso.id
  description        = "Авторизованный ключ External Secrets Operator"
  key_algorithm      = "RSA_2048"
}

# API-ключ для remote_write в Managed Prometheus
resource "yandex_iam_service_account_api_key" "prometheus" {
  service_account_id = yandex_iam_service_account.observability.id
  description        = "remote_write в Managed Service for Prometheus"
}

# Авторизованный ключ Fluent Bit для Cloud Logging
resource "yandex_iam_service_account_key" "fluentbit" {
  service_account_id = yandex_iam_service_account.observability.id
  description        = "Fluent Bit -> Cloud Logging"
  key_algorithm      = "RSA_2048"
}
