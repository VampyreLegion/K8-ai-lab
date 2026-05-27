# K8 AI Lab — Design Spec

**Date:** 2026-05-27  
**Repo:** https://github.com/VampyreLegion/K8-ai-lab  
**Status:** Approved

---

## Overview

End-to-end GitLab CI/CD pipeline across three machines in the Nyx Studios LAN:

1. **GitLab CE on Nyx** — source control + CI runner + container registry
2. **Kubernetes (kubeadm) on Selene** — deployment target
3. **Astraea** — public-facing reverse proxy via Cloudflare tunnel

A demo app (nginx) validates the full pipeline: push code → build image → push to registry → deploy to K8s → serve publicly at `app.nyxstudios.net`.

---

## Infrastructure Map

```
Nyx (192.168.1.236 · aarch64 · DGX GB10)
├── GitLab CE            :8929   https://gitlab.nyxstudios.net  (CF Access)
├── Container Registry   :5050   registry.nyxstudios.net        (LAN only)
└── GitLab Runner               docker executor, runs on Nyx

Selene (192.168.1.25 · x86_64 · i7-4790K · 32GB)
├── kubeadm single-node K8s
│   ├── containerd runtime
│   ├── Flannel CNI (10.244.0.0/16)
│   └── demo-app Deployment  NodePort :30080

Astraea (192.168.1.109 · x86_64 · Ubuntu)
├── Apache: app.nyxstudios.net → ProxyPass http://192.168.1.25:30080
└── cloudflared tunnel: app.nyxstudios.net → localhost:80

Cloudflare
├── gitlab.nyxstudios.net  → Nyx:8929        (CF Access · Google OAuth)
└── app.nyxstudios.net     → Astraea:80      (CF Access · Google OAuth)
```

---

## Phase 1: GitLab CE on Nyx

### Docker Compose

File: `gitlab/docker-compose.yml`  
Deployed as a Portainer stack named `gitlab`.

**Image:** `gitlab/gitlab-ce:latest` (official ARM64 support since v15)

**Ports:**
| Host Port | Container Port | Purpose |
|-----------|---------------|---------|
| 8929 | 80 | GitLab web HTTP |
| 2222 | 22 | Git SSH |
| 5050 | 5050 | Container Registry |

**Volumes (bind mounts):**
```
/home/legion/docker/gitlab/config  →  /etc/gitlab
/home/legion/docker/gitlab/logs    →  /var/log/gitlab
/home/legion/docker/gitlab/data    →  /var/opt/gitlab
```

**`GITLAB_OMNIBUS_CONFIG` key settings:**
```ruby
external_url 'https://gitlab.nyxstudios.net'
nginx['listen_port'] = 8929
nginx['listen_https'] = false
gitlab_rails['gitlab_shell_ssh_port'] = 2222
registry_external_url 'https://registry.nyxstudios.net'
registry_nginx['listen_port'] = 5050
registry_nginx['listen_https'] = false
```

### Nyx Firewall (UFW)
```
ufw allow from 192.168.1.0/24 to any port 8929
ufw allow from 192.168.1.0/24 to any port 2222
ufw allow from 192.168.1.0/24 to any port 5050
```

### Cloudflare
- Tunnel route: `gitlab.nyxstudios.net` → `http://192.168.1.236:8929`
- New CF Access application: same Google OAuth policy (`steve.j.petry@gmail.com`, 24h)
- Registry stays LAN-only (Selene pulls over LAN)

---

## Phase 2: Kubernetes on Selene

### Prerequisites
- Fix SSH: verify `sshd` is running on Selene (currently port 22 closed)
- OS: Ubuntu 24.04 x86_64

### Install Sequence
1. Install `containerd` (container runtime, no Docker)
2. Configure containerd: enable SystemdCgroup, disable disabled_plugins
3. Install `kubeadm`, `kubelet`, `kubectl` via Kubernetes 1.30 apt repo
4. `kubeadm init --pod-network-cidr=10.244.0.0/16`
5. Copy kubeconfig to `~/.kube/config`
6. Untaint control-plane node (single-node cluster, must schedule workloads)
7. Install Flannel CNI: `kubectl apply -f flannel.yaml`

### Selene UFW Ports
```
ufw allow from 192.168.1.0/24 to any port 6443    # K8s API (GitLab Runner → Selene)
ufw allow from 192.168.1.0/24 to any port 10250   # kubelet
ufw allow from any to any port 30080               # NodePort (Astraea → Selene)
```

### Post-install
- Export kubeconfig, store as GitLab CI/CD variable `KUBE_CONFIG` (base64-encoded, masked)

---

## Phase 3: GitLab CI/CD Pipeline

### GitLab Runner
- Deployed as Docker container on Nyx alongside GitLab stack
- Executor: `docker`
- Image: `gitlab/gitlab-runner:latest`
- Registered to `https://gitlab.nyxstudios.net` with a runner token

### Demo App
File: `demo-app/`
- `index.html` — "K8 AI Lab — deployed via GitLab CI"
- `Dockerfile` — `FROM nginx:alpine`, copies `index.html` to `/usr/share/nginx/html/`

### Pipeline (`.gitlab-ci.yml`)
Two stages:

**build:**
- Docker-in-Docker (`docker:dind`) or Docker socket mount
- `docker build -t registry.nyxstudios.net/$CI_PROJECT_PATH:$CI_COMMIT_SHA .`
- `docker push registry.nyxstudios.net/$CI_PROJECT_PATH:$CI_COMMIT_SHA`

**deploy:**
- Uses `bitnami/kubectl` image
- Decodes `$KUBE_CONFIG` env var, writes to `~/.kube/config`
- `kubectl set image deployment/demo-app demo-app=registry.nyxstudios.net/$CI_PROJECT_PATH:$CI_COMMIT_SHA`

### K8s Manifests
File: `kubernetes/demo-app.yaml`
- `Deployment`: 2 replicas, image placeholder updated by pipeline
- `Service`: NodePort :30080

### CI/CD Variables (set in GitLab project settings)
| Variable | Value | Masked |
|----------|-------|--------|
| `KUBE_CONFIG` | base64-encoded kubeconfig | Yes |

`CI_REGISTRY_USER` and `CI_REGISTRY_PASSWORD` are auto-injected by GitLab when the built-in container registry is enabled — no manual configuration needed.

---

## Phase 4: Astraea Routing

### Apache VirtualHost
File: `/etc/apache2/sites-available/app.nyxstudios.net.conf`
```apache
<VirtualHost *:80>
    ServerName app.nyxstudios.net
    ProxyPreserveHost On
    ProxyPass / http://192.168.1.25:30080/
    ProxyPassReverse / http://192.168.1.25:30080/
</VirtualHost>
```
Enable: `a2ensite app.nyxstudios.net && a2enmod proxy proxy_http && systemctl reload apache2`

### Cloudflare
- Tunnel route: `app.nyxstudios.net` → `http://192.168.1.109:80`
- New CF Access application: Google OAuth, `steve.j.petry@gmail.com`, 24h session

---

## Port Reference

| Port | Machine | Protocol | Purpose | Open To |
|------|---------|----------|---------|---------|
| 8929 | Nyx | TCP | GitLab web | LAN + Cloudflare |
| 2222 | Nyx | TCP | GitLab SSH | LAN |
| 5050 | Nyx | TCP | Container Registry | LAN (Selene) |
| 6443 | Selene | TCP | K8s API server | LAN (Nyx Runner) |
| 10250 | Selene | TCP | kubelet | LAN |
| 30080 | Selene | TCP | K8s NodePort (demo app) | LAN (Astraea) |

---

## Repo Structure

```
K8-ai-lab/
├── demo-app/
│   ├── Dockerfile
│   ├── index.html
│   └── .gitlab-ci.yml
├── gitlab/
│   └── docker-compose.yml
├── kubernetes/
│   └── demo-app.yaml
├── pipeline/
│   └── README.md        (runner registration steps)
└── docs/
    └── superpowers/
        └── specs/
            └── 2026-05-27-k8-ai-lab-design.md
```

---

## Implementation Order

1. **Phase 1** — Deploy GitLab CE on Nyx, add Cloudflare route
2. **Phase 2** — Fix Selene SSH, install kubeadm cluster, open ports
3. **Phase 3** — Register GitLab Runner, push demo app, configure CI/CD variables, run pipeline
4. **Phase 4** — Configure Astraea Apache VirtualHost, add Cloudflare route

Each phase is independently verifiable before moving to the next.
