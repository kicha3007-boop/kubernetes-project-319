# --- Облако -------------------------------------------------------------------

variable "cloud_id" {
  description = "ID облака Yandex Cloud (yc config get cloud-id)"
  type        = string
}

variable "folder_id" {
  description = "ID каталога, в котором создаются ресурсы (yc config get folder-id)"
  type        = string
}

variable "default_zone" {
  description = "Зона доступности по умолчанию"
  type        = string
  default     = "ru-central1-a"
}

variable "project" {
  description = "Префикс имён всех ресурсов проекта"
  type        = string
  default     = "bulletin-board"
}

variable "labels" {
  description = "Метки, которые вешаются на все ресурсы"
  type        = map(string)
  default = {
    project    = "bulletin-board"
    managed-by = "terraform"
  }
}

# --- Сеть ---------------------------------------------------------------------

variable "subnets" {
  description = "Подсети кластера: зона -> CIDR. Ноды и БД размещаются в этих подсетях"
  type        = map(string)
  default = {
    "ru-central1-a" = "10.10.0.0/24"
    "ru-central1-b" = "10.11.0.0/24"
    "ru-central1-d" = "10.12.0.0/24"
  }
}

variable "cluster_ipv4_range" {
  description = "CIDR для адресов подов"
  type        = string
  default     = "10.96.0.0/16"
}

variable "service_ipv4_range" {
  description = "CIDR для адресов сервисов (ClusterIP)"
  type        = string
  default     = "10.112.0.0/16"
}

variable "k8s_api_allowed_cidrs" {
  description = "Адреса, с которых разрешён доступ к API Kubernetes (443/6443). Сузьте до своего IP"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# --- Kubernetes ---------------------------------------------------------------

variable "k8s_version" {
  description = "Версия Kubernetes (список доступных: yc managed-kubernetes list-versions)"
  type        = string
  default     = "1.32"
}

variable "node_count" {
  description = "Количество рабочих нод (шаг 2 — 1, шаг 4 — минимум 2)"
  type        = number
  default     = 2

  validation {
    condition     = var.node_count >= 1
    error_message = "Нужна хотя бы одна нода."
  }
}

variable "node_resources" {
  description = "Ресурсы одной ноды"
  type = object({
    platform_id   = string
    cores         = number
    memory        = number
    core_fraction = number
    disk_type     = string
    disk_size     = number
  })
  default = {
    platform_id   = "standard-v3"
    cores         = 2
    memory        = 4
    core_fraction = 50
    disk_type     = "network-hdd"
    disk_size     = 64
  }
}

variable "node_preemptible" {
  description = "Прерываемые ВМ для нод — в разы дешевле, подходит для учебного стенда"
  type        = bool
  default     = true
}

# --- PostgreSQL ---------------------------------------------------------------

variable "pg_version" {
  description = "Версия PostgreSQL"
  type        = string
  default     = "16"
}

variable "pg_resource_preset" {
  description = "Класс хостов Managed PostgreSQL"
  type        = string
  default     = "s2.micro"
}

variable "pg_disk_size" {
  description = "Размер диска БД, ГБ"
  type        = number
  default     = 10
}

variable "db_name" {
  description = "Имя базы данных приложения"
  type        = string
  default     = "bulletins"
}

variable "db_user" {
  description = "Пользователь БД приложения"
  type        = string
  default     = "bulletins"
}

# --- Логи ---------------------------------------------------------------------

variable "log_retention" {
  description = "Срок хранения логов в Cloud Logging"
  type        = string
  default     = "72h"
}
