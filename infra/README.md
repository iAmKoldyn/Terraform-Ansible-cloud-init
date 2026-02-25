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
sudo rm -f /etc/ssh/ssh_host_*key*
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id
sudo cloud-init clean --logs
sudo sync
sudo poweroff
```

После этого создайте или обновите snapshot `GOLDEN-CLEAN`.

Важно: не удаляйте доступ, пока не проверите cloud-init bootstrap хотя бы на одном клоне.

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

Важно: сетевые переменные в Terraform теперь обязательны (без `terraform.tfvars` или `-var` запуск `plan/apply` завершится ошибкой).

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
