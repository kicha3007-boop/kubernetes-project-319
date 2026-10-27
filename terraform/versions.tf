terraform {
  required_version = ">= 1.6.0"

  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "~> 0.230"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Состояние хранится в Yandex Object Storage (S3-совместимый бекенд).
  # Здесь только неизменяемые параметры; бакет, ключ и ключи доступа передаются
  # при инициализации (частичная конфигурация):
  #   terraform init -backend-config=backend.hcl
  # Шаблон — backend.hcl.example, сам backend.hcl в git не попадает.
  backend "s3" {
    endpoints = {
      s3 = "https://storage.yandexcloud.net"
    }
    region = "ru-central1"

    skip_region_validation      = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}
