# Лаборатория Docker Swarm HA (VirtualBox + Terraform + Ansible)

Этот каталог содержит полный bootstrap для изолированного кластера Docker Swarm:
- 3 manager-ноды
- 2 worker-ноды
- 2 LB-ноды (HAProxy + Keepalived VIP)

Поток развертывания:
1. Terraform клонирует VM из golden-шаблона в VirtualBox.
2. Для каждой ноды cloud-init seed ISO добавляет SSH-ключ и включает SSH hardening (только key-based вход).
3. Ansible устанавливает Docker, инициализирует Swarm, присоединяет ноды, настраивает LB.

## Отслеживание проекта

Текущий прогресс, оставшиеся задачи и журнал изменений ведутся в файле:

- `infra/PROJECT_STATUS.md`

## 1) Безопасно подготовьте golden VM

Перед созданием финального snapshot выполните в шаблонной VM:

```bash
sudo rm -f /home/naurlox/.ssh/authorized_keys
sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker.io docker-doc docker-compose podman-docker || true
sudo rm -f /etc/apt/sources.list.d/docker.list
sudo apt-get autoremove -y
sudo rm -f /etc/ssh/ssh_host_*key*
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id
sudo cloud-init clean --logs
sudo sync
sudo poweroff
```

После этого создайте или обновите snapshot `GOLDEN-CLEAN`.

Важно: не удаляйте доступ, пока не проверите cloud-init bootstrap хотя бы на одном клоне.

Практика:
- golden VM лучше держать без установленного Docker и без Docker APT repo;
- Docker должен приходить из Ansible, иначе на первом прогоне playbook тратит время на удаление `docker-ce/containerd.io` и может упереться в `dpkg` lock на незавершенном или прерванном `apt`;
- preflight в `01-bootstrap-ssh.yml` теперь ждет завершения `cloud-init`, а `02-docker.yml` дополнительно лечит зависшие `apt`-процессы после прерванных прогонов.

## 2) Требования

Хост (Windows):
- VirtualBox + `VBoxManage` в PATH
- Terraform в PATH
- PowerShell 5+

WSL (рекомендуется Ubuntu):
- `ansible`
- `cloud-localds` (из `cloud-image-utils`) или `genisoimage`

Установка в WSL:

```bash
sudo apt update
sudo apt install -y ansible cloud-image-utils genisoimage
```

## 3) Настройка переменных

Путь к ключу по умолчанию уже задан:

```text
/mnt/c/Users/YOUR_WINDOWS_USER/.ssh/id_ed25519.pub
```

Скопируйте `infra/terraform/terraform.tfvars.example` в `infra/terraform/terraform.tfvars` и при необходимости отредактируйте:

```hcl
template_vm_name    = "ubuntu-22.04-docker-template"
host_only_adapter   = "VirtualBox Host-Only Ethernet Adapter"
ssh_public_key_path = "/mnt/c/Users/YOUR_WINDOWS_USER/.ssh/id_ed25519.pub"
vm_name_prefix      = "kp"

cluster_cidr          = "192.168.56.0/24"
cluster_prefix_length = 24
manager_ip_start      = 11
worker_ip_start       = 21
lb_ip_start           = 31

hostonly_guest_interface = "enp0s3"
nat_guest_interface      = "enp0s8"
```

Рекомендуемый профиль для задания:

```hcl
managers_count = 3
workers_count  = 2
lbs_count      = 2
```

Почему именно так:
- `3 manager` — минимально достаточный состав для кворума Raft; кластер переживает отказ одного manager;
- `2 worker` — достаточно для репликации прикладных сервисов и демонстрации failover;
- `2 lb` — убирают single point of failure на входном слое и позволяют VIP переключаться между LB.

Важно: сетевые переменные в Terraform теперь обязательны (без `terraform.tfvars` или `-var` запуск `plan/apply` завершится ошибкой).

## 3.1) Сетевая схема

В проекте у каждой VM два сетевых адаптера:

1. `Adapter 1 = Host-Only`
   - на стороне хоста VirtualBox задается через `host_only_adapter`;
   - внутри гостевой Ubuntu это интерфейс `hostonly_guest_interface` (по умолчанию `enp0s3`);
   - получает статический IP из `cluster_cidr`;
   - используется для:
     - SSH с хоста;
     - межнодового трафика Swarm;
     - VIP `192.168.56.10`;
     - backend-трафика HAProxy.

2. `Adapter 2 = NAT`
   - на стороне VirtualBox включается автоматически, отдельное имя адаптера в `terraform.tfvars` не требуется;
   - внутри гостевой Ubuntu это интерфейс `nat_guest_interface` (по умолчанию `enp0s8`);
   - получает адрес по DHCP;
   - используется как исходящий канал в интернет для `apt`, скачивания пакетов и bootstrap.

Важно:
- `host_only_adapter` в `terraform.tfvars` не описывает всю сетевую схему целиком, а только имя host-only адаптера на Windows-хосте;
- NAT у тебя уже есть и настраивается в `infra/scripts/new-vm.ps1`;
- в терминах задания это изолированный стенд с отдельным внутренним сегментом для кластера и отдельным egress-каналом наружу;
- если нужен строго air-gapped профиль без выхода в интернет, NAT придется отключать и готовить локальные зеркала/образы заранее.

## 4) Развернуть VM (Terraform)

В PowerShell:

```powershell
cd infra/terraform
terraform init
terraform apply
```

## 5) Сгенерировать Ansible inventory из Terraform outputs

В PowerShell:

```powershell
cd ..\scripts
.\tf-output-to-inventory.ps1
```

Inventory будет создан в `infra/ansible/inventory/hosts.ini`.
Скрипт по умолчанию только генерирует inventory.
Если нужно сразу обновить `known_hosts`, используйте:

```powershell
.\tf-output-to-inventory.ps1 -RefreshKnownHosts
```

## 6) Запустить Ansible из WSL

В PowerShell:

```powershell
cd ..\scripts
.\run-ansible-from-wsl.ps1
```

Или вручную из WSL:

```bash
cd /mnt/c/Users/YOUR_WINDOWS_USER/Desktop/Kwork_labs/KP/infra/ansible
ANSIBLE_CONFIG=$PWD/ansible.cfg ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i inventory/hosts.ini playbooks/site.yml
```

`run-ansible-from-wsl.ps1` перед запуском playbook синхронизирует Windows `known_hosts`, чтобы после пересоздания VM не требовался ручной `ssh-keygen -R`.

После успешного прогона playbook скрипт дополнительно вызывает `infra/scripts/rebalance-swarm-services.ps1`:
- он ищет сервисы с label `com.kp.auto_rebalance=true`;
- если восстановившийся worker уже `Ready/Active`, но на нем нет задач такого сервиса, скрипт запускает rolling rebalance через `docker service update --force`;
- это не "мгновенный перенос задач", а штатный rolling restart выбранных сервисов.

## 7) Проверка

На manager-01:

```bash
docker node ls
```

Развернуть тестовый сервис:

```bash
docker service create --name web --replicas 3 -p 80:80 nginx
```

Откройте `http://192.168.56.10` (VIP) с хоста.

Примечания:
- если backend-сервис на `:80` еще не развернут, VIP может возвращать `503` от HAProxy — это означает, что входной слой жив, но публикуемого приложения за ним пока нет;
- если сервис помечен label `com.kp.auto_rebalance=true`, `run-ansible-from-wsl.ps1` после успешного подключения к восстановившимся нодам попробует запустить rolling rebalance автоматически;
- если нужен ручной rebalance без Ansible, используйте:

```bash
cd infra/scripts
.\rebalance-swarm-services.ps1
```

- текущий `infra/ansible/templates/haproxy.cfg.j2` маршрутизирует HTTP только на workers; это ближе к production-практике и не смешивает прикладной трафик с manager control plane;
- manager backend в HAProxy остается отдельным и используется только для `:2377` (join/control plane);
- если в кластере нет ни одного worker, playbook `04-haproxy-keepalived.yml` теперь завершится явной ошибкой, а не создаст пустой HTTP backend.

## 7.1) Docker Stack для прикладных сервисов

Для ручного smoke-теста достаточно `docker service create`, но для своих приложений лучше использовать `docker stack deploy` и хранить стек в Git.

Минимальный пример:

```yaml
version: "3.8"

services:
  web:
    image: nginx:alpine
    ports:
      - "80:80"
    deploy:
      replicas: 3
      placement:
        constraints:
          - node.role == worker
      restart_policy:
        condition: any
    networks:
      - app_net

networks:
  app_net:
    driver: overlay
    attachable: true
```

Команды:

```bash
docker stack deploy -c stack.yml app
docker stack services app
docker stack ps app
docker service scale app_web=5
docker stack rm app
```

Практика:
- выполнять `docker stack deploy` нужно с manager-ноды;
- для прикладных сервисов лучше задавать `placement.constraints`, чтобы не размещать нагрузку на managers без необходимости;
- при нескольких сервисах в одном стеке удобнее версионировать их вместе, чем управлять каждым через отдельные `docker service create/update`.
- текущая конфигурация HAProxy уже соответствует этому подходу: HTTP трафик идет только на worker-ноды.
- если хотите, чтобы сервис автоматически участвовал в post-recovery rebalance после возврата worker-ноды, добавьте label:

```yaml
deploy:
  labels:
    com.kp.auto_rebalance: "true"
```

### Практический пример: стек `pageview`

Текущий тестовый сервис находится в:

- `infra/test/docker-stack.yml`
- `infra/test/react-monitoring-demo/`

Текущий образ:

```text
naurlox123/naurlox:pageview-v1
```

Важно:
- `docker stack deploy` нужно запускать на manager-ноду;
- stack-файл должен существовать на самой manager-ноде;
- переменная `PAGE_VIEW_IMAGE` должна быть экспортирована в той же shell-сессии, где выполняется `docker stack deploy`.

Пример из Windows-хоста:

```powershell
scp .\infra\test\docker-stack.yml naurlox@192.168.56.11:~/docker-stack.yml
ssh naurlox@192.168.56.11
```

Дальше на manager:

```bash
export PAGE_VIEW_IMAGE=naurlox123/naurlox:pageview-v1
docker stack deploy -c ~/docker-stack.yml pageview
```

Проверка:

```bash
docker stack services pageview
docker service ps pageview_page_view_demo
docker service inspect pageview_page_view_demo --format '{{json .Spec.Labels}}'
```

Ожидаемо:
- label `com.kp.auto_rebalance=true` присутствует;
- при `3 replicas` и `2 workers` итоговая раскладка будет `2+1`, а не `1+1+1`.

Замечание по warning:

```text
image ... could not be accessed on a registry to record its digest
```

Для лабораторного стенда это допустимо. Для более строгого режима лучше использовать immutable tag или deploy по digest.

#### Endpoint-ы `pageview`

Сервис публикуется в ingress mode на `3000` и `3001`.

Прямой доступ через любую Swarm-ноду:

```text
http://192.168.56.11:3000/
http://192.168.56.12:3000/
http://192.168.56.21:3000/
http://192.168.56.22:3000/

http://192.168.56.11:3001/
http://192.168.56.12:3001/
http://192.168.56.21:3001/
http://192.168.56.22:3001/
```

Поддерживаемые endpoint-ы приложения:

```text
/
/api/stats
/health
/metrics
```

Примеры:

```bash
curl http://192.168.56.11:3000/
curl http://192.168.56.11:3000/api/stats
curl http://192.168.56.11:3000/health
curl http://192.168.56.11:3000/metrics
```

Проверка фактической балансировки:

```bash
for i in {1..10}; do curl -s http://127.0.0.1:3000/api/stats; echo; done
```

Если в ответах меняется `hostname`, значит routing mesh реально распределяет запросы по разным репликам.

Проверка размещения контейнеров по worker-нодам:

```powershell
ssh naurlox@192.168.56.21 "docker ps --format 'table {{.Names}}\t{{.Status}}'"
ssh naurlox@192.168.56.22 "docker ps --format 'table {{.Names}}\t{{.Status}}'"
```

Ребаланс:

```bash
docker service update --force pageview_page_view_demo
```

или из Windows:

```powershell
cd infra\scripts
.\rebalance-swarm-services.ps1
```

Поведение:
- при отказе одного worker Swarm пересоздаст недостающую задачу на оставшемся worker;
- после возврата worker автоматического rebalance в самом Swarm нет;
- в этом проекте rebalance делается через rolling `docker service update --force` для сервисов с label `com.kp.auto_rebalance=true`.

Полный lifecycle- и failover-runbook для `pageview` вынесен в:

- [infra/test/README.md](C:\Users\Nvidia\Desktop\Kwork_labs\KP\infra\test\README.md)

Там собраны отдельные команды для:
- `deploy / restart / stop / start / remove`;
- проверки worker failover;
- проверки manager quorum;
- проверки failover балансировщика и сохранения VIP.

### Как гонять 5-10 HTTP-сервисов через один VIP

Для нескольких HTTP-сервисов не нужно поднимать отдельный VIP или отдельный внешний порт на каждый сервис.

Нормальная схема такая:
- снаружи у вас один VIP, обычно `80/443`;
- HAProxy на LB смотрит на `Host` header или path;
- дальше он отправляет трафик на опубликованный ingress-порт нужного сервиса на worker-нодах;
- routing mesh Swarm уже доставляет запрос до живой реплики.

В проект уже добавлена заготовка для такого режима через переменную `haproxy_http_routes` в `infra/ansible/group_vars/all.yml`.

Пример:

```yaml
haproxy_http_routes:
  - name: pageview
    host: pageview.local
    backend_port: 3000
#  - name: api
#    host: api.local
#    backend_port: 8080
```

После этого примените только HAProxy/Keepalived:

```powershell
cd infra\scripts
.\run-ansible-from-wsl.ps1 -Playbook playbooks/04-haproxy-keepalived.yml
```

Проверка с хоста:

```powershell
curl -H "Host: pageview.local" http://192.168.56.10/
# после включения api.local и деплоя сервиса на :8080
curl -H "Host: api.local" http://192.168.56.10/
```

Текущее фактически проверенное состояние стенда:
- в `infra/ansible/group_vars/all.yml` уже включен маршрут:

```yaml
haproxy_http_routes:
  - name: pageview
    host: pageview.local
    backend_port: 3000
```

- после применения `playbooks/04-haproxy-keepalived.yml` подтверждено:
  - `api.local` пока оставлен в виде шаблона и не включается по умолчанию, пока в Swarm нет реального backend-сервиса на `:8080`;
  - иначе HAProxy начнет честно показывать отдельный backend в статусе `DOWN`, что в текущем стенде будет просто шумом;
  - `curl -H "Host: pageview.local" http://192.168.56.10/api/stats` возвращает ответ приложения;
  - в HAProxy stats backend `pageview_backend` находится в статусе `UP`;
  - backend `swarm_http_nodes` при этом может оставаться `DOWN`, если на `:80` нет отдельного сервиса, и это нормально.

После настройки маршрута для `pageview` за VIP будут доступны те же endpoint-ы приложения:

```powershell
curl -H "Host: pageview.local" http://192.168.56.10/
curl -H "Host: pageview.local" http://192.168.56.10/api/stats
curl -H "Host: pageview.local" http://192.168.56.10/health
curl -H "Host: pageview.local" http://192.168.56.10/metrics
```

Если хотите открывать сервисы из браузера без ручного `Host` header, добавьте локальные DNS/hosts-записи на Windows для нужных имен на `192.168.56.10`.

Итог:
- для 5-10 HTTP-сервисов используйте один VIP и host-based routing;
- отдельные frontend/backend по портам нужны только для TCP-сервисов или если вы осознанно хотите разные внешние порты.

## 7.2) Секреты и Ansible Vault

Сейчас переменная `keepalived_auth_pass` хранится открытым текстом в `infra/ansible/group_vars/all.yml`. Для лабораторного стенда это допустимо, но для более строгой практики лучше вынести секреты в `Ansible Vault`.

Минимальный путь:

```bash
ansible-vault encrypt_string 'SWarmPass123' --name 'keepalived_auth_pass'
```

Дальше:
- заменить открытое значение в `group_vars/all.yml` на зашифрованный блок;
- запускать playbook с `--ask-vault-pass` или `--vault-password-file`;
- тем же способом хранить пароли приложений, токены API и другие секреты для будущих `docker stack` сервисов.

## 7.3) HAProxy Stats Page

В конфигурации LB включена отдельная read-only stats page HAProxy.

Доступ:

```text
http://192.168.56.31:8404/stats
http://192.168.56.32:8404/stats
```

Текущие учетные данные по умолчанию:

```text
admin / admin
```

Что важно:
- это отдельный `listen haproxy_stats`, а не приложение за обычным HTTP frontend;
- страница слушает только `ansible_host` LB-ноды;
- runtime admin-команды не включены, страница остается read-only;
- для реального окружения пароль нужно заменить и вынести в `Ansible Vault`.

## 7.4) Готовый Сценарий Демонстрации

Ниже один готовый сценарий для защиты. Он показывает:
- что кластер поднят;
- что сервис реплицирован;
- что доступ через VIP работает;
- что отказ worker не ломает сервис;
- что отказ одного manager не ломает quorum;
- что отказ active LB не ломает входной доступ.

Для наглядной балансировки лучше использовать не `nginx`, а `traefik/whoami`, потому что он возвращает hostname контейнера в ответе.

### Шаг 1. Проверка кластера

На `manager-01`:

```bash
sudo docker node ls
sudo docker service ls
```

Что показать:
- `3 manager`, из них один `Leader`, остальные `Reachable`;
- `2 worker` в статусе `Ready/Active`.

### Шаг 2. Развернуть демонстрационный сервис

Если `web` уже есть, сначала удалить:

```bash
sudo docker service rm web || true
```

Потом создать сервис:

```bash
sudo docker service create \
  --name web \
  --replicas 3 \
  --constraint 'node.role==worker' \
  -p 80:80 \
  traefik/whoami
```

Проверка:

```bash
sudo docker service ls
sudo docker service ps web
```

Что показать:
- `web` в статусе `3/3`;
- реплики размещены на worker-нодах.

### Шаг 3. Показать доступ через VIP и балансировку

С Windows-хоста:

```powershell
curl http://192.168.56.10
```

Для наглядности несколько запросов подряд:

```powershell
1..10 | ForEach-Object { curl http://192.168.56.10 }
```

Что показать:
- ответы приходят через `VIP 192.168.56.10`;
- в выводе `whoami` меняется `Hostname`, значит HAProxy и Swarm действительно распределяют запросы между репликами.

### Шаг 4. Проверка отказа worker без потери сервиса

На `manager-01`:

```bash
sudo docker node update --availability drain kp-worker-01
sudo docker service ps web
```

С Windows-хоста:

```powershell
1..10 | ForEach-Object { curl http://192.168.56.10 }
```

Что показать:
- `kp-worker-01` выведен из размещения задач;
- Swarm переразмещает реплики на оставшиеся worker-ноды;
- сервис по `VIP` продолжает отвечать.

Вернуть worker обратно:

```bash
sudo docker node update --availability active kp-worker-01
sudo docker service update --force web
sudo docker service ps web
```

### Шаг 5. Проверка quorum: отказ одного manager

С Windows-хоста:

```powershell
VBoxManage controlvm kp-manager-02 poweroff
```

На живом manager:

```bash
sudo docker node ls
sudo docker service ls
sudo docker service ps web
```

С Windows-хоста:

```powershell
curl -I http://192.168.56.10
```

Что показать:
- при `3 manager` кластер переживает отказ одного manager;
- команды Swarm продолжают работать;
- сервис остается доступен.

Вернуть manager:

```powershell
VBoxManage startvm kp-manager-02 --type headless
```

### Шаг 6. Проверка failover LB

Сначала определить, на каком LB сейчас VIP:

```bash
ssh naurlox@192.168.56.31 "ip a | grep 192.168.56.10 || true"
ssh naurlox@192.168.56.32 "ip a | grep 192.168.56.10 || true"
```

Выключить active LB через Windows:

```powershell
VBoxManage controlvm kp-lb-01 poweroff
```

или, если VIP был на `kp-lb-02`:

```powershell
VBoxManage controlvm kp-lb-02 poweroff
```

С Windows-хоста:

```powershell
curl -I http://192.168.56.10
```

Что показать:
- VIP переехал на второй LB;
- клиент продолжает ходить на тот же `192.168.56.10`;
- сервис остается доступен.

Вернуть LB:

```powershell
VBoxManage startvm kp-lb-01 --type headless
```

или:

```powershell
VBoxManage startvm kp-lb-02 --type headless
```

### Шаг 7. Финальная очистка после демонстрации

Если временный сервис больше не нужен:

```bash
sudo docker service rm web
```

Если нужен повторный прогон LB-конфигов после жестких выключений:

```powershell
cd infra\scripts
.\run-ansible-from-wsl.ps1 -Playbook playbooks/04-haproxy-keepalived.yml
```

Ограничение сценария:
- не выключайте одновременно два manager при конфигурации `3 manager`, иначе quorum будет потерян;
- если хотите показать именно балансировку, а не только отказоустойчивость, используйте `whoami`, а не обычный `nginx`.

## 8) Операционные команды (runbook)

### Полный старт с нуля

```powershell
cd infra/terraform
terraform init
terraform apply

cd ..\scripts
.\tf-output-to-inventory.ps1
.\run-ansible-from-wsl.ps1
```

### Проверка состояния

```powershell
VBoxManage list runningvms
terraform -chdir=infra/terraform output
```

```powershell
cd infra\scripts
.\run-ansible-from-wsl.ps1 -Playbook playbooks/03-swarm.yml
```

```bash
# из WSL
ssh naurlox@192.168.56.11 "sudo docker node ls"
curl -I http://192.168.56.10
```

### Внести изменения в конфиг и применить

1. Измените параметры в `infra/terraform/terraform.tfvars` (IP диапазоны, интерфейсы, размеры VM, counts).
2. Если меняли cloud-init шаблоны, увеличьте `bootstrap_revision` (например `v6` -> `v7`), чтобы пересобрались seed ISO.
3. Примените:

```powershell
cd infra/terraform
terraform apply
cd ..\scripts
.\tf-output-to-inventory.ps1
.\run-ansible-from-wsl.ps1
```

### Масштабирование нод внутри кластера

1. Обновите в `infra/terraform/terraform.tfvars`:
   - `managers_count`
   - `workers_count`
   - `lbs_count`
2. Рекомендуется держать `managers_count` нечетным (3 или 5) для кворума.
3. Примените:

```powershell
cd infra/terraform
terraform apply
cd ..\scripts
.\tf-output-to-inventory.ps1
.\run-ansible-from-wsl.ps1 -Playbook playbooks/03-swarm.yml
.\run-ansible-from-wsl.ps1 -Playbook playbooks/04-haproxy-keepalived.yml
```

4. Проверьте:

```bash
ssh naurlox@192.168.56.11 "sudo docker node ls"
```

### Сокращение числа нод (scale down)

1. Уменьшите `*_count` в `terraform.tfvars` и выполните `terraform apply`.
2. На manager удалите `Down` ноды из Swarm:

```bash
ssh naurlox@192.168.56.11 "sudo docker node ls"
ssh naurlox@192.168.56.11 "sudo docker node rm --force <NODE_NAME>"
```

### Отдельный дополнительный кластер (второй стенд)

Используйте другой `vm_name_prefix` и другую подсеть (`cluster_cidr`), чтобы кластеры не пересекались по именам VM и IP.

## Удаление окружения

В PowerShell:

```powershell
cd infra/terraform
terraform destroy
```

## Примечания

- Парольная аутентификация отключается через cloud-init и дополнительно фиксируется Ansible.
- Не храните статический `authorized_keys` в golden VM.
- Если имена интерфейсов гостевой ОС отличаются от `enp0s3/enp0s8`, меняйте их в `terraform.tfvars`:
  - `hostonly_guest_interface`
  - `nat_guest_interface`
- Для Keepalived интерфейс берется из `infra/ansible/group_vars/all.yml` через `vip_interface` (по умолчанию = `hostonly_guest_interface`).

## 9) Миграция в VMware (опционально)

Рекомендуемый порядок миграции после стабилизации VirtualBox-стенда:

1. Создать отдельный модуль `infra/terraform-vsphere` (не ломая текущий `infra/terraform`).
2. Перенести слой создания VM на провайдер `hashicorp/vsphere` (template, datastore, network).
3. Оставить существующие Ansible playbook-файлы без изменений, подавая inventory из нового terraform output.
4. Для VIP/Keepalived в vSwitch/Port Group учесть политики `Promiscuous Mode`, `MAC Address Changes`, `Forged Transmits`.
5. После успешной проверки failover сделать VMware основным вариантом, VirtualBox оставить как учебный стенд.

## 10) Диагностика типовых проблем

### Все ноды получили один IP (например, `192.168.56.109`)
- Причина: в golden VM остался старый state (`cloud-init`, `netplan`, `machine-id`), который наследуют клоны.
- Дополнительная причина (Windows PowerShell 5): `user-data` в seed ISO может записываться с BOM, и cloud-init игнорирует такой YAML.
- Внешняя причина: конфликт маршрутов (VPN/оверлей-сети) с подсетью `192.168.56.0/24`; адрес `192.168.56.109` может оказаться не вашей VM.
- Решение: очистить golden VM перед snapshot и пересоздать ноды:

```bash
sudo cloud-init clean --logs --seed
sudo rm -rf /var/lib/cloud/*
sudo rm -f /etc/netplan/00-installer-config.yaml /etc/netplan/50-cloud-init.yaml
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id
sudo rm -f /etc/ssh/ssh_host_*
sudo poweroff
```

После этого:

```powershell
cd infra/terraform
terraform apply -var "bootstrap_revision=v2"
```

Проверка признака BOM-проблемы внутри ноды:

```bash
cloud-init status --long
# Если есть предупреждение:
# Unhandled non-multipart ... '\ufeff#cloud-config'
# значит user-data был с BOM и не был корректно применен
```

Проверка на конфликт маршрутов в Windows:

```powershell
ping -n 2 192.168.56.109
ping -n 2 -S 192.168.56.1 192.168.56.109
```

Если без `-S` есть ответ, а с `-S 192.168.56.1` получаете `Destination host unreachable`, то это внешний маршрут/адаптер, а не ваш VirtualBox кластер.

### SSH закрывается до авторизации (`kex_exchange_identification: Connection closed by remote host`)
- Обычно не сгенерированы host keys OpenSSH в гостевой ОС.
- Проверка и исправление в консоли ВМ:

```bash
sudo ssh-keygen -A
sudo systemctl restart ssh
sudo systemctl status ssh --no-pager
ls -l /etc/ssh/ssh_host_*
```

### Загрузка зависает на `A start job is running for Wait for Network to be Configured`
- Симптом: сразу после `terraform apply` часть нод долго не пингуется или SSH на них то недоступен, то закрывается до авторизации.
- Причина: systemd ждёт `network-online`, а VirtualBox-гость ещё не завершил настройку одного из интерфейсов.
- Исправление уже внесено в проект:
  - в `infra/cloud-init/network-config.tpl` оба интерфейса помечены как `optional: true`;
  - в `infra/cloud-init/user-data.tpl` та же логика дублируется в netplan и отключаются `systemd-networkd-wait-online.service` / `NetworkManager-wait-online.service`.
- После этой правки ноды нужно пересоздать, чтобы новый `seed.iso` попал в клоны:

```powershell
cd infra/terraform
terraform apply
cd ..\scripts
.\tf-output-to-inventory.ps1
```

- После `terraform apply` дайте гостям 1-3 минуты на первый boot (`cloud-init`, `network-online`, генерация host keys`) и только потом запускайте Ansible.
- Если используете стандартный workflow `terraform apply -> tf-output-to-inventory.ps1 -> run-ansible-from-wsl.ps1`, ручная очистка `known_hosts` больше не нужна: она выполняется автоматически.
- Перед запуском Ansible проверьте доступность SSH по всем IP:

```powershell
ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -i C:\Users\<USER>\.ssh\id_ed25519 naurlox@192.168.56.11 hostname
ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -i C:\Users\<USER>\.ssh\id_ed25519 naurlox@192.168.56.12 hostname
ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -i C:\Users\<USER>\.ssh\id_ed25519 naurlox@192.168.56.21 hostname
ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -i C:\Users\<USER>\.ssh\id_ed25519 naurlox@192.168.56.22 hostname
ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -i C:\Users\<USER>\.ssh\id_ed25519 naurlox@192.168.56.31 hostname
```
