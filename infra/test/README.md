# Page View Demo

This test service is prepared for two modes:

- local run with `docker compose`
- cluster run with `docker stack deploy`

## What it does

- serves a page on port `3000`
- publishes the same app on `3001` too by mapping the same container port
- increments a local page-view counter on every `GET /`
- shows the current replica hostname in the page
- exposes:
  - `/api/stats`
  - `/metrics`
  - `/health`

Important:
- with multiple replicas in Swarm, the counter is local to each replica
- this is correct for load-balancing and failover demos
- if you need one shared global counter across all replicas, add Redis or another shared state backend

## Local run

```powershell
cd infra/test
docker compose up --build
```

Open:

- `http://localhost:3000`
- `http://localhost:3001`

## Swarm deploy

Build and push the image to a registry reachable from your nodes.

Example with Docker Hub:

```powershell
cd infra/test/react-monitoring-demo
docker build -t <dockerhub-user>/page-view-demo:1.0.0 .
docker push <dockerhub-user>/page-view-demo:1.0.0
```

Deploy from a manager node:

```bash
export PAGE_VIEW_IMAGE=<dockerhub-user>/page-view-demo:1.0.0
docker stack deploy -c /mnt/c/Users/Nvidia/Desktop/Kwork_labs/KP/infra/test/docker-stack.yml pageview
```

Check:

```bash
docker stack services pageview
docker stack ps pageview
docker service logs pageview_page_view_demo
```

Service lifecycle:

```bash
# restart all replicas
docker service update --force pageview_page_view_demo

# temporarily stop the service
docker service scale pageview_page_view_demo=0

# start it back with 3 replicas
docker service scale pageview_page_view_demo=3

# remove the whole stack
docker stack rm pageview

# deploy it again
export PAGE_VIEW_IMAGE=<dockerhub-user>/page-view-demo:1.0.0
docker stack deploy -c /mnt/c/Users/Nvidia/Desktop/Kwork_labs/KP/infra/test/docker-stack.yml pageview
```

Access:

- `http://192.168.56.11:3000`
- `http://192.168.56.12:3000`
- `http://192.168.56.21:3000`
- `http://192.168.56.22:3000`
- or the same on port `3001`

Because ports `3000` and `3001` are published in ingress mode, any swarm node can accept the request and forward it to a healthy replica.

VIP access through HAProxy route:

```powershell
curl.exe -H "Host: pageview.local" http://192.168.56.10/
curl.exe -H "Host: pageview.local" http://192.168.56.10/api/stats
curl.exe -H "Host: pageview.local" http://192.168.56.10/health
curl.exe -H "Host: pageview.local" http://192.168.56.10/metrics
```

## Failover test

1. Open `http://192.168.56.11:3000` and refresh several times.
2. Watch hostname changes.
3. On a manager:

```bash
docker service ps pageview_page_view_demo
docker node update --availability drain kp-worker-01
docker service ps pageview_page_view_demo
```

4. Refresh the page again.
5. Restore the worker:

```bash
docker node update --availability active kp-worker-01
docker service update --force pageview_page_view_demo
```

For automatic post-recovery rebalance, the stack file already contains:

```yaml
deploy:
  labels:
    com.kp.auto_rebalance: "true"
```

So after a worker returns and you run the standard workflow through `infra/scripts/run-ansible-from-wsl.ps1`, the helper `infra/scripts/rebalance-swarm-services.ps1` can trigger a rolling rebalance automatically.

If you want this service behind the VIP, do not create one VIP per service. Use one VIP with host-based routing in HAProxy. Example route in `infra/ansible/group_vars/all.yml`:

```yaml
haproxy_http_routes:
  - name: pageview
    host: pageview.local
    backend_port: 3000
```

Then apply HAProxy config and test:

```powershell
cd infra\scripts
.\run-ansible-from-wsl.ps1 -Playbook playbooks/04-haproxy-keepalived.yml
curl -H "Host: pageview.local" http://192.168.56.10/
```

Right now the base lab HAProxy is configured only for:

- `:80` for application HTTP
- `:2377` for Swarm manager join/control-plane

## HA validation runbook

Worker failure:

```powershell
VBoxManage controlvm "kp-worker-01" poweroff
```

```bash
docker node ls
docker stack services pageview
docker service ps pageview_page_view_demo
```

```powershell
curl.exe -H "Host: pageview.local" http://192.168.56.10/health
for ($i=1; $i -le 10; $i++) { curl.exe -s -H "Host: pageview.local" http://192.168.56.10/api/stats; Write-Host "" }
```

Recover worker:

```powershell
VBoxManage startvm "kp-worker-01" --type headless
```

```bash
docker service update --force pageview_page_view_demo
docker service ps pageview_page_view_demo
```

Manager quorum:

```powershell
VBoxManage controlvm "kp-manager-03" poweroff
```

```bash
docker node ls
docker service ls
docker service ps pageview_page_view_demo
```

Recover manager:

```powershell
VBoxManage startvm "kp-manager-03" --type headless
```

LB failover and VIP retention:

```powershell
ssh naurlox@192.168.56.31 "ip a show enp0s3 | grep 192.168.56.10 || true"
ssh naurlox@192.168.56.32 "ip a show enp0s3 | grep 192.168.56.10 || true"
```

Then power off the active LB:

```powershell
VBoxManage controlvm "kp-lb-01" poweroff
```

or:

```powershell
VBoxManage controlvm "kp-lb-02" poweroff
```

And verify the same VIP still answers:

```powershell
curl.exe -H "Host: pageview.local" http://192.168.56.10/health
curl.exe -H "Host: pageview.local" http://192.168.56.10/api/stats
```
