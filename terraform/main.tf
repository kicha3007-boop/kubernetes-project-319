# Managed Kubernetes: зональный мастер с публичным адресом и группа рабочих нод.

resource "yandex_kubernetes_cluster" "main" {
  name        = "${var.project}-k8s"
  description = "Кластер доски объявлений"
  network_id  = yandex_vpc_network.main.id
  labels      = var.labels

  cluster_ipv4_range = var.cluster_ipv4_range
  service_ipv4_range = var.service_ipv4_range

  master {
    version   = var.k8s_version
    public_ip = true

    master_location {
      zone      = var.default_zone
      subnet_id = yandex_vpc_subnet.main[var.default_zone].id
    }

    security_group_ids = [
      yandex_vpc_security_group.k8s_main.id,
      yandex_vpc_security_group.k8s_master.id,
    ]

    maintenance_policy {
      auto_upgrade = true

      maintenance_window {
        day        = "sunday"
        start_time = "03:00"
        duration   = "3h"
      }
    }

    master_logging {
      enabled                    = true
      log_group_id               = yandex_logging_group.main.id
      kube_apiserver_enabled     = true
      cluster_autoscaler_enabled = true
      events_enabled             = true
      audit_enabled              = false
    }
  }

  service_account_id      = yandex_iam_service_account.k8s_cluster.id
  node_service_account_id = yandex_iam_service_account.k8s_nodes.id

  release_channel         = "STABLE"
  network_policy_provider = "CALICO"

  kms_provider {
    key_id = yandex_kms_symmetric_key.k8s.id
  }

  # Без ролей у сервисного аккаунта кластер не создастся
  depends_on = [
    yandex_resourcemanager_folder_iam_member.k8s_cluster,
    yandex_resourcemanager_folder_iam_member.k8s_nodes_puller,
    yandex_kms_symmetric_key_iam_binding.k8s,
  ]
}

resource "yandex_kubernetes_node_group" "main" {
  cluster_id  = yandex_kubernetes_cluster.main.id
  name        = "${var.project}-nodes"
  description = "Рабочие ноды приложения"
  version     = var.k8s_version
  labels      = var.labels

  instance_template {
    platform_id = var.node_resources.platform_id

    resources {
      cores         = var.node_resources.cores
      memory        = var.node_resources.memory
      core_fraction = var.node_resources.core_fraction
    }

    boot_disk {
      type = var.node_resources.disk_type
      size = var.node_resources.disk_size
    }

    # Публичных адресов у нод нет: выход в интернет — через NAT-шлюз,
    # вход — только через балансировщик ingress-nginx.
    network_interface {
      nat        = false
      subnet_ids = [yandex_vpc_subnet.main[var.default_zone].id]
      security_group_ids = [
        yandex_vpc_security_group.k8s_main.id,
        yandex_vpc_security_group.k8s_nodes_public.id,
      ]
    }

    scheduling_policy {
      preemptible = var.node_preemptible
    }

    container_runtime {
      type = "containerd"
    }
  }

  scale_policy {
    fixed_scale {
      size = var.node_count
    }
  }

  allocation_policy {
    location {
      zone = var.default_zone
    }
  }

  # Обновление нод по одной: max_unavailable = 0 и max_expansion = 1 означают,
  # что сначала поднимается новая нода и только потом выводится старая.
  deploy_policy {
    max_unavailable = 0
    max_expansion   = 1
  }

  maintenance_policy {
    auto_upgrade = true
    auto_repair  = true

    maintenance_window {
      day        = "sunday"
      start_time = "04:00"
      duration   = "3h"
    }
  }
}
