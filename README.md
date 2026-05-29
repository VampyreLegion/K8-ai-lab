# K8 AI Lab — GitLab CI/CD + Kubernetes on Nyx Studios

A self-hosted DevOps lab built on three physical machines, deploying containerised apps
through a full GitLab CI/CD pipeline into a Kubernetes cluster — all exposed securely
through Cloudflare Tunnel without opening a single port on your router.

---

## Table of Contents

1. [What Was Built](#what-was-built)
2. [Infrastructure Overview](#infrastructure-overview)
3. [How It All Works](#how-it-all-works)
4. [Websites & Access Points](#websites--access-points)
5. [How to Use GitLab](#how-to-use-gitlab)
6. [How to Add a New Project](#how-to-add-a-new-project)
7. [Accessing Servers & Deployed Apps](#accessing-servers--deployed-apps)
8. [The CI/CD Pipeline Explained](#the-cicd-pipeline-explained)
9. [Manual vs Automatic Deploys](#manual-vs-automatic-deploys)
10. [Troubleshooting](#troubleshooting)

---

## What Was Built

This lab gives you a **complete DevOps workflow** on your own hardware:

- **Push code → Automatic build → Docker image → Kubernetes deployment → Live on the internet**

Two apps are currently running:

| App | Description | URL |
|-----|-------------|-----|
| **demo-app** | Nginx HTML page, auto-deploys on every push | https://app.nyxstudios.net |
| **space-invaders** | Full HTML5 Space Invaders game, manually deployed | https://invaders.nyxstudios.net |

Both are served securely over HTTPS via Cloudflare with Google OAuth login required.

---

## Infrastructure Overview

Three physical machines make up the lab:

```
┌─────────────────────────────────────────────────────────────────┐
│                        NYX STUDIOS LAN                          │
│                                                                 │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────┐  │
│  │     NYX      │    │   ASTRAEA    │    │     SELENE       │  │
│  │ 192.168.1.236│    │ 192.168.1.109│    │  192.168.1.25    │  │
│  │  aarch64     │    │   x86_64     │    │    x86_64        │  │
│  │  NVIDIA GB10 │    │              │    │                  │  │
│  │              │    │ Cloudflare   │    │  Kubernetes      │  │
│  │  GitLab CE   │    │   Tunnel     │    │  Single-Node     │  │
│  │  CI Runner   │    │   Apache     │    │  containerd      │  │
│  │  Container   │    │              │    │                  │  │
│  │  Registry    │    │              │    │  demo-app Pod    │  │
│  │              │    │              │    │  invaders Pod    │  │
│  └──────────────┘    └──────────────┘    └──────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
          ▲                    ▲
          │                    │ Cloudflare Tunnel (outbound only)
          │               ┌────┴────────────────────────┐
          │               │         CLOUDFLARE           │
          │               │  Zero Trust + Access + DNS   │
          │               └────────────┬────────────────┘
          │                            │ HTTPS
          │                     ┌──────▼──────┐
          └─────────────────────│   INTERNET   │
                                └─────────────┘
```

### Machine Roles

**Nyx** (192.168.1.236) — The build machine
- Runs **GitLab CE** (self-hosted Git + CI/CD)
- Runs the **GitLab Runner** (executes build jobs)
- Hosts the **Container Registry** (stores Docker images)
- Is an NVIDIA GB10 Blackwell (aarch64) — GPU-capable

**Astraea** (192.168.1.109) — The gateway
- Runs **Cloudflare Tunnel** (connects your LAN to the internet securely)
- Runs **Apache** (HTTP proxy routing hostnames to internal services)
- No inbound ports need to be opened on your router

**Selene** (192.168.1.25) — The deployment target
- Runs **Kubernetes** (single-node cluster via kubeadm)
- Pulls Docker images from Nyx's registry
- Serves deployed apps via NodePort services

---

## How It All Works

### The Build & Deploy Flow

```
You push code to GitLab
         │
         ▼
GitLab detects the push and creates a Pipeline
         │
         ▼
┌────────────────────────────────────────────┐
│              STAGE 1: BUILD                │
│  Runner on Nyx pulls your repo             │
│  Runs: docker build --platform linux/amd64 │
│  Pushes image to 192.168.1.236:5050        │
│  (GitLab Container Registry)               │
└────────────────────────────────────────────┘
         │
         ▼ (auto OR manual depending on project)
┌────────────────────────────────────────────┐
│             STAGE 2: DEPLOY                │
│  Runner uses kubectl to update K8s         │
│  kubectl set image deployment/<app>        │
│  Kubernetes pulls new image from registry  │
│  Old pod terminates, new pod starts        │
│  Rollout waits for healthy confirmation    │
└────────────────────────────────────────────┘
         │
         ▼
App is live at its public URL
```

### The Request Path (when a user visits your app)

```
User's browser
     │  HTTPS request to app.nyxstudios.net
     ▼
Cloudflare Edge (anycast, global CDN)
     │  Google OAuth check (Cloudflare Access)
     │  If authenticated: forwards via tunnel
     ▼
Cloudflare Tunnel on Astraea
     │  Decrypts and forwards to Apache
     ▼
Apache on Astraea (localhost:80)
     │  VirtualHost match on hostname
     │  ProxyPass to Selene NodePort
     ▼
Selene Kubernetes NodePort (192.168.1.25:3xxxx)
     │  kube-proxy routes to pod
     ▼
Running Pod (nginx container)
     │  Serves your app content
     ▼
Response travels back the same path
```

---

## Websites & Access Points

All public sites require **Google sign-in with steve.j.petry@gmail.com** via Cloudflare Access.

### Your GitLab & Apps

| Site | URL | What it is |
|------|-----|------------|
| **GitLab** | https://gitlab.nyxstudios.net | Source code, pipelines, registry |
| **demo-app** | https://app.nyxstudios.net | Demo nginx app on K8s |
| **Space Invaders** | https://invaders.nyxstudios.net | HTML5 game on K8s |

### Other Nyx Studios Services

| Site | URL | What it is |
|------|-----|------------|
| ComfyUI | https://ai.nyxstudios.net | AI image generation |
| ACE-Step | https://ai2.nyxstudios.net | Music generation |
| Open WebUI | https://nyx.nyxstudios.net | LLM chat interface |
| Navidrome | https://music.nyxstudios.net | Music streaming |
| Immich | https://selene.nyxstudios.net | Photo library |

### LAN Direct Access (no Cloudflare Auth needed)

| What | Address |
|------|---------|
| GitLab | http://192.168.1.236:8929 |
| demo-app | http://192.168.1.25:31055 |
| Space Invaders | http://192.168.1.25:30618 |

---

## How to Use GitLab

### Logging In

1. Go to **https://gitlab.nyxstudios.net**
2. Cloudflare Access will ask you to sign in with Google — use `steve.j.petry@gmail.com`
3. GitLab login:
   - Username: `user`
   - Password: `pw`

### Cloning a Project

```bash
git clone https://gitlab.nyxstudios.net/root/demo-app.git
cd demo-app
# username: user  password: pw
```

### Making Changes and Deploying (demo-app — auto deploy)

```bash
# Edit the page
nano index.html

# Commit and push
git add index.html
git commit -m "update: change homepage content"
git push origin main

# The pipeline starts automatically:
# 1. build stage runs (~2 min)
# 2. deploy stage runs automatically (~30 sec)
# 3. Visit https://app.nyxstudios.net — your change is live
```

### Making Changes and Deploying (space-invaders — manual deploy)

```bash
git clone https://gitlab.nyxstudios.net/root/space-invaders.git
cd space-invaders

# Edit the game
nano index.html

git add index.html
git commit -m "feat: add more lives"
git push origin main

# Pipeline runs the build stage automatically.
# The deploy stage has a PLAY BUTTON — you trigger it manually:
# Go to: https://gitlab.nyxstudios.net/root/space-invaders/-/pipelines
# Click the ▶ button next to "deploy"
```

---

## How to Add a New Project

Follow these steps to add a new app with full CI/CD to Kubernetes.

### Step 1 — Create the project in GitLab

```bash
# Via API (from Nyx terminal):
curl -X POST -H "PRIVATE-TOKEN: <your-gitlab-pat>" \
  http://192.168.1.236:8929/api/v4/projects \
  --form "name=my-new-app" \
  --form "visibility=public"
# Note the "id" in the response — you'll need it
```

Or use the GitLab web UI: **New Project → Create blank project**

### Step 2 — Add these three files to your project

**`Dockerfile`** — wraps your app in a container:
```dockerfile
FROM nginx:alpine
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 80
```

**`index.html`** — your actual app content (or replace with your stack)

**`.gitlab-ci.yml`** — the pipeline definition:
```yaml
stages:
  - build
  - deploy

variables:
  REGISTRY: "192.168.1.236:5050"
  IMAGE_TAG: "$REGISTRY/root/my-new-app:$CI_COMMIT_SHA"
  LATEST_TAG: "$REGISTRY/root/my-new-app:latest"

build:
  stage: build
  tags:
    - docker-nyx
  script:
    - docker login -u $CI_REGISTRY_USER -p $CI_REGISTRY_PASSWORD $REGISTRY
    - docker run --rm --privileged tonistiigi/binfmt --install all
    - docker build --platform linux/amd64 -t $IMAGE_TAG -t $LATEST_TAG .
    - docker push $IMAGE_TAG
    - docker push $LATEST_TAG
  only:
    - main

deploy:
  stage: deploy
  when: manual          # remove this line for auto-deploy
  tags:
    - docker-nyx
  image:
    name: bitnami/kubectl:latest
    entrypoint: [""]
  script:
    - echo $KUBE_CONFIG | base64 -d > /tmp/kubeconfig
    - export KUBECONFIG=/tmp/kubeconfig
    - kubectl set image deployment/my-new-app my-new-app=$IMAGE_TAG -n default
    - kubectl rollout status deployment/my-new-app -n default --timeout=120s
  only:
    - main
```

### Step 3 — Add the KUBE_CONFIG variable to your project

```bash
# Copy from existing project (replace PROJECT_ID with your new project's ID):
KUBE=$(curl -s -H "PRIVATE-TOKEN: <your-gitlab-pat>" \
  http://192.168.1.236:8929/api/v4/projects/1/variables/KUBE_CONFIG \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])")

curl -X POST -H "PRIVATE-TOKEN: <your-gitlab-pat>" \
  http://192.168.1.236:8929/api/v4/projects/PROJECT_ID/variables \
  --form "key=KUBE_CONFIG" --form "value=$KUBE"
```

### Step 4 — Enable the runner on your project

```bash
curl -X POST -H "PRIVATE-TOKEN: <your-gitlab-pat>" \
  http://192.168.1.236:8929/api/v4/projects/PROJECT_ID/runners \
  --form "runner_id=1"
```

### Step 5 — Create the Kubernetes deployment on Selene

```bash
ssh user@192.168.1.25   # password: pw

kubectl create deployment my-new-app \
  --image=192.168.1.236:5050/root/my-new-app:latest -n default

kubectl expose deployment my-new-app \
  --port=80 --target-port=80 --type=NodePort -n default

kubectl get svc my-new-app   # note the NodePort (e.g. 32345)
```

### Step 6 — Add Apache VirtualHost on Astraea

```bash
ssh user@192.168.1.109   # password: pw

sudo tee /etc/apache2/sites-available/my-new-app.conf << EOF
<VirtualHost *:80>
    ServerName my-new-app.nyxstudios.net
    ProxyPreserveHost On
    ProxyPass / http://192.168.1.25:32345/
    ProxyPassReverse / http://192.168.1.25:32345/
</VirtualHost>
EOF

sudo a2ensite my-new-app.conf
sudo systemctl reload apache2
```

### Step 7 — Add to Cloudflare Tunnel & DNS

SSH to Astraea and add to `/etc/cloudflared/config.yml` before the last `http_status:404` line:
```yaml
  - hostname: my-new-app.nyxstudios.net
    service: http://localhost:80
```
Then: `sudo systemctl restart cloudflared`

Add DNS record via Cloudflare API or dashboard:
- Type: CNAME
- Name: `my-new-app`
- Target: `6ba0ad1e-7a83-44b0-9361-2af437572b6b.cfargotunnel.com`
- Proxied: Yes

---

## Accessing Servers & Deployed Apps

### SSH to Nyx (the build machine)
You're already on Nyx — open a terminal.

### SSH to Astraea (the gateway)
```bash
sshpass -p 'pw' ssh \
  -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no \
  user@192.168.1.109
```

### SSH to Selene (the K8s machine)
```bash
ssh user@192.168.1.25
# password: pw
```

### Kubernetes Commands (run on Selene)
```bash
# See all running pods
kubectl get pods

# See all services and their ports
kubectl get svc

# Live logs from an app
kubectl logs -l app=demo-app -f

# Describe a pod (good for debugging)
kubectl describe pod <pod-name>

# Restart an app
kubectl rollout restart deployment/demo-app

# See all K8s resources
kubectl get all -n default
```

### Check a Deployed App's Status
```bash
# On Selene — is the pod running?
kubectl get pods -l app=my-new-app

# Test locally on Selene:
curl http://localhost:<nodeport>/

# Test from Nyx:
curl http://192.168.1.25:<nodeport>/
```

---

## The CI/CD Pipeline Explained

Each project has a `.gitlab-ci.yml` file that defines the pipeline.

### Pipeline Stages

```
PUSH TO MAIN
     │
     ▼
┌──────────────────────────────────────┐
│  STAGE: build                        │
│                                      │
│  1. docker login to registry         │
│  2. Install QEMU (for cross-arch)    │
│  3. docker build --platform amd64    │
│     (builds on Nyx arm64,            │
│      targets Selene x86_64)          │
│  4. docker push (SHA tag + latest)   │
│                                      │
│  Result: image stored in registry    │
└──────────────────────────────────────┘
     │
     ▼ (auto or manual)
┌──────────────────────────────────────┐
│  STAGE: deploy                       │
│                                      │
│  1. Decode KUBE_CONFIG secret        │
│  2. kubectl set image → new SHA      │
│  3. kubectl rollout status           │
│     (waits for pod to be healthy)    │
│                                      │
│  Result: new pod running on Selene   │
└──────────────────────────────────────┘
```

### Key Variables

| Variable | Value | Purpose |
|----------|-------|---------|
| `REGISTRY` | `192.168.1.236:5050` | Where images are stored |
| `IMAGE_TAG` | `registry/project:commit-sha` | Unique tag per commit |
| `LATEST_TAG` | `registry/project:latest` | Always the newest build |
| `KUBE_CONFIG` | base64 kubeconfig | Lets the runner talk to K8s |
| `CI_REGISTRY_USER` | Set by GitLab | Registry login username |
| `CI_REGISTRY_PASSWORD` | Set by GitLab | Registry login password |

### Why `--platform linux/amd64`?
Nyx is ARM64 (aarch64) but Selene is x86_64 (AMD64). The build step uses QEMU emulation
to cross-compile the image so it runs on Selene.

---

## Manual vs Automatic Deploys

| | demo-app | space-invaders |
|--|----------|----------------|
| Build | Automatic on push | Automatic on push |
| Deploy | **Automatic** | **Manual** (click ▶) |

**To switch a project from manual to automatic deploy**, remove `when: manual` from `.gitlab-ci.yml`:

```yaml
deploy:
  stage: deploy
  # when: manual   ← remove or comment this line
  tags:
    - docker-nyx
```

---

## Troubleshooting

### Pipeline stuck on "pending"
The runner isn't enabled for that project.
```bash
curl -X POST -H "PRIVATE-TOKEN: glpat-..." \
  http://192.168.1.236:8929/api/v4/projects/PROJECT_ID/runners \
  --form "runner_id=1"
```

### Image pull fails on Selene — HTTPS error
containerd's config_path must be a single path (no colon-separated list):
```bash
ssh user@192.168.1.25
grep config_path /etc/containerd/config.toml
# Must be: config_path = '/etc/containerd/certs.d'
# NOT:     config_path = '/etc/containerd/certs.d:/etc/docker/certs.d'
```

### Pod won't start — ImagePullBackOff
Check the pod events:
```bash
kubectl describe pod -l app=<appname> | grep -A 10 Events
```

### Site unreachable
1. Is the tunnel running? `ssh astraea "systemctl is-active cloudflared"`
2. Is GitLab up? `docker ps | grep gitlab`
3. Is the pod running? `ssh selene "kubectl get pods"`

### "Firefox can't connect" on a *.nyxstudios.net domain
Check `/etc/hosts` on Nyx — remove any LAN overrides for public domains.
Only `selene` (192.168.1.25) should be in `/etc/hosts`.

---

## Quick Reference Card

```
┌─────────────────────────────────────────────────────────────────┐
│                    K8 AI LAB QUICK REFERENCE                    │
├─────────────────────────────────────────────────────────────────┤
│ GitLab          https://gitlab.nyxstudios.net                   │
│                 user: user  pw: pw                  │
├─────────────────────────────────────────────────────────────────┤
│ demo-app        https://app.nyxstudios.net                      │
│                 Auto-deploys on every git push                   │
├─────────────────────────────────────────────────────────────────┤
│ Space Invaders  https://invaders.nyxstudios.net                 │
│                 Manual deploy (click ▶ in GitLab pipeline)       │
├─────────────────────────────────────────────────────────────────┤
│ SSH Selene      ssh user@192.168.1.25  pw: pw       │
│ SSH Astraea     ssh user@192.168.1.109  pw: pw      │
├─────────────────────────────────────────────────────────────────┤
│ K8s check       kubectl get pods                                 │
│ K8s logs        kubectl logs -l app=<name> -f                   │
│ K8s restart     kubectl rollout restart deployment/<name>        │
└─────────────────────────────────────────────────────────────────┘
```
