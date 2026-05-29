# K8 AI Lab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy GitLab CE on Nyx, a kubeadm Kubernetes cluster on Selene, and wire them together with a CI/CD pipeline that auto-deploys a demo app publicly via Astraea/Cloudflare.

**Architecture:** GitLab CE (Docker, Nyx) provides source control, CI runner, and container registry. Selene runs a single-node kubeadm cluster that pulls built images from Nyx's registry and serves the demo app on NodePort 30080. Astraea proxies `app.nyxstudios.net` → Selene:30080 through the existing Cloudflare tunnel.

**Tech Stack:** Docker Compose, GitLab CE (ARM64), GitLab Runner (docker executor), kubeadm 1.30, containerd, Flannel CNI, Cloudflare Tunnel (local config mode), Apache2 mod_proxy

---

## File Map

```
K8-ai-lab/
├── demo-app/
│   ├── Dockerfile              # nginx:alpine + index.html
│   ├── index.html              # "K8 AI Lab" landing page
│   └── .gitlab-ci.yml          # build + deploy pipeline
├── gitlab/
│   └── docker-compose.yml      # GitLab CE + GitLab Runner services
├── kubernetes/
│   ├── demo-app.yaml           # Deployment + Service (NodePort 30080)
│   └── registry-secret.yaml    # imagePullSecret template (values filled at runtime)
└── pipeline/
    └── README.md               # Runner registration steps + CI variable setup
```

---

## Phase 1: GitLab CE on Nyx

### Task 1: Create data directories and docker-compose.yml

**Files:**
- Create: `gitlab/docker-compose.yml`
- Run: `mkdir -p /home/legion/docker/gitlab/{config,logs,data}`

- [ ] **Step 1: Create host data directories**

```bash
mkdir -p /home/legion/docker/gitlab/config
mkdir -p /home/legion/docker/gitlab/logs
mkdir -p /home/legion/docker/gitlab/data
```

Expected: directories exist, no errors.

- [ ] **Step 2: Write docker-compose.yml**

Create `gitlab/docker-compose.yml`:

```yaml
services:
  gitlab:
    image: gitlab/gitlab-ce:latest
    container_name: gitlab
    restart: unless-stopped
    hostname: gitlab.nyxstudios.net
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'https://gitlab.nyxstudios.net'
        nginx['listen_port'] = 8929
        nginx['listen_https'] = false
        nginx['proxy_set_headers'] = {
          "X-Forwarded-Proto" => "https",
          "X-Forwarded-Ssl" => "on"
        }
        gitlab_rails['gitlab_shell_ssh_port'] = 2222
        registry_external_url 'https://registry.nyxstudios.net'
        registry_nginx['listen_port'] = 5050
        registry_nginx['listen_https'] = false
        registry_nginx['proxy_set_headers'] = {
          "X-Forwarded-Proto" => "https",
          "X-Forwarded-Ssl" => "on"
        }
        gitlab_rails['time_zone'] = 'America/Chicago'
    ports:
      - "8929:8929"
      - "2222:22"
      - "5050:5050"
    volumes:
      - /home/legion/docker/gitlab/config:/etc/gitlab
      - /home/legion/docker/gitlab/logs:/var/log/gitlab
      - /home/legion/docker/gitlab/data:/var/opt/gitlab
    shm_size: '256m'

  gitlab-runner:
    image: gitlab/gitlab-runner:latest
    container_name: gitlab-runner
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /home/legion/docker/gitlab/runner:/etc/gitlab-runner
    depends_on:
      - gitlab
```

- [ ] **Step 3: Commit**

```bash
cd /home/legion/legionprojects/K8-ai-lab
git add gitlab/docker-compose.yml
git commit -m "feat: add GitLab CE + Runner docker-compose"
git push
```

---

### Task 2: Open UFW ports on Nyx

**Files:** None (system configuration)

- [ ] **Step 1: Add UFW rules for GitLab web and SSH**

```bash
sudo ufw allow from 192.168.1.109 to any port 8929 comment 'GitLab web - Astraea tunnel'
sudo ufw allow from 192.168.1.0/24 to any port 2222 comment 'GitLab SSH - LAN'
sudo ufw allow from 192.168.1.0/24 to any port 5050 comment 'GitLab registry - Selene pulls'
sudo ufw reload
```

- [ ] **Step 2: Verify rules are active**

```bash
sudo ufw status | grep -E '8929|2222|5050'
```

Expected output (three lines showing the new rules):
```
8929                       ALLOW       192.168.1.109
2222/tcp                   ALLOW       192.168.1.0/24
5050                       ALLOW       192.168.1.0/24
```

---

### Task 3: Deploy GitLab stack via Portainer

- [ ] **Step 1: Deploy the stack from CLI (Portainer will pick it up)**

```bash
cd /home/legion/legionprojects/K8-ai-lab/gitlab
docker compose up -d
```

- [ ] **Step 2: Monitor startup (GitLab takes 3-5 minutes to reconfigure)**

```bash
docker logs -f gitlab 2>&1 | grep -E 'gitlab Reconfigured|ERROR|FATAL'
```

Wait until you see: `gitlab Reconfigured!`
Press Ctrl+C to stop tailing.

- [ ] **Step 3: Verify GitLab is responding on port 8929**

```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:8929
```

Expected: `302` (redirect to login page — confirms nginx is up)

- [ ] **Step 4: Get initial root password**

```bash
docker exec gitlab cat /etc/gitlab/initial_root_password | grep Password:
```

Save this password — it's only valid for 24 hours. Log in at http://192.168.1.236:8929 (LAN) and set a permanent password in User Settings → Password.

- [ ] **Step 5: Verify in Portainer**

Open https://192.168.1.236:9443 → Environments → local → Stacks.
Confirm `gitlab` stack appears with `gitlab` and `gitlab-runner` containers both running.

---

### Task 4: Add gitlab.nyxstudios.net to Cloudflare tunnel

The tunnel runs on Astraea using a local config file at `/etc/cloudflared/config.yml`. Routes are added by editing that file and restarting cloudflared.

- [ ] **Step 1: SSH into Astraea and view current tunnel config**

```bash
sshpass -p 'Zaq12345zaq1' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no legion@192.168.1.109 "cat /etc/cloudflared/config.yml"
```

- [ ] **Step 2: Add two new ingress entries to the config**

```bash
sshpass -p 'Zaq12345zaq1' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no legion@192.168.1.109 "
  sudo sed -i '/^ingress:/a\\  - hostname: gitlab.nyxstudios.net\n    service: http://192.168.1.236:8929\n  - hostname: app.nyxstudios.net\n    service: http://localhost:80' /etc/cloudflared/config.yml
"
```

- [ ] **Step 3: Verify the entries were added correctly**

```bash
sshpass -p 'Zaq12345zaq1' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no legion@192.168.1.109 "cat /etc/cloudflared/config.yml"
```

Confirm `gitlab.nyxstudios.net` and `app.nyxstudios.net` appear before the catch-all `service: http_status:404` line.

- [ ] **Step 4: Restart cloudflared**

```bash
sshpass -p 'Zaq12345zaq1' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no legion@192.168.1.109 "sudo systemctl restart cloudflared && sudo systemctl status cloudflared --no-pager | head -5"
```

Expected: `Active: active (running)`

---

### Task 5: Create CF DNS records and Access apps

**Cloudflare credentials:** All values are in `~/.claude/projects/-home-legion/memory/project_cloudflare.md` on Nyx.
- Email: `steve.j.petry@gmail.com`
- API Key: `<CF_GLOBAL_API_KEY>`  ← from memory file
- Account ID: `<CF_ACCOUNT_ID>`  ← from memory file
- Zone ID: `<CF_ZONE_ID>`  ← from memory file
- Tunnel ID: `<CF_TUNNEL_ID>`  ← from memory file
- IdP ID: `<CF_IDP_ID>`  ← from memory file

- [ ] **Step 1: Create CNAME DNS records for both new subdomains**

```bash
CF_EMAIL="steve.j.petry@gmail.com"
CF_KEY="<CF_GLOBAL_API_KEY>"
ZONE_ID="<CF_ZONE_ID>"
TUNNEL_ID="<CF_TUNNEL_ID>"

for SUBDOMAIN in gitlab app; do
  curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
    -H "X-Auth-Email: ${CF_EMAIL}" \
    -H "X-Auth-Key: ${CF_KEY}" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"CNAME\",\"name\":\"${SUBDOMAIN}\",\"content\":\"${TUNNEL_ID}.cfargotunnel.com\",\"ttl\":1,\"proxied\":true}" \
    | python3 -c "import sys,json; r=json.load(sys.stdin); print('${SUBDOMAIN}:', 'OK' if r['success'] else r['errors'])"
done
```

Expected:
```
gitlab: OK
app: OK
```

- [ ] **Step 2: Create CF Access application for gitlab.nyxstudios.net**

```bash
CF_EMAIL="steve.j.petry@gmail.com"
CF_KEY="<CF_GLOBAL_API_KEY>"
ACCOUNT_ID="<CF_ACCOUNT_ID>"

GITLAB_APP_ID=$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/access/apps" \
  -H "X-Auth-Email: ${CF_EMAIL}" \
  -H "X-Auth-Key: ${CF_KEY}" \
  -H "Content-Type: application/json" \
  --data '{
    "name": "GitLab",
    "domain": "gitlab.nyxstudios.net",
    "type": "self_hosted",
    "session_duration": "24h",
    "auto_redirect_to_identity": true
  }' | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['result']['id'] if r['success'] else r['errors'])")

echo "GitLab App ID: $GITLAB_APP_ID"
```

Save the printed App ID — needed for the policy step.

- [ ] **Step 3: Add Google OAuth policy to gitlab.nyxstudios.net Access app**

Replace `<GITLAB_APP_ID>` with the ID from Step 2.

```bash
CF_EMAIL="steve.j.petry@gmail.com"
CF_KEY="<CF_GLOBAL_API_KEY>"
ACCOUNT_ID="<CF_ACCOUNT_ID>"
IDP_ID="<CF_IDP_ID>"
GITLAB_APP_ID="<GITLAB_APP_ID>"

curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/access/apps/${GITLAB_APP_ID}/policies" \
  -H "X-Auth-Email: ${CF_EMAIL}" \
  -H "X-Auth-Key: ${CF_KEY}" \
  -H "Content-Type: application/json" \
  --data "{
    \"name\": \"Allow steve\",
    \"decision\": \"allow\",
    \"precedence\": 1,
    \"include\": [{\"email\": {\"email\": \"steve.j.petry@gmail.com\"}}],
    \"identity_provider_id\": \"${IDP_ID}\"
  }" | python3 -c "import sys,json; r=json.load(sys.stdin); print('Policy:', 'OK' if r['success'] else r['errors'])"
```

- [ ] **Step 4: Create CF Access application for app.nyxstudios.net**

```bash
CF_EMAIL="steve.j.petry@gmail.com"
CF_KEY="<CF_GLOBAL_API_KEY>"
ACCOUNT_ID="<CF_ACCOUNT_ID>"
IDP_ID="<CF_IDP_ID>"

APP_APP_ID=$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/access/apps" \
  -H "X-Auth-Email: ${CF_EMAIL}" \
  -H "X-Auth-Key: ${CF_KEY}" \
  -H "Content-Type: application/json" \
  --data '{
    "name": "K8 AI Lab App",
    "domain": "app.nyxstudios.net",
    "type": "self_hosted",
    "session_duration": "24h",
    "auto_redirect_to_identity": true
  }' | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['result']['id'] if r['success'] else r['errors'])")

curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/access/apps/${APP_APP_ID}/policies" \
  -H "X-Auth-Email: ${CF_EMAIL}" \
  -H "X-Auth-Key: ${CF_KEY}" \
  -H "Content-Type: application/json" \
  --data "{
    \"name\": \"Allow steve\",
    \"decision\": \"allow\",
    \"precedence\": 1,
    \"include\": [{\"email\": {\"email\": \"steve.j.petry@gmail.com\"}}],
    \"identity_provider_id\": \"${IDP_ID}\"
  }" | python3 -c "import sys,json; r=json.load(sys.stdin); print('app.nyxstudios.net App+Policy:', 'OK' if r['success'] else r['errors'])"

echo "App App ID: $APP_APP_ID"
```

- [ ] **Step 5: Verify GitLab is accessible via Cloudflare**

```bash
curl -s -o /dev/null -w "%{http_code}" https://gitlab.nyxstudios.net
```

Expected: `302` or `200` (Cloudflare Access redirect to Google OAuth, or GitLab login page)

---

## Phase 2: Kubernetes on Selene

### Task 6: Restore Selene SSH access

Selene (192.168.1.25) is reachable via ping but SSH port 22 is closed. The sshd service is likely stopped.

- [ ] **Step 1: Check if Selene is reachable and identify SSH issue**

On Nyx, check if another port is open on Selene:
```bash
nmap -p 22,2222,8022 192.168.1.25 2>/dev/null || nc -zv 192.168.1.25 22 2>&1
```

If port 22 is closed (not filtered), sshd is stopped. Proceed to Step 2.
If it's filtered (firewall), proceed to Step 3.

- [ ] **Step 2: Start sshd on Selene via physical/console access OR via Astraea**

If you have physical access to Selene:
```bash
sudo systemctl start ssh
sudo systemctl enable ssh
```

If sshd is active but blocked by UFW on Selene, add the rule (from Selene's console):
```bash
sudo ufw allow from 192.168.1.0/24 to any port 22
sudo ufw reload
```

- [ ] **Step 3: Verify SSH works from Nyx**

```bash
sshpass -p 'Zaq12345zaq1' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no -o StrictHostKeyChecking=no legion@192.168.1.25 "echo SSH OK && uname -a"
```

Expected: `SSH OK` followed by Linux kernel info.

---

### Task 7: Install containerd on Selene

All commands in this task run on Selene via SSH from Nyx. Prefix each with:
```bash
sshpass -p 'Zaq12345zaq1' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no legion@192.168.1.25 "sudo bash -s" << 'ENDSSH'
<commands>
ENDSSH
```

- [ ] **Step 1: Disable swap (kubeadm requirement)**

```bash
sshpass -p 'Zaq12345zaq1' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no legion@192.168.1.25 "sudo bash -s" << 'ENDSSH'
swapoff -a
sed -i '/\bswap\b/d' /etc/fstab
echo "Swap disabled: $(swapon --show | wc -l) swap entries"
ENDSSH
```

Expected: `Swap disabled: 0 swap entries`

- [ ] **Step 2: Load required kernel modules**

```bash
sshpass -p 'Zaq12345zaq1' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no legion@192.168.1.25 "sudo bash -s" << 'ENDSSH'
cat > /etc/modules-load.d/k8s.conf << 'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
lsmod | grep -E 'overlay|br_netfilter'
ENDSSH
```

Expected: both `overlay` and `br_netfilter` appear in output.

- [ ] **Step 3: Set kernel networking parameters**

```bash
sshpass -p 'Zaq12345zaq1' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no legion@192.168.1.25 "sudo bash -s" << 'ENDSSH'
cat > /etc/sysctl.d/k8s.conf << 'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system 2>&1 | grep -E 'Applying|forward|bridge'
ENDSSH
```

- [ ] **Step 4: Install containerd**

```bash
sshpass -p 'Zaq12345zaq1' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no legion@192.168.1.25 "sudo bash -s" << 'ENDSSH'
apt-get update -qq
apt-get install -y containerd
containerd --version
ENDSSH
```

Expected: `containerd github.com/containerd/containerd v1.x.x ...`

- [ ] **Step 5: Configure containerd with SystemdCgroup and Nyx registry**

```bash
sshpass -p 'Zaq12345zaq1' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no legion@192.168.1.25 "sudo bash -s" << 'ENDSSH'
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Configure Nyx container registry (LAN, plain HTTP on port 5050)
mkdir -p /etc/containerd/certs.d/registry.nyxstudios.net
cat > /etc/containerd/certs.d/registry.nyxstudios.net/hosts.toml << 'EOF'
server = "http://192.168.1.236:5050"

[host."http://192.168.1.236:5050"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF

# Add hosts entry so registry.nyxstudios.net resolves to Nyx on LAN
if ! grep -q 'registry.nyxstudios.net' /etc/hosts; then
  echo '192.168.1.236 registry.nyxstudios.net' >> /etc/hosts
fi

systemctl restart containerd
systemctl is-active containerd
ENDSSH
```

Expected: `active`

---

### Task 8: Install kubeadm, kubelet, kubectl on Selene

- [ ] **Step 1: Add Kubernetes 1.30 apt repository**

```bash
sshpass -p 'Zaq12345zaq1' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no legion@192.168.1.25 "sudo bash -s" << 'ENDSSH'
apt-get install -y apt-transport-https ca-certificates curl gpg
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -qq
ENDSSH
```

- [ ] **Step 2: Install and pin kubeadm, kubelet, kubectl**

```bash
sshpass -p 'Zaq12345zaq1' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no legion@192.168.1.25 "sudo bash -s" << 'ENDSSH'
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
kubeadm version
kubectl version --client
ENDSSH
```

Expected: both version commands show `v1.30.x`

---

### Task 9: Initialize Kubernetes cluster on Selene

- [ ] **Step 1: Run kubeadm init**

```bash
sshpass -p 'Zaq12345zaq1' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no legion@192.168.1.25 "sudo bash -s" << 'ENDSSH'
kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --apiserver-advertise-address=192.168.1.25 \
  2>&1 | tee /tmp/kubeadm-init.log
tail -20 /tmp/kubeadm-init.log
ENDSSH
```

Expected: ends with `Your Kubernetes control-plane has initialized successfully!`

- [ ] **Step 2: Configure kubectl for legion user**

```bash
sshpass -p 'Zaq12345zaq1' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no legion@192.168.1.25 "bash -s" << 'ENDSSH'
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
kubectl get nodes
ENDSSH
```

Expected: Selene node listed as `NotReady` (no CNI installed yet — that's normal here).

- [ ] **Step 3: Remove control-plane taint (single-node — must schedule workloads)**

```bash
sshpass -p 'Zaq12345zaq1' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no legion@192.168.1.25 "bash -s" << 'ENDSSH'
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>&1 || true
kubectl describe node | grep -A5 Taints
ENDSSH
```

Expected: `Taints: <none>`

- [ ] **Step 4: Install Flannel CNI**

```bash
sshpass -p 'Zaq12345zaq1' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no legion@192.168.1.25 "bash -s" << 'ENDSSH'
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
echo "Waiting for node to become Ready..."
for i in $(seq 1 30); do
  STATUS=$(kubectl get nodes --no-headers | awk '{print $2}')
  [ "$STATUS" = "Ready" ] && echo "Node is Ready!" && break
  echo "  [$i/30] Status: $STATUS — waiting 10s..."
  sleep 10
done
kubectl get nodes
ENDSSH
```

Expected: node shows `Ready`.

---

### Task 10: Open Selene UFW ports

- [ ] **Step 1: Add UFW rules on Selene**

```bash
sshpass -p 'Zaq12345zaq1' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no legion@192.168.1.25 "sudo bash -s" << 'ENDSSH'
# K8s API server — Nyx GitLab Runner needs this to deploy
ufw allow from 192.168.1.236 to any port 6443 comment 'K8s API - Nyx GitLab Runner'
# kubelet — internal cluster communication
ufw allow from 192.168.1.0/24 to any port 10250 comment 'kubelet'
# NodePort for demo app — Astraea needs this for reverse proxy
ufw allow from 192.168.1.109 to any port 30080 comment 'demo-app NodePort - Astraea'
ufw reload
ufw status | grep -E '6443|10250|30080'
ENDSSH
```

Expected: three new rules appear.

---

### Task 11: Extract kubeconfig and store in GitLab

- [ ] **Step 1: Fetch kubeconfig from Selene**

```bash
KUBE_CONFIG=$(sshpass -p 'Zaq12345zaq1' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no legion@192.168.1.25 "cat ~/.kube/config" | base64 -w0)
echo "KUBE_CONFIG length: ${#KUBE_CONFIG} chars"
echo $KUBE_CONFIG | head -c 100
```

- [ ] **Step 2: Add KUBE_CONFIG as a GitLab CI/CD variable**

In GitLab (https://gitlab.nyxstudios.net):
1. Create a project named `demo-app` (the pipeline repo)
2. Go to Settings → CI/CD → Variables → Add variable
3. Key: `KUBE_CONFIG`, Value: the base64 string from Step 1, Type: Variable, Masked: ✓, Protected: ✗
4. Click "Add variable"

Or via GitLab API (replace `<ROOT_TOKEN>` with a personal access token from User Settings → Access Tokens → create token with `api` scope):

```bash
GITLAB_TOKEN="<ROOT_TOKEN>"
PROJECT_ID=$(curl -s -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "http://192.168.1.236:8929/api/v4/projects?search=demo-app" \
  | python3 -c "import sys,json; p=json.load(sys.stdin); print(p[0]['id']) if p else print('project not found')")

KUBE_CONFIG=$(sshpass -p 'Zaq12345zaq1' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no legion@192.168.1.25 "cat ~/.kube/config" | base64 -w0)

curl -s -X POST "http://192.168.1.236:8929/api/v4/projects/${PROJECT_ID}/variables" \
  -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  -H "Content-Type: application/json" \
  --data "{\"key\":\"KUBE_CONFIG\",\"value\":\"${KUBE_CONFIG}\",\"masked\":true}" \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print('KUBE_CONFIG var:', r.get('key','ERROR'))"
```

---

## Phase 3: CI/CD Pipeline

### Task 12: Create the demo app

**Files:**
- Create: `demo-app/index.html`
- Create: `demo-app/Dockerfile`

- [ ] **Step 1: Write index.html**

Create `demo-app/index.html`:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>K8 AI Lab</title>
  <style>
    body { font-family: system-ui, sans-serif; background: #0f0f1a; color: #e0e0ff; display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; }
    .card { text-align: center; padding: 3rem; border: 1px solid #4040ff; border-radius: 12px; max-width: 480px; }
    h1 { font-size: 2.5rem; margin: 0 0 1rem; color: #7070ff; }
    p { color: #a0a0cc; line-height: 1.6; }
    .tag { display: inline-block; background: #1a1a3a; border: 1px solid #4040aa; border-radius: 4px; padding: 0.2rem 0.6rem; font-family: monospace; font-size: 0.85rem; margin-top: 1rem; color: #8080ff; }
  </style>
</head>
<body>
  <div class="card">
    <h1>K8 AI Lab</h1>
    <p>Deployed via GitLab CI/CD pipeline to Kubernetes on Selene.</p>
    <div class="tag">BUILD_SHA_PLACEHOLDER</div>
  </div>
</body>
</html>
```

- [ ] **Step 2: Write Dockerfile**

Create `demo-app/Dockerfile`:

```dockerfile
FROM nginx:alpine
COPY index.html /usr/share/nginx/html/index.html
ARG BUILD_SHA=unknown
RUN sed -i "s/BUILD_SHA_PLACEHOLDER/${BUILD_SHA}/" /usr/share/nginx/html/index.html
EXPOSE 80
```

- [ ] **Step 3: Build and test locally on Nyx**

```bash
cd /home/legion/legionprojects/K8-ai-lab/demo-app
docker build --build-arg BUILD_SHA=local-test -t demo-app:test .
docker run -d --name demo-test -p 8999:80 demo-app:test
curl -s http://localhost:8999 | grep -o 'local-test'
docker rm -f demo-test
```

Expected: `local-test` printed (confirms the SHA substitution works)

- [ ] **Step 4: Commit**

```bash
cd /home/legion/legionprojects/K8-ai-lab
git add demo-app/index.html demo-app/Dockerfile
git commit -m "feat: add demo-app Dockerfile and landing page"
git push
```

---

### Task 13: Create Kubernetes manifests

**Files:**
- Create: `kubernetes/demo-app.yaml`

- [ ] **Step 1: Write demo-app.yaml**

Create `kubernetes/demo-app.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
  namespace: default
  labels:
    app: demo-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: demo-app
  template:
    metadata:
      labels:
        app: demo-app
    spec:
      imagePullSecrets:
        - name: gitlab-registry
      containers:
        - name: demo-app
          image: registry.nyxstudios.net/root/demo-app:latest
          ports:
            - containerPort: 80
          resources:
            requests:
              memory: "32Mi"
              cpu: "50m"
            limits:
              memory: "64Mi"
              cpu: "100m"
---
apiVersion: v1
kind: Service
metadata:
  name: demo-app
  namespace: default
spec:
  type: NodePort
  selector:
    app: demo-app
  ports:
    - port: 80
      targetPort: 80
      nodePort: 30080
```

- [ ] **Step 2: Create the imagePullSecret on Selene**

Replace `<ROOT_TOKEN>` with the GitLab personal access token (api scope) created in Task 11.

```bash
sshpass -p 'Zaq12345zaq1' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no legion@192.168.1.25 "bash -s" << 'ENDSSH'
kubectl create secret docker-registry gitlab-registry \
  --docker-server=registry.nyxstudios.net \
  --docker-username=root \
  --docker-password=<ROOT_TOKEN> \
  --namespace=default 2>&1 || kubectl get secret gitlab-registry -n default
ENDSSH
```

- [ ] **Step 3: Apply the manifests (using placeholder image for initial deploy)**

```bash
sshpass -p 'Zaq12345zaq1' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no legion@192.168.1.25 "bash -s" << 'ENDSSH'
kubectl apply -f - << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
  namespace: default
  labels:
    app: demo-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: demo-app
  template:
    metadata:
      labels:
        app: demo-app
    spec:
      imagePullSecrets:
        - name: gitlab-registry
      containers:
        - name: demo-app
          image: nginx:alpine
          ports:
            - containerPort: 80
          resources:
            requests:
              memory: "32Mi"
              cpu: "50m"
            limits:
              memory: "64Mi"
              cpu: "100m"
---
apiVersion: v1
kind: Service
metadata:
  name: demo-app
  namespace: default
spec:
  type: NodePort
  selector:
    app: demo-app
  ports:
    - port: 80
      targetPort: 80
      nodePort: 30080
EOF
kubectl get pods,svc -n default
ENDSSH
```

Expected: 2 pods `Running` and service `demo-app` with NodePort `30080`.

- [ ] **Step 4: Verify demo-app is reachable from Nyx**

```bash
curl -s -o /dev/null -w "%{http_code}" http://192.168.1.25:30080
```

Expected: `200`

- [ ] **Step 5: Commit manifests**

```bash
cd /home/legion/legionprojects/K8-ai-lab
git add kubernetes/demo-app.yaml
git commit -m "feat: add K8s Deployment and NodePort Service for demo-app"
git push
```

---

### Task 14: Write .gitlab-ci.yml and register GitLab Runner

**Files:**
- Create: `demo-app/.gitlab-ci.yml`
- Create: `pipeline/README.md`

- [ ] **Step 1: Register GitLab Runner**

In GitLab: Settings → CI/CD → Runners → New project runner.
- Tags: `docker-nyx`
- Copy the registration token shown.

Then register the container:
```bash
docker exec -it gitlab-runner gitlab-runner register \
  --non-interactive \
  --url "http://gitlab:8929" \
  --token "<RUNNER_TOKEN>" \
  --executor "docker" \
  --docker-image "docker:latest" \
  --docker-volumes "/var/run/docker.sock:/var/run/docker.sock" \
  --description "Nyx Docker Runner" \
  --tag-list "docker-nyx" \
  --docker-network-mode "host"
```

Verify: `docker exec gitlab-runner gitlab-runner list`

Expected: runner listed as `alive`.

- [ ] **Step 2: Write .gitlab-ci.yml**

Create `demo-app/.gitlab-ci.yml`:

```yaml
stages:
  - build
  - deploy

variables:
  IMAGE_TAG: $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA
  LATEST_TAG: $CI_REGISTRY_IMAGE:latest

build:
  stage: build
  tags:
    - docker-nyx
  script:
    - docker login -u $CI_REGISTRY_USER -p $CI_REGISTRY_PASSWORD $CI_REGISTRY
    - docker build --build-arg BUILD_SHA=$CI_COMMIT_SHA -t $IMAGE_TAG -t $LATEST_TAG .
    - docker push $IMAGE_TAG
    - docker push $LATEST_TAG
  only:
    - main

deploy:
  stage: deploy
  tags:
    - docker-nyx
  image: bitnami/kubectl:latest
  script:
    - echo $KUBE_CONFIG | base64 -d > /tmp/kubeconfig
    - export KUBECONFIG=/tmp/kubeconfig
    - kubectl set image deployment/demo-app demo-app=$IMAGE_TAG -n default
    - kubectl rollout status deployment/demo-app -n default --timeout=120s
  only:
    - main
```

- [ ] **Step 3: Write pipeline/README.md**

Create `pipeline/README.md` with these contents (write without nested code fences):

```
# GitLab Runner Setup

## Runner registration (run once after GitLab is deployed)

1. In GitLab: Settings → CI/CD → Runners → New project runner
2. Set tag: docker-nyx
3. Copy the token, then run:

    docker exec -it gitlab-runner gitlab-runner register \
      --non-interactive \
      --url "http://gitlab:8929" \
      --token "<TOKEN>" \
      --executor "docker" \
      --docker-image "docker:latest" \
      --docker-volumes "/var/run/docker.sock:/var/run/docker.sock" \
      --description "Nyx Docker Runner" \
      --tag-list "docker-nyx" \
      --docker-network-mode "host"

## CI/CD Variables (set in GitLab project Settings → CI/CD → Variables)

| Key | Description | Masked |
|-----|-------------|--------|
| KUBE_CONFIG | base64-encoded kubeconfig from Selene (cat ~/.kube/config | base64 -w0) | Yes |

CI_REGISTRY, CI_REGISTRY_USER, CI_REGISTRY_PASSWORD are auto-injected by GitLab.
```

- [ ] **Step 4: Commit**

```bash
cd /home/legion/legionprojects/K8-ai-lab
git add demo-app/.gitlab-ci.yml pipeline/README.md
git commit -m "feat: add CI/CD pipeline and runner docs"
git push
```

---

### Task 15: Push demo-app to GitLab and trigger pipeline

- [ ] **Step 1: Create demo-app project in GitLab**

In GitLab (https://gitlab.nyxstudios.net):
1. New project → Create blank project
2. Name: `demo-app`, Visibility: Private
3. Do NOT initialize with README (you'll push from the repo)

- [ ] **Step 2: Add GitLab as a remote and push demo-app directory**

```bash
cd /tmp
cp -r /home/legion/legionprojects/K8-ai-lab/demo-app k8-demo-app
cd k8-demo-app
git init
git checkout -b main
git remote add origin http://root:<ROOT_TOKEN>@192.168.1.236:8929/root/demo-app.git
git add .
git commit -m "initial: demo-app with CI/CD pipeline"
git push -u origin main
```

- [ ] **Step 3: Watch the pipeline run**

In GitLab → demo-app project → CI/CD → Pipelines.
Click on the running pipeline to watch `build` then `deploy` stages.

Expected: both stages pass (green checkmarks).

- [ ] **Step 4: Verify deployment on Selene**

```bash
sshpass -p 'Zaq12345zaq1' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no legion@192.168.1.25 "kubectl get pods,deploy -n default"
```

Expected: 2 pods with `Running` status, image tag matches the commit SHA.

```bash
curl -s http://192.168.1.25:30080 | grep -o 'K8 AI Lab'
```

Expected: `K8 AI Lab`

---

## Phase 4: Astraea Routing

### Task 16: Configure Apache VirtualHost on Astraea

- [ ] **Step 1: Create the VirtualHost config**

```bash
sshpass -p 'Zaq12345zaq1' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no legion@192.168.1.109 "sudo bash -s" << 'ENDSSH'
cat > /etc/apache2/sites-available/app.nyxstudios.net.conf << 'EOF'
<VirtualHost *:80>
    ServerName app.nyxstudios.net
    ProxyPreserveHost On
    ProxyPass / http://192.168.1.25:30080/
    ProxyPassReverse / http://192.168.1.25:30080/
    ErrorLog ${APACHE_LOG_DIR}/app-error.log
    CustomLog ${APACHE_LOG_DIR}/app-access.log combined
</VirtualHost>
EOF

a2enmod proxy proxy_http 2>&1 | tail -2
a2ensite app.nyxstudios.net 2>&1 | tail -1
apache2ctl configtest 2>&1
ENDSSH
```

Expected: `Syntax OK`

- [ ] **Step 2: Reload Apache**

```bash
sshpass -p 'Zaq12345zaq1' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no legion@192.168.1.109 "sudo systemctl reload apache2 && echo Apache reloaded"
```

- [ ] **Step 3: Test proxy from Nyx (via Astraea LAN)**

```bash
curl -s -H "Host: app.nyxstudios.net" http://192.168.1.109 | grep -o 'K8 AI Lab'
```

Expected: `K8 AI Lab`

---

### Task 17: End-to-end verification

- [ ] **Step 1: Verify gitlab.nyxstudios.net**

```bash
curl -sI https://gitlab.nyxstudios.net | head -5
```

Expected: HTTP 200 or 302 with Cloudflare headers (`cf-ray:` present)

- [ ] **Step 2: Verify app.nyxstudios.net (after authenticating in browser)**

```bash
curl -s -o /dev/null -w "%{http_code}" https://app.nyxstudios.net
```

Expected: `302` (Cloudflare Access redirect to Google — confirms tunnel and Access are active)

Open https://app.nyxstudios.net in browser, authenticate with Google, confirm the "K8 AI Lab" page loads with the commit SHA displayed.

- [ ] **Step 3: Trigger a code change to verify full pipeline**

```bash
cd /tmp/k8-demo-app
sed -i 's/Deployed via GitLab CI\/CD pipeline/v2: Updated via automated pipeline/' index.html
git add index.html
git commit -m "test: update landing page text to verify pipeline"
git push
```

Watch the pipeline in GitLab, then verify the updated text appears at https://app.nyxstudios.net.

- [ ] **Step 4: Commit final kubernetes manifests to K8-ai-lab repo**

```bash
cd /home/legion/legionprojects/K8-ai-lab
git add kubernetes/
git commit -m "feat: add final K8s manifests"
git push
```

---

## Summary: What Was Built

| Component | Location | URL / Access |
|-----------|----------|-------------|
| GitLab CE | Nyx:8929 | https://gitlab.nyxstudios.net |
| Container Registry | Nyx:5050 | LAN: 192.168.1.236:5050 |
| GitLab Runner | Nyx (Docker) | Tagged: docker-nyx |
| K8s API | Selene:6443 | LAN: 192.168.1.25:6443 |
| demo-app | Selene:30080 | https://app.nyxstudios.net |
