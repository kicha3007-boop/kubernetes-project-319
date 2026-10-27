# Managed PostgreSQL в той же сети, что и кластер. Доступ — только из подсетей кластера
# (группа безопасности postgres), пароль генерируется Terraform и кладётся в Lockbox.

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "yandex_mdb_postgresql_cluster" "main" {
  name               = "${var.project}-pg"
  description        = "БД доски объявлений"
  environment        = "PRODUCTION"
  network_id         = yandex_vpc_network.main.id
  security_group_ids = [yandex_vpc_security_group.postgres.id]
  labels             = var.labels

  config {
    version = var.pg_version

    resources {
      resource_preset_id = var.pg_resource_preset
      disk_type_id       = "network-ssd"
      disk_size          = var.pg_disk_size
    }

    backup_window_start {
      hours   = 2
      minutes = 0
    }
  }

  host {
    zone      = var.default_zone
    subnet_id = yandex_vpc_subnet.main[var.default_zone].id
  }

  maintenance_window {
    type = "WEEKLY"
    day  = "SUN"
    hour = 5
  }
}

resource "yandex_mdb_postgresql_user" "app" {
  cluster_id = yandex_mdb_postgresql_cluster.main.id
  name       = var.db_user
  password   = random_password.db.result
  conn_limit = 50
}

resource "yandex_mdb_postgresql_database" "app" {
  cluster_id = yandex_mdb_postgresql_cluster.main.id
  name       = var.db_name
  owner      = yandex_mdb_postgresql_user.app.name
  lc_collate = "en_US.UTF-8"
  lc_type    = "en_US.UTF-8"
}

locals {
  # Особый FQDN c-<id>.rw.mdb.yandexcloud.net всегда указывает на текущий мастер кластера
  db_host = "c-${yandex_mdb_postgresql_cluster.main.id}.rw.mdb.yandexcloud.net"
  db_port = 6432
  db_jdbc_url = format(
    "jdbc:postgresql://%s:%d/%s?sslmode=require",
    local.db_host, local.db_port, var.db_name,
  )
}
