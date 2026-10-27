# Секреты: Yandex Lockbox + External Secrets Operator

## Что секретно и где лежит

| Значение | Источник правды | Как попадает в под |
| --- | --- | --- |
| `SPRING_DATASOURCE_URL` | Lockbox (Terraform пишет FQDN мастера Managed PostgreSQL) | ESO → Secret `bulletin-board-secrets` → `envFrom` |
| `SPRING_DATASOURCE_USERNAME`, `SPRING_DATASOURCE_PASSWORD` | Lockbox (пароль генерирует `random_password`) | то же |
| `STORAGE_S3_ACCESSKEY`, `STORAGE_S3_SECRETKEY` | Lockbox (статический ключ SA `storage`) | то же |
| ключ SA ESO (`authorized-key`) | `terraform output eso_sa_key_json` | `make yc-eso-auth` → Secret `yc-auth` (единственный секрет, создаваемый вне Lockbox: им ESO и ходит в Lockbox) |
| имя бакета, регион, endpoint, профиль Spring | не секрет | ConfigMap из `values*.yaml` |

В репозитории нет реальных секретов: `values.yaml` содержит плейсхолдеры `change-me`, `values-yc.yaml` —
пустой `lockboxSecretId` (подставляется из `terraform output`). Заглушка `local-dev-only` в
`k8s/manifests/secret.yaml` и `k8s/local/postgres.yaml` — пароль одноразовой локальной БД в kind.
Terraform state содержит значения секретов, поэтому хранится только в бакете Object Storage
(S3-бекенд), не в git.

## Права

- SA `bulletin-board-eso` получает `lockbox.payloadViewer` **на один секрет** (`yandex_lockbox_secret_iam_member`),
  не на каталог.
- Авторизованный ключ этого SA — в Secret `yc-auth` namespace приложения; читать его может только ESO
  (`SecretStore` ссылается на него в том же namespace).
- Секреты Kubernetes в etcd шифруются ключом KMS (`kms_provider` кластера).

## Схема

```text
Lockbox secret (versions)            kind: Secret lockbox-emulator/bulletin-board-app
          │  yandexlockbox                        │  kubernetes (RBAC: get один Secret)
          ▼                                       ▼
   SecretStore bulletin-board  ───────────────────┘
          │
   ExternalSecret bulletin-board (refreshInterval 1m, локально 15s; dataFrom.extract — все ключи)
          │
   Secret bulletin-board-secrets  ──envFrom──>  Deployment bulletin-board
          │ изменился
   Reloader (аннотация secret.reloader.stakater.com/reload) ──> RollingUpdate подов
```

Чарт: `externalSecrets.enabled`, `externalSecrets.provider` = `yandexlockbox` | `kubernetes` | `fake`
(`templates/externalsecret.yaml`), `reloader.enabled` (аннотация в `templates/deployment.yaml`).

## Установка в облаке

```bash
make addons-yc            # ingress-nginx + ESO + Reloader
make yc-eso-auth          # Secret yc-auth из terraform output eso_sa_key_json
make helm-install ENV=yc TAG=1.0.0 INGRESS_HOST=...
make eso-status           # SecretStore Valid, ExternalSecret SecretSynced
```

## Ротация

### Yandex Cloud (`make yc-rotate`, `scripts/rotate-yc.sh`)

1. `yc managed-postgresql user update bulletins --password <новый>` — пароль в БД.
2. `yc lockbox secret add-version` — новая версия секрета: тот же набор ключей, новый пароль.
3. ESO за `refreshInterval` (1 мин) перечитывает Lockbox и обновляет Secret.
4. Reloader перезапускает Deployment RollingUpdate-ом: новые поды стартуют с новым паролем,
   старые до остановки работают на уже открытых соединениях пула. Простоя нет.
5. Проверка: `make eso-status`, `kubectl -n bulletin-board rollout status deploy/bulletin-board`,
   опрос `scripts/probe.sh` по внешнему адресу во время ротации.

Terraform не перетирает версии, созданные при ротации (`lifecycle { ignore_changes = [entries] }`
у `yandex_lockbox_secret_version`). Облачная процедура не выполнялась — облачного стенда нет.

### Локально (проверено, `make rotate-local`, `scripts/rotate-local.sh`)

Те же шаги, только источник — Secret `lockbox-emulator/bulletin-board-app`, а пароль меняется
`ALTER USER` в PostgreSQL кластера. Результат ([evidence/04-secret-rotation.txt](evidence/04-secret-rotation.txt)):

- ESO обновил `bulletin-board-secrets` (хеш пароля до/после различается, ExternalSecret `SecretSynced`);
- Reloader записал в лог `Changes detected in 'bulletin-board-secrets' ... updated 'bulletin-board'`;
- поды пересозданы RollingUpdate-ом и подключились к БД с новым паролем;
- опрос через ingress в течение 150 с: 604 запроса, все HTTP 200.

Почему не `checksum/secret`-аннотация: Secret создаёт ESO, Helm его содержимого не знает, а ротация
идёт мимо `helm upgrade`. Поэтому перезапуск по изменению Secret делает Reloader.
