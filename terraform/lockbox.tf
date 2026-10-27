# Lockbox — единственный источник чувствительных параметров приложения.
# В кластер они попадают через External Secrets Operator (см. k8s/bulletin-board,
# values-yc.yaml: externalSecrets.enabled=true). Ключи записи совпадают с именами
# переменных окружения Spring Boot, поэтому ExternalSecret забирает секрет целиком.
#
# Ротация: новая версия секрета (yc lockbox secret add-version ...) -> ESO подтягивает
# её за refreshInterval -> Reloader перезапускает поды по одному (RollingUpdate).
# Terraform не затирает версии, созданные вручную при ротации (ignore_changes ниже).

resource "yandex_lockbox_secret" "app" {
  name                = "${var.project}-app"
  description         = "Секреты доски объявлений: БД и Object Storage"
  deletion_protection = false
  labels              = var.labels
}

resource "yandex_lockbox_secret_version" "app" {
  secret_id = yandex_lockbox_secret.app.id

  entries {
    key        = "SPRING_DATASOURCE_URL"
    text_value = local.db_jdbc_url
  }

  entries {
    key        = "SPRING_DATASOURCE_USERNAME"
    text_value = yandex_mdb_postgresql_user.app.name
  }

  entries {
    key        = "SPRING_DATASOURCE_PASSWORD"
    text_value = random_password.db.result
  }

  entries {
    key        = "STORAGE_S3_ACCESSKEY"
    text_value = yandex_iam_service_account_static_access_key.storage.access_key
  }

  entries {
    key        = "STORAGE_S3_SECRETKEY"
    text_value = yandex_iam_service_account_static_access_key.storage.secret_key
  }

  lifecycle {
    ignore_changes = [entries]
  }
}

# ESO читает только этот секрет, а не весь каталог
resource "yandex_lockbox_secret_iam_member" "eso" {
  secret_id = yandex_lockbox_secret.app.id
  role      = "lockbox.payloadViewer"
  member    = "serviceAccount:${yandex_iam_service_account.eso.id}"
}
