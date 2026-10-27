# Сеть: VPC, NAT-шлюз для выхода нод в интернет (у нод нет публичных IP),
# подсети в трёх зонах и группы безопасности по примеру из документации:
# https://yandex.cloud/ru/docs/managed-kubernetes/operations/connect/security-groups

resource "yandex_vpc_network" "main" {
  name   = "${var.project}-net"
  labels = var.labels
}

resource "yandex_vpc_gateway" "nat" {
  name = "${var.project}-nat"
  shared_egress_gateway {}
}

resource "yandex_vpc_route_table" "nat" {
  name       = "${var.project}-rt"
  network_id = yandex_vpc_network.main.id

  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.nat.id
  }
}

resource "yandex_vpc_subnet" "main" {
  for_each = var.subnets

  name           = "${var.project}-${each.key}"
  zone           = each.key
  network_id     = yandex_vpc_network.main.id
  v4_cidr_blocks = [each.value]
  route_table_id = yandex_vpc_route_table.nat.id
  labels         = var.labels
}

locals {
  subnet_cidrs = values(var.subnets)
  # Балансировщики Yandex проверяют здоровье нод с этих адресов
  lb_healthcheck_cidrs = ["198.18.235.0/24", "198.18.248.0/24"]
}

# Общая группа для кластера и нод: служебный трафик внутри кластера.
resource "yandex_vpc_security_group" "k8s_main" {
  name        = "${var.project}-k8s-main"
  description = "Служебный трафик кластера: healthchecks балансировщика, master<->nodes, pod<->pod"
  network_id  = yandex_vpc_network.main.id
  labels      = var.labels

  ingress {
    description    = "Проверки состояния сетевого балансировщика"
    protocol       = "TCP"
    from_port      = 0
    to_port        = 65535
    v4_cidr_blocks = local.lb_healthcheck_cidrs
  }

  ingress {
    description       = "Трафик между мастером и нодами"
    protocol          = "ANY"
    from_port         = 0
    to_port           = 65535
    predefined_target = "self_security_group"
  }

  ingress {
    description    = "Трафик между подами и сервисами"
    protocol       = "ANY"
    from_port      = 0
    to_port        = 65535
    v4_cidr_blocks = [var.cluster_ipv4_range, var.service_ipv4_range]
  }

  ingress {
    description    = "ICMP из внутренних подсетей (диагностика)"
    protocol       = "ICMP"
    v4_cidr_blocks = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
  }

  egress {
    description    = "Весь исходящий трафик (образы, обновления, облачные API)"
    protocol       = "ANY"
    from_port      = 0
    to_port        = 65535
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# Доступ к API Kubernetes снаружи (kubectl, helm).
resource "yandex_vpc_security_group" "k8s_master" {
  name        = "${var.project}-k8s-master"
  description = "Доступ к API Kubernetes"
  network_id  = yandex_vpc_network.main.id
  labels      = var.labels

  ingress {
    description    = "Kubernetes API"
    protocol       = "TCP"
    port           = 443
    v4_cidr_blocks = var.k8s_api_allowed_cidrs
  }

  ingress {
    description    = "Kubernetes API"
    protocol       = "TCP"
    port           = 6443
    v4_cidr_blocks = var.k8s_api_allowed_cidrs
  }
}

# Входящий трафик к сервисам типа NodePort/LoadBalancer (ingress-nginx).
resource "yandex_vpc_security_group" "k8s_nodes_public" {
  name        = "${var.project}-k8s-nodes-public"
  description = "Доступ к NodePort-сервисам из интернета (через сетевой балансировщик)"
  network_id  = yandex_vpc_network.main.id
  labels      = var.labels

  ingress {
    description    = "Диапазон NodePort"
    protocol       = "TCP"
    from_port      = 30000
    to_port        = 32767
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# Managed PostgreSQL: подключения только из подсетей кластера.
resource "yandex_vpc_security_group" "postgres" {
  name        = "${var.project}-postgres"
  description = "Доступ к Managed PostgreSQL из подсетей кластера"
  network_id  = yandex_vpc_network.main.id
  labels      = var.labels

  ingress {
    description    = "PostgreSQL (порт пулера Odyssey)"
    protocol       = "TCP"
    port           = 6432
    v4_cidr_blocks = concat(local.subnet_cidrs, [var.cluster_ipv4_range])
  }

  egress {
    description    = "Ответы и репликация"
    protocol       = "ANY"
    from_port      = 0
    to_port        = 65535
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}
