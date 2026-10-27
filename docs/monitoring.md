# Мониторинг, алерты и логи

## Что собираем

| Источник | Метрики | Как собирается |
| --- | --- | --- |
| Приложение (Micrometer, `:9090/actuator/prometheus`) | `http_server_requests_seconds_{count,bucket}` по `uri`, `status`, `method` — RPS, 5xx, гистограмма latency; `jvm_memory_*`, `process_cpu_usage`, пул Hikari | ServiceMonitor из чарта (`monitoring.serviceMonitor.enabled`) |
| ingress-nginx | `nginx_ingress_controller_requests` (коды ответов по ingress), `..._request_duration_seconds_bucket` | ServiceMonitor чарта ingress-nginx (`controller.metrics.serviceMonitor.enabled`) |
| kube-state-metrics | число подов и реплик, рестарты, состояние HPA/Deployment | kube-prometheus-stack |
| kubelet / cAdvisor, node-exporter | CPU и память подов и нод | kube-prometheus-stack |

## Алерты (`templates/prometheusrule.yaml`)

| Алерт | Условие | Severity |
| --- | --- | --- |
| `BulletinBoardDown` | ни одна цель приложения не отвечает 2 мин | critical |
| `BulletinBoardHigh5xxRate` | доля 5xx ответов API > 5% в течение 5 мин | critical |
| `BulletinBoardIngress5xx` | доля 5xx на ingress > 5% в течение 5 мин (502/503 при недоступных подах) | critical |
| `BulletinBoardReplicasUnavailable` | доступных реплик меньше желаемых 10 мин | warning |
| `BulletinBoardHighLatencyP95` | p95 времени ответа API > 0.5 с 10 мин | warning |
| `BulletinBoardHighHeapUsage` | heap JVM > 90% 10 мин | warning |
| `BulletinBoardPodRestarts` | > 2 рестартов контейнера за 15 мин | warning |
| `BulletinBoardHPAMaxedOut` | HPA на `maxReplicas` 15 мин — пора добавлять ноды | warning |

Пороги — в `values.yaml → monitoring.prometheusRule`.

## Дашборд

Grafana-дашборд «Доска объявлений» (`k8s/bulletin-board/files/dashboard.json`, генерируется
`scripts/gen-dashboard.py`) ставится ConfigMap-ом с меткой `grafana_dashboard: "1"` — sidecar Grafana
подхватывает его сам. Панели: доступные реплики, RPS, доля 5xx, p95; запросы по кодам ответа
(приложение и ingress); latency p50/p95/p99 и p95 ingress; CPU и память по подам; JVM heap; рестарты;
реплики HPA.

## Локально (kind) — проверено

```bash
make monitoring-install          # kube-prometheus-stack + ServiceMonitor ingress-nginx
make helm-install ENV=local      # values-local.yaml включает ServiceMonitor, PrometheusRule и дашборд
make grafana-password
```

- Grafana: <http://grafana.localhost:18080> → Dashboards → «Доска объявлений» (логин `admin`).
- Prometheus: <http://prometheus.localhost:18080> (Status → Targets, Alerts).
- Alertmanager: <http://alertmanager.localhost:18080>.

Скриншоты:

- [grafana-dashboard.png](screenshots/grafana-dashboard.png) — дашборд под нагрузкой во время rolling update и ротации секрета;
- [prometheus-targets.png](screenshots/prometheus-targets.png) — все цели `up`, включая `bulletin-board` (2 пода) и ingress-nginx;
- [prometheus-alerts.png](screenshots/prometheus-alerts.png) — правила `bulletin-board.*` загружены;
- [prometheus-alerts-firing.png](screenshots/prometheus-alerts-firing.png) — проверка алертов: PostgreSQL остановлен,
  `BulletinBoardHigh5xxRate` и `BulletinBoardHighLatencyP95` перешли в pending → firing;
- [alertmanager.png](screenshots/alertmanager.png) — сработавшие алерты дошли до Alertmanager;
- [grafana-dashboard-incident.png](screenshots/grafana-dashboard-incident.png) — тот же инцидент на дашборде.

Вывод проверки алертов — [evidence/05-alerts.txt](evidence/05-alerts.txt). `BulletinBoardIngress5xx`
в этом сценарии не сработал, и это ожидаемо: клиент (curl с таймаутом 5 с) обрывал запрос раньше,
чем приложение отвечало 500 через 30 с, поэтому ingress-nginx записал коды 499, а не 5xx — это видно на
панели «Ingress-nginx: запросы по кодам ответа».

## Yandex Cloud — сконфигурировано, не запускалось

Метрики — **Yandex Managed Service for Prometheus**:

1. Создать воркспейс: консоль → Monitoring → Prometheus → «Создать воркспейс», скопировать его ID.
2. Terraform уже создал SA `bulletin-board-observability` (`monitoring.editor`, `logging.writer`) и
   API-ключ (`terraform output -raw prometheus_api_key`).
3. `YC_PROMETHEUS_WORKSPACE_ID=<id> make monitoring-yc` — ставит kube-prometheus-stack
   (`k8s/addons/kube-prometheus-stack-yc.yaml`) с `remote_write` в
   `https://monitoring.api.cloud.yandex.net/prometheus/workspaces/<id>/api/v1/write`; ServiceMonitor и
   PrometheusRule приложения работают так же, как локально.
4. Дашборд: в Yandex Monitoring → Дашборды → создать дашборд, источник «Prometheus» (воркспейс),
   запросы — PromQL из `files/dashboard.json` (те же метрики); либо Grafana кластера с источником
   «Yandex Managed Prometheus» (прописан в `additionalDataSources`). Ссылка на дашборд:
   `https://monitoring.yandex.cloud/folders/<folder_id>/dashboards`.
5. Алерты: правила из `PrometheusRule` вычисляются Prometheus в кластере (Alertmanager); для
   уведомлений из облака те же выражения создаются в Monitoring → Алерты (каналы — email/Telegram).

Логи — **Cloud Logging**:

- лог-группа `bulletin-board-logs` с `retention_period = 72h` создаётся Terraform (`terraform/logging.tf`);
  туда же пишутся логи мастера Kubernetes (`master_logging`);
- Fluent Bit с плагином `yc-logging` (`k8s/addons/fluent-bit-yc.yaml`) читает логи только подов
  `bulletin-board` и `ingress-nginx`, отбрасывает строки health-проб и пишет в лог-группу, поток
  (`stream_name`) — имя namespace;
- приложение пишет JSON (logback + logstash encoder), Fluent Bit разбирает поля `level`, `message`;
- просмотр: консоль → Cloud Logging → `bulletin-board-logs`, фильтры вида
  `stream_name = "bulletin-board" and level = "ERROR"`.
