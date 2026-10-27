# --- Kubernetes ---------------------------------------------------------------

output "cluster_id" {
  description = "ID кластера Managed Kubernetes"
  value       = yandex_kubernetes_cluster.main.id
}

output "node_group_id" {
  description = "ID группы нод"
  value       = yandex_kubernetes_node_group.main.id
}

output "cluster_external_endpoint" {
  description = "Публичный адрес API Kubernetes"
  value       = yandex_kubernetes_cluster.main.master[0].external_v4_endpoint
}

output "kubeconfig_command" {
  description = "Команда, которая добавляет кластер в ~/.kube/config"
  value       = "yc managed-kubernetes cluster get-credentials --id ${yandex_kubernetes_cluster.main.id} --external --force"
}

# Токен в kubeconfig не хранится: kubectl каждый раз получает короткоживущий
# IAM-токен через `yc k8s create-token` (exec-плагин).
output "kubeconfig" {
  description = "kubeconfig кластера (terraform output -raw kubeconfig > kubeconfig.yaml)"
  sensitive   = true
  value = yamlencode({
    apiVersion      = "v1"
    kind            = "Config"
    current-context = "yc-${var.project}"
    clusters = [{
      name = "yc-${var.project}"
      cluster = {
        server                     = yandex_kubernetes_cluster.main.master[0].external_v4_endpoint
        certificate-authority-data = base64encode(yandex_kubernetes_cluster.main.master[0].cluster_ca_certificate)
      }
    }]
    contexts = [{
      name    = "yc-${var.project}"
      context = { cluster = "yc-${var.project}", user = "yc-${var.project}" }
    }]
    users = [{
      name = "yc-${var.project}"
      user = {
        exec = {
          apiVersion = "client.authentication.k8s.io/v1beta1"
          command    = "yc"
          args       = ["k8s", "create-token"]
        }
      }
    }]
  })
}

# --- PostgreSQL ---------------------------------------------------------------

output "db_host" {
  description = "FQDN текущего мастера PostgreSQL"
  value       = local.db_host
}

output "db_port" {
  description = "Порт PostgreSQL (пулер)"
  value       = local.db_port
}

output "db_name" {
  description = "Имя БД"
  value       = yandex_mdb_postgresql_database.app.name
}

output "db_user" {
  description = "Пользователь БД"
  value       = yandex_mdb_postgresql_user.app.name
}

output "db_jdbc_url" {
  description = "JDBC-строка подключения (без пароля)"
  value       = local.db_jdbc_url
}

output "db_password" {
  description = "Пароль БД (он же лежит в Lockbox)"
  value       = random_password.db.result
  sensitive   = true
}

# --- Object Storage -----------------------------------------------------------

output "s3_bucket" {
  description = "Бакет для картинок"
  value       = yandex_storage_bucket.images.bucket
}

output "s3_endpoint" {
  description = "Endpoint Object Storage"
  value       = "https://storage.yandexcloud.net"
}

output "s3_access_key" {
  description = "ID статического ключа S3"
  value       = yandex_iam_service_account_static_access_key.storage.access_key
}

output "s3_secret_key" {
  description = "Секретная часть статического ключа S3"
  value       = yandex_iam_service_account_static_access_key.storage.secret_key
  sensitive   = true
}

# --- Секреты и наблюдаемость -----------------------------------------------------

output "lockbox_secret_id" {
  description = "ID секрета Lockbox — подставляется в values-yc.yaml (externalSecrets.lockboxSecretId)"
  value       = yandex_lockbox_secret.app.id
}

output "eso_sa_key_json" {
  description = "Авторизованный ключ сервисного аккаунта ESO в формате yc (для Secret yc-auth)"
  sensitive   = true
  value = jsonencode({
    id                 = yandex_iam_service_account_key.eso.id
    service_account_id = yandex_iam_service_account.eso.id
    created_at         = yandex_iam_service_account_key.eso.created_at
    key_algorithm      = yandex_iam_service_account_key.eso.key_algorithm
    public_key         = yandex_iam_service_account_key.eso.public_key
    private_key        = yandex_iam_service_account_key.eso.private_key
  })
}

output "fluentbit_sa_key_json" {
  description = "Авторизованный ключ для Fluent Bit (Cloud Logging)"
  sensitive   = true
  value = jsonencode({
    id                 = yandex_iam_service_account_key.fluentbit.id
    service_account_id = yandex_iam_service_account.observability.id
    created_at         = yandex_iam_service_account_key.fluentbit.created_at
    key_algorithm      = yandex_iam_service_account_key.fluentbit.key_algorithm
    public_key         = yandex_iam_service_account_key.fluentbit.public_key
    private_key        = yandex_iam_service_account_key.fluentbit.private_key
  })
}

output "prometheus_api_key" {
  description = "API-ключ для remote_write в Managed Prometheus"
  value       = yandex_iam_service_account_api_key.prometheus.secret_key
  sensitive   = true
}

output "logging_group_id" {
  description = "ID лог-группы Cloud Logging"
  value       = yandex_logging_group.main.id
}

output "folder_id" {
  description = "ID каталога (нужен Fluent Bit и Managed Prometheus)"
  value       = var.folder_id
}
