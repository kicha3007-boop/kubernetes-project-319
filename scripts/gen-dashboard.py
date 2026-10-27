"""Генерирует дашборд Grafana для Helm-чарта.

    python scripts/gen-dashboard.py k8s/bulletin-board/files/dashboard.json

__NAMESPACE__, __SERVICE__, __INGRESS__ подставляет шаблон templates/grafana-dashboard.yaml.
"""
import json, sys
DS = {"type": "prometheus", "uid": "${datasource}"}
APP = 'namespace="__NAMESPACE__", service="__SERVICE__", uri!~"/actuator.*"'
panels = []
pid = [0]
def nid():
    pid[0] += 1
    return pid[0]
def stat(title, expr, x, unit, w=6, thresholds=None, desc=""):
    p = {"id": nid(), "type": "stat", "title": title, "description": desc, "datasource": DS,
         "gridPos": {"h": 4, "w": w, "x": x, "y": 0},
         "targets": [{"refId": "A", "expr": expr, "datasource": DS}],
         "fieldConfig": {"defaults": {"unit": unit, "decimals": 2,
             "thresholds": {"mode": "absolute", "steps": thresholds or [{"color": "green", "value": None}]}},
             "overrides": []},
         "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                     "colorMode": "value", "graphMode": "area", "textMode": "auto"}}
    panels.append(p)
def ts(title, targets, x, y, unit, w=12, h=8, desc=""):
    p = {"id": nid(), "type": "timeseries", "title": title, "description": desc, "datasource": DS,
         "gridPos": {"h": h, "w": w, "x": x, "y": y},
         "targets": [{"refId": chr(65+i), "expr": e, "legendFormat": l, "datasource": DS} for i, (e, l) in enumerate(targets)],
         "fieldConfig": {"defaults": {"unit": unit, "custom": {"lineWidth": 1, "fillOpacity": 10, "showPoints": "never"}}, "overrides": []},
         "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
                     "tooltip": {"mode": "multi", "sort": "desc"}}}
    panels.append(p)

stat("Доступные реплики", 'kube_deployment_status_replicas_available{namespace="__NAMESPACE__", deployment="__SERVICE__"}', 0, "none",
     thresholds=[{"color": "red", "value": None}, {"color": "orange", "value": 1}, {"color": "green", "value": 2}])
stat("Запросов в секунду (API)", f'sum(rate(http_server_requests_seconds_count{{{APP}}}[5m]))', 6, "reqps")
stat("Доля 5xx (API)", f'(sum(rate(http_server_requests_seconds_count{{{APP}, status=~"5.."}}[5m])) or vector(0)) / clamp_min(sum(rate(http_server_requests_seconds_count{{{APP}}}[5m])), 1e-9)', 12, "percentunit",
     thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 0.01}, {"color": "red", "value": 0.05}])
stat("Latency p95 (API)", f'histogram_quantile(0.95, sum by (le) (rate(http_server_requests_seconds_bucket{{{APP}}}[5m])))', 18, "s",
     thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 0.3}, {"color": "red", "value": 0.5}])

ts("Запросы к API по кодам ответа", [(f'sum by (status) (rate(http_server_requests_seconds_count{{{APP}}}[5m]))', "{{status}}")], 0, 4, "reqps")
ts("Ingress-nginx: запросы по кодам ответа", [('sum by (status) (rate(nginx_ingress_controller_requests{ingress="__INGRESS__"}[5m]))', "{{status}}")], 12, 4, "reqps")
ts("Latency API (p50 / p95 / p99)", [
    (f'histogram_quantile(0.50, sum by (le) (rate(http_server_requests_seconds_bucket{{{APP}}}[5m])))', "p50"),
    (f'histogram_quantile(0.95, sum by (le) (rate(http_server_requests_seconds_bucket{{{APP}}}[5m])))', "p95"),
    (f'histogram_quantile(0.99, sum by (le) (rate(http_server_requests_seconds_bucket{{{APP}}}[5m])))', "p99")], 0, 12, "s")
ts("Ingress-nginx: latency p95 по ingress", [('histogram_quantile(0.95, sum by (le) (rate(nginx_ingress_controller_request_duration_seconds_bucket{ingress="__INGRESS__"}[5m])))', "p95")], 12, 12, "s")
ts("CPU по подам", [('sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="__NAMESPACE__", pod=~"__SERVICE__-.*", container="app"}[5m]))', "{{pod}}")], 0, 20, "cores")
ts("Память по подам (working set)", [('sum by (pod) (container_memory_working_set_bytes{namespace="__NAMESPACE__", pod=~"__SERVICE__-.*", container="app"})', "{{pod}}")], 12, 20, "bytes")
ts("JVM heap", [('sum by (pod) (jvm_memory_used_bytes{namespace="__NAMESPACE__", service="__SERVICE__", area="heap"})', "{{pod}} used"),
                ('sum by (pod) (jvm_memory_max_bytes{namespace="__NAMESPACE__", service="__SERVICE__", area="heap"})', "{{pod}} max")], 0, 28, "bytes")
ts("Рестарты контейнеров (за 15 мин)", [('sum by (pod) (increase(kube_pod_container_status_restarts_total{namespace="__NAMESPACE__", pod=~"__SERVICE__-.*"}[15m]))', "{{pod}}")], 12, 28, "none")
ts("HPA: реплики", [('kube_horizontalpodautoscaler_status_current_replicas{namespace="__NAMESPACE__", horizontalpodautoscaler="__SERVICE__"}', "current"),
                   ('kube_horizontalpodautoscaler_status_desired_replicas{namespace="__NAMESPACE__", horizontalpodautoscaler="__SERVICE__"}', "desired"),
                   ('kube_horizontalpodautoscaler_spec_max_replicas{namespace="__NAMESPACE__", horizontalpodautoscaler="__SERVICE__"}', "max")], 0, 36, "none", w=24)

dash = {
    "uid": "bulletin-board", "title": "Доска объявлений", "tags": ["bulletin-board"], "timezone": "browser",
    "schemaVersion": 39, "version": 1, "editable": True, "refresh": "30s",
    "time": {"from": "now-1h", "to": "now"},
    "templating": {"list": [{"name": "datasource", "label": "Источник", "type": "datasource", "query": "prometheus",
                              "current": {}, "hide": 0, "refresh": 1}]},
    "annotations": {"list": []},
    "panels": panels,
}
json.dump(dash, open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False, indent=2)
