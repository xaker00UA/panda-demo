# Panda Demo


## Repository secrets

Добавить в Settings → Secrets and variables → Actions → Repository secrets:

| Secret | Значение |
| --- | --- |
| `VPS_HOST` | IP или DNS-имя VPS |
| `VPS_USER` | SSH-пользователь с доступом к Docker |
| `VPS_SSH_KEY` | Приватный SSH-ключ без passphrase, целиком с заголовком и окончанием |
| `VPS_KNOWN_HOSTS` | Проверенная запись SSH host key сервера из `known_hosts`; для нестандартного порта адрес имеет вид `[host]:port` |
| `VPS_PORT` | SSH-порт; необязательно, по умолчанию `22` |
| `VPS_PATH` | Абсолютный путь к уже клонированному репозиторию приложения на VPS, например `/opt/panda-demo` |
| `HELM_REPO_URL` | HTTPS URL другого GitHub-репозитория, например `https://github.com/owner/helm-repo.git` |
| `HELM_REPO_TOKEN` | Fine-grained PAT с доступом к Helm-репозиторию и `Contents: Read and write` |
| `SERVICE` | Имя каталога сервиса в Helm-репозитории, например `panda-demo` |

Для публикации и скачивания образа workflow использует автоматически созданный
`GITHUB_TOKEN`: вручную добавлять его в secrets не нужно. Публикации дано
`packages: write`, VPS-деплою — `packages: read`. Пакет GHCR должен разрешать
этому репозиторию доступ; label `org.opencontainers.image.source` связывает
новый пакет с исходным репозиторием.

`HELM_REPO_TOKEN` нужен именно для другого репозитория. Его владелец должен
иметь право пушить в `main`, включая разрешения branch protection, если они
настроены. Если образ и обе переменные уже актуальны, шаг завершается без
нового коммита. Ошибки clone, commit или push завершают workflow с ошибкой.

Переменные `GIT_SHORT_HASH` и `GIT_TAG` добавляются, если их не было; остальные
переменные окружения сохраняются.

Workflow определяет `GIT_TAG` только для тега, указывающего на собираемый коммит
(`git describe --tags --exact-match`). Тег должен быть запушен в GitHub до
сборки. Если тег запушен позже коммита, запустите workflow вручную через
`workflow_dispatch` для этой ветки: push самого тега сейчас не запускает сборку.
Тег передаётся в окружение образа, VPS и Kubernetes; имя образа в GHCR использует
короткий хеш коммита, например `ghcr.io/xaker00ua/panda-demo:c6c727a`.

## Подготовка VPS

На сервере нужны Bash, Git, GNU `timeout` (пакет `coreutils`), Docker Engine и Docker Compose v2. Образ собирается
на Linux runner для `linux/amd64`; VPS должен поддерживать эту архитектуру.
Перед первым деплоем:

1. Клонировать репозиторий приложения в `VPS_PATH`.
2. Настроить для SSH-пользователя доступ к `origin`, чтобы `git fetch` и
   `git pull` работали без ввода пароля. Для приватного репозитория можно
   установить отдельный read-only deploy key на VPS.
3. Добавить публичную часть `VPS_SSH_KEY` в `authorized_keys` этого пользователя.
4. Проверить доступ пользователя к Docker без `sudo` и записать проверенный
   host key сервера в `VPS_KNOWN_HOSTS`.
5. Создать ssl сертификаты для домена `panda.wotbstats.xyz` и положить `/` на VPS.

Compose получает `APP_IMAGE` и запускает скачанный образ без локальной сборки.
Сначала выполняется `pull`, чтобы ошибка скачивания не останавливала работающее
приложение. Затем `up --force-recreate` пересоздаёт приложение и nginx; на это
время будет короткий перерыв. nginx тоже пересоздаётся, чтобы обновить адрес upstream.
Учётные данные GHCR хранятся во временном Docker config и удаляются после деплоя.

### Проверка деплоя и rollback на VPS

- Приложение отвечает `200 {"status":"ok"}` на `/healthz`. Compose проверяет
  его напрямую и через nginx каждые 5 секунд с таймаутом запроса 2 секунды.
- С начала `up` отводится общее окно **60 секунд** на запуск и наблюдение.
  Проверки не прекращаются после первого успешного ответа. Оба контейнера должны
  быть `running` и `healthy` минимум последние **10 секунд** этого окна.
- **3 рестарта** любого контейнера за окно, остановка контейнера, ошибка `up`
  или провал проверки вызывают rollback. Состояние проверяется каждые 2 секунды.
  Окончание окна между проверками само по себе не считается сбоем: учитываются
  последние подтверждённые состояния каждого сервиса, не старше 5 секунд.
  Лог `[health]` показывает изменения состояния, рестарты и длительность стабильной работы.
- До обновления сохраняются предыдущий Git-коммит, развёрнутая Compose-конфигурация
  и фактические локальные ID образов приложения и nginx. При откате восстанавливается
  этот коммит и запускаются сохранённые образы без скачивания и сборки.
  На проверку восстановленной версии отводится отдельное окно 60 секунд.
- `.env.deploy` обновляется только после успешной проверки. Даже успешный rollback
  завершает workflow с ошибкой, чтобы не скрывать неудачный релиз.
- При первом деплое откатываться некуда: неудачные контейнеры удаляются, workflow
  завершается с ошибкой. Если сам rollback не удался, в логе остаётся
  `ROLLBACK FAILED` и путь к сохранённой конфигурации для ручного восстановления.

При откате на старый релиз без healthcheck проверяется HTTP `/` напрямую и через
nginx. Наблюдение ограничено временем деплоя: последующие падения процессов
обрабатывает `restart: always`. Сам по себе статус `unhealthy` в обычном Docker
Compose не вызывает рестарт или rollback.

Для ручного повторного запуска уже скачанного образа на VPS:

Пример `.env.deploy`
```bash
APP_IMAGE=ghcr.io/xaker00ua/panda-demo:c025041
GIT_SHORT_HASH=c025041
GIT_TAG=v0.1
```
```bash
docker compose --env-file .env.deploy -f docker-compose.local.yaml up -d --no-build
```

## Локальный запуск

```bash
uv sync --locked --dev
uv run ruff format
uv run ruff check
GIT_SHORT_HASH=local uv run pytest
docker compose -f docker-compose.local.yaml up --build -d
```
или если установлен [task](https://taskfile.dev/docs/)
```bash
task
```

## Политика запуска в Kubernetes

В `deployment.yaml` добавлены:

- `startupProbe` на `/healthz`: 12 попыток каждые 5 секунд (около 60 секунд на запуск);
- `readinessProbe`: не направляет трафик в Pod, пока он не готов;
- `livenessProbe`: перезапускает зависшее приложение после 3 неудачных проверок;
- `minReadySeconds: 10`: новая реплика должна оставаться готовой без падений 10 секунд;
- `progressDeadlineSeconds: 60`: отмечает rollout как неуспешный при отсутствии прогресса;
- `maxUnavailable: 0`, `maxSurge: 1`: старая реплика остаётся, пока новая не станет доступной;
- `revisionHistoryLimit: 3`: сохраняет предыдущие ревизии для отката.

**Deployment не делает автоматический rollback.** `progressDeadlineSeconds` —
таймаут отсутствия прогресса, а не строгий общий таймер деплоя. Для прямого деплоя
из CI откат можно выполнить отдельным шагом после `apply`:

```bash
if ! kubectl -n panda rollout status deployment/panda-demo --timeout=60s; then
  kubectl -n panda rollout undo deployment/panda-demo
  kubectl -n panda rollout status deployment/panda-demo --timeout=60s
  exit 1
fi
```

Такой шаг требует существующей предыдущей ревизии. `rollout status` заканчивается,
когда rollout готов; для наблюдения все 60 секунд и ограничения числа рестартов,
как на VPS, нужна дополнительная проверка Pod или контроллер progressive delivery.
Поведение probes и Deployment описано в
[документации Kubernetes](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/).

Текущий workflow обновляет `apps/$SERVICE/deployment.yaml` **в другом репозитории**
и меняет там только образ и переменные. Политику probes и rollout нужно также
перенести в тот манифест. Если кластер синхронизирует Argo CD или Flux, для
постоянного отката нужно вернуть предыдущий образ и переменные в Git: синхронизация
может отменить ручной `kubectl rollout undo`.


