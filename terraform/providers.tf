# Аутентификация провайдера — через переменные окружения, а не через код:
#   export YC_TOKEN=$(yc iam create-token)                # пользователь
#   или YC_SERVICE_ACCOUNT_KEY_FILE=/path/to/key.json     # сервисный аккаунт
# cloud_id и folder_id передаются переменными (terraform.tfvars или TF_VAR_*).
provider "yandex" {
  cloud_id  = var.cloud_id
  folder_id = var.folder_id
  zone      = var.default_zone
}
