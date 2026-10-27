# Масштабирование и релизы без простоя

## Что обеспечивает zero-downtime

| Механизм | Где задан | Что даёт |
| --- | --- | --- |
| `strategy: RollingUpdate`, `maxSurge: 1`, `maxUnavailable: 0` | `templates/deployment.yaml`, `values.yaml → strategy` | новый под поднимается до того, как гасится старый; число готовых подов не падает ниже текущего |
| `minReadySeconds: 5` | `values.yaml` | под считается доступным, только если 5 с подряд готов |
| `startupProbe` (`/actuator/health/liveness`, до 150 с) | `values.yaml → probes.startup` | пока Spring стартует, liveness не убивает под |
| `readinessProbe` (`/actuator/health/readiness`) | `values.yaml → probes.readiness` | трафик идёт только на под, у которого поднят контекст и выполнена инициализация данных в БД (`ApplicationRunner`) |
| `livenessProbe` (`/actuator/health/liveness`) | `values.yaml → probes.liveness` | зависший под перезапускается |
| `preStop: sleep 10` + `SERVER_SHUTDOWN=graceful` + `terminationGracePeriodSeconds: 45` | `values.yaml` | под ещё обслуживает запросы, пока endpoints и ingress-nginx исключают его из балансировки, затем Spring дорабатывает активные запросы |
| `nginx.ingress.kubernetes.io/proxy-next-upstream` | `values.yaml → ingress.annotations` | при ошибке соединения ingress повторяет запрос на другом поде |
| `topologySpreadConstraints` по `kubernetes.io/hostname` | `values.yaml → topologySpread` | реплики на разных нодах: потеря ноды не выключает сервис |
| PodDisruptionBudget `minAvailable: 1` | `templates/pdb.yaml` | `kubectl drain` (обновление node group) не выводит последний под; значение меньше числа реплик, поэтому drain не блокируется |
| HPA 2..5 (облако 2..6), CPU 70% | `templates/hpa.yaml` | нагрузка → больше подов; никогда меньше двух |

Requests/limits (`250m/384Mi` → `1 CPU/512Mi`, в облаке память 512Mi → 768Mi) нужны планировщику
для размещения подов и HPA — для расчёта утилизации.

Масштабирование нод — Terraform: `node_count` (по умолчанию 2), нода-группа обновляется по одной
(`deploy_policy { max_unavailable = 0, max_expansion = 1 }`): сначала создаётся новая нода, потом
старая освобождается через drain с учётом PDB.

```bash
# шаг 2: одна нода
terraform -chdir=terraform apply -var node_count=1
# шаг 4: две ноды
terraform -chdir=terraform apply -var node_count=2
kubectl get nodes
```

## Как выкатывать

```bash
make build push TAG=1.0.1                    # новый образ в реестр (в kind: make build kind-load TAG=1.0.1)
make helm-install ENV=local TAG=1.0.1        # helm upgrade --install --wait + kubectl rollout status
make rollout-status                          # повторная проверка: deployment "bulletin-board" successfully rolled out
```

## Как проверялось (kind)

Во время выката в соседнем терминале работал опрос через ingress-nginx (`scripts/probe.sh`,
запрос каждые ~0.1 с, любой ответ кроме 2xx/3xx или отсутствие ответа считается простоем):

```bash
make probe          # = scripts/probe.sh http://127.0.0.1:18080/api/bulletins 120 probe.log bulletin-board.localhost
```

| Сценарий | Запросов | Не-2xx | Лог |
| --- | --- | --- | --- |
| rolling update 1.0.0 → 1.0.1 | 411 | 0 | [evidence/02-rolling-update.txt](evidence/02-rolling-update.txt) |
| `helm rollback` 1.0.1 → 1.0.0 | 420 | 0 | [evidence/03-helm-rollback.txt](evidence/03-helm-rollback.txt) |
| ротация секрета (рестарт подов Reloader-ом) | 604 | 0 | [evidence/04-secret-rotation.txt](evidence/04-secret-rotation.txt) |
| релиз 1.1.0 через `make helm-install` (5 → 2 пода после HPA) | 572 | 0 | [evidence/08-release-1.1.0.txt](evidence/08-release-1.1.0.txt) |

HPA проверен нагрузкой изнутри кластера (12 параллельных циклов curl): CPU 254% от requests →
через окно стабилизации 60 с HPA поднял Deployment с 2 до 5 реплик (maxReplicas), поды разошлись по
обеим рабочим нодам — [evidence/06-hpa.txt](evidence/06-hpa.txt). Состояние релиза и `helm test` —
[evidence/07-helm-release.txt](evidence/07-helm-release.txt).

Тег 1.0.1 в локальной проверке — тот же собранный образ под новым тегом: для Kubernetes это новая
версия шаблона пода, выкатывается так же, как образ с изменённым кодом.

Трафик распределяется по обоим подам: Service балансирует соединения ingress-nginx между endpoints,
поды стоят на разных нодах (`kubectl -n bulletin-board get pods -o wide` в логах выше).

## Откат

```bash
make helm-history                      # ревизии релиза
make helm-rollback REVISION=1          # helm rollback bulletin-board 1 --wait + rollout status
```

`helm rollback` создаёт новую ревизию с манифестами выбранной; Deployment выкатывает её тем же
RollingUpdate, поэтому откат тоже проходит без простоя. Альтернатива без Helm —
`kubectl -n bulletin-board rollout undo deploy/bulletin-board`, но тогда Helm «не знает» о
состоянии, и следующий `helm upgrade` перезапишет его.
