# Cloud Logging: лог-группа для логов мастера и подов (Fluent Bit).
# Срок хранения задаётся переменной log_retention.

resource "yandex_logging_group" "main" {
  name             = "${var.project}-logs"
  description      = "Логи кластера и приложения"
  retention_period = var.log_retention
  labels           = var.labels
}
