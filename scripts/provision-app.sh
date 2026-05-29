#!/usr/bin/env bash
# provision-app.sh — Create a new GitLab project ready for self-service deployment
# Usage: ./provision-app.sh <app-name>
#
# This script only creates the GitLab project, CI pipeline, and CI variables.
# Infrastructure (K8s, Apache, DNS, Cloudflare) is provisioned later via the
# 'provision' stage in the GitLab pipeline — which prompts for the subdomain.
#
# Requires: scripts/provision.env (copy from provision.env.example and fill in)
set -euo pipefail

GREEN='\033[0;32m'; BOLD='\033[1m'; RESET='\033[0m'
ok()   { echo -e "${GREEN}✔ ${BOLD}$*${RESET}"; }
step() { echo -e "\n${BOLD}▶ $*${RESET}"; }

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <app-name>"
  echo ""
  echo "  app-name  GitLab project name (e.g. hello-world)"
  echo ""
  echo "After running this script:"
  echo "  1. Clone the repo and push your code"
  echo "  2. Build stage runs automatically"
  echo "  3. Click ▶ provision in GitLab — enter your subdomain"
  echo "  4. Click ▶ deploy — your app goes live"
  exit 1
fi
APP_NAME="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/provision.env"
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Error: ${ENV_FILE} not found."
  echo "Copy scripts/provision.env.example to scripts/provision.env and fill in your values."
  exit 1
fi
source "${ENV_FILE}"

# ── 1. Create GitLab project ───────────────────────────────────────────────────
step "1/4 — Creating GitLab project '${APP_NAME}'"

NS_ID=$(curl -sf \
  -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "${GITLAB_URL}/api/v4/namespaces?search=${NAMESPACE}" \
  | python3 -c "
import sys,json
hits=[n for n in json.load(sys.stdin) if n['path']=='${NAMESPACE}']
print(hits[0]['id'])")

CREATE_RESP=$(curl -s \
  -X POST \
  -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  -H "Content-Type: application/json" \
  "${GITLAB_URL}/api/v4/projects" \
  -d "{\"name\":\"${APP_NAME}\",\"namespace_id\":${NS_ID},\"visibility\":\"public\",\"initialize_with_readme\":false}" || true)

PROJECT_ID=$(echo "${CREATE_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || true)

if [[ -z "${PROJECT_ID}" ]]; then
  PROJECT_ID=$(curl -sf \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${GITLAB_URL}/api/v4/projects?search=${APP_NAME}&namespace_id=${NS_ID}" \
    | python3 -c "
import sys,json
hits=[p for p in json.load(sys.stdin) if p['path']=='${APP_NAME}']
print(hits[0]['id'])")
fi

ok "Project ID=${PROJECT_ID}  path=${NAMESPACE}/${APP_NAME}"

# ── 2. Commit .gitlab-ci.yml with provision + build + deploy stages ────────────
step "2/4 — Committing CI pipeline (build / provision / deploy)"

# Single-quoted heredoc keeps GitLab CI variable names ($CI_PROJECT_NAME etc.) literal
CI_YML=$(cat <<'YAML_EOF'
stages:
  - build
  - provision
  - deploy

variables:
  REGISTRY: "192.168.1.236:5050"
  IMAGE_TAG: "$REGISTRY/$CI_PROJECT_PATH:$CI_COMMIT_SHA"
  LATEST_TAG: "$REGISTRY/$CI_PROJECT_PATH:latest"

# ── Build: runs automatically on every push ────────────────────────────────────
build:
  stage: build
  tags:
    - docker-nyx
  script:
    - docker login -u $CI_REGISTRY_USER -p $CI_REGISTRY_PASSWORD $REGISTRY
    - docker run --rm --privileged tonistiigi/binfmt --install all
    - docker build --platform linux/amd64 --build-arg BUILD_SHA=$CI_COMMIT_SHA -t $IMAGE_TAG -t $LATEST_TAG .
    - docker push $IMAGE_TAG
    - docker push $LATEST_TAG
  only:
    - main

# ── Provision: run ONCE to set up infrastructure — asks for your subdomain ─────
provision:
  stage: provision
  when: manual
  tags:
    - docker-nyx
  image: alpine:3.19
  variables:
    SUBDOMAIN:
      value: ""
      description: "Your subdomain on nyxstudios.net — e.g. 'myapp' makes https://myapp.nyxstudios.net"
  before_script:
    - apk add --no-cache sshpass curl python3 openssh-client
  script:
    - |
      set -e
      APP_NAME="$CI_PROJECT_NAME"
      HOSTNAME_FQDN="${SUBDOMAIN}.${DOMAIN}"
      SSH_OPTS="-o PreferredAuthentications=password -o PubkeyAuthentication=no -o StrictHostKeyChecking=no"

      echo "Provisioning ${APP_NAME} at https://${HOSTNAME_FQDN} ..."

      # ── K8s deployment on Selene ───────────────────────────────────────────
      python3 -c "
      print('''apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${APP_NAME}
  template:
    metadata:
      labels:
        app: ${APP_NAME}
    spec:
      containers:
      - name: ${APP_NAME}
        image: nginx:alpine
        ports:
        - containerPort: 80''')
      " > /tmp/k8s-deploy.yaml

      sshpass -p "$SSH_PASS" scp $SSH_OPTS /tmp/k8s-deploy.yaml ${SSH_USER}@${K8S_HOST}:/tmp/k8s-deploy-${APP_NAME}.yaml
      sshpass -p "$SSH_PASS" ssh $SSH_OPTS ${SSH_USER}@${K8S_HOST} "
        kubectl apply -f /tmp/k8s-deploy-${APP_NAME}.yaml
        kubectl expose deployment ${APP_NAME} --port=80 --target-port=80 --type=NodePort -n default 2>/dev/null || true
        kubectl rollout status deployment/${APP_NAME} -n default --timeout=60s
      "
      NODE_PORT=$(sshpass -p "$SSH_PASS" ssh $SSH_OPTS ${SSH_USER}@${K8S_HOST} \
        "kubectl get svc ${APP_NAME} -n default -o jsonpath='{.spec.ports[0].nodePort}'")
      echo "NodePort: ${NODE_PORT}"

      # ── Apache VirtualHost on Astraea ──────────────────────────────────────
      python3 -c "
      print('''<VirtualHost *:80>
    ServerName ${HOSTNAME_FQDN}
    ProxyPreserveHost On
    ProxyPass / http://${K8S_HOST}:${NODE_PORT}/
    ProxyPassReverse / http://${K8S_HOST}:${NODE_PORT}/
</VirtualHost>''')
      " > /tmp/vhost-${APP_NAME}.conf

      sshpass -p "$SSH_PASS" scp $SSH_OPTS /tmp/vhost-${APP_NAME}.conf ${SSH_USER}@${ASTRAEA_HOST}:/tmp/${APP_NAME}.conf
      sshpass -p "$SSH_PASS" ssh $SSH_OPTS ${SSH_USER}@${ASTRAEA_HOST} "
        echo '${SSH_PASS}' | sudo -S cp /tmp/${APP_NAME}.conf /etc/apache2/sites-available/${APP_NAME}.conf
        echo '${SSH_PASS}' | sudo -S a2ensite ${APP_NAME}.conf
        echo '${SSH_PASS}' | sudo -S systemctl reload apache2
      "

      # ── Cloudflare DNS CNAME ───────────────────────────────────────────────
      curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
        -H "X-Auth-Email: ${CF_EMAIL}" \
        -H "X-Auth-Key: ${CF_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"type\":\"CNAME\",\"name\":\"${SUBDOMAIN}\",\"content\":\"${CF_TUNNEL_ID}.cfargotunnel.com\",\"proxied\":true,\"ttl\":1}" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print('DNS:', 'created' if d.get('success') else d.get('errors',''))"

      # ── Cloudflare tunnel route on Astraea ─────────────────────────────────
      sshpass -p "$SSH_PASS" ssh $SSH_OPTS ${SSH_USER}@${ASTRAEA_HOST} "
        if ! grep -q 'hostname: ${HOSTNAME_FQDN}' /etc/cloudflared/config.yml; then
          echo '${SSH_PASS}' | sudo -S sed -i \
            '/http_status:404/i\\  - hostname: ${HOSTNAME_FQDN}\\n    service: http://localhost:80' \
            /etc/cloudflared/config.yml
        fi
        echo '${SSH_PASS}' | sudo -S systemctl restart cloudflared
      "

      # ── Cloudflare Access app + policy ─────────────────────────────────────
      ACCESS_APP_ID=$(curl -s -X POST \
        "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/access/apps" \
        -H "X-Auth-Email: ${CF_EMAIL}" \
        -H "X-Auth-Key: ${CF_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${APP_NAME}\",\"domain\":\"${HOSTNAME_FQDN}\",\"type\":\"self_hosted\",\"session_duration\":\"24h\",\"allowed_idps\":[\"${CF_IDP_ID}\"],\"auto_redirect_to_identity\":true}" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result']['id'] if d.get('success') else '')" || echo "")

      if [[ -n "${ACCESS_APP_ID}" ]]; then
        curl -sf -X POST \
          "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/access/apps/${ACCESS_APP_ID}/policies" \
          -H "X-Auth-Email: ${CF_EMAIL}" \
          -H "X-Auth-Key: ${CF_API_KEY}" \
          -H "Content-Type: application/json" \
          -d "{\"name\":\"Allow users\",\"decision\":\"allow\",\"precedence\":1,\"include\":[{\"email\":{\"email\":\"${ADMIN_EMAIL}\"}}]}" > /dev/null
      fi

      echo ""
      echo "✔ Infrastructure ready!"
      echo "✔ https://${HOSTNAME_FQDN}"
      echo ""
      echo "Now click ▶ deploy to go live."
  only:
    - main

# ── Deploy: push your image to K8s ────────────────────────────────────────────
deploy:
  stage: deploy
  when: manual
  tags:
    - docker-nyx
  image:
    name: bitnami/kubectl:latest
    entrypoint: [""]
  script:
    - echo $KUBE_CONFIG | base64 -d > /tmp/kubeconfig
    - export KUBECONFIG=/tmp/kubeconfig
    - kubectl set image deployment/$CI_PROJECT_NAME $CI_PROJECT_NAME=$IMAGE_TAG -n default
    - kubectl rollout status deployment/$CI_PROJECT_NAME -n default --timeout=120s
  only:
    - main
YAML_EOF
)

CI_YML_B64=$(printf '%s' "${CI_YML}" | base64 -w0)
PAYLOAD_FILE=$(mktemp /tmp/provision-ci-XXXXXX.json)
trap 'rm -f "${PAYLOAD_FILE}"' EXIT

python3 -c "
import json
print(json.dumps({
    'branch': 'main',
    'commit_message': 'chore: add CI pipeline (build / provision / deploy)',
    'encoding': 'base64',
    'content': '${CI_YML_B64}'
}))" > "${PAYLOAD_FILE}"

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST \
  -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  -H "Content-Type: application/json" \
  "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/repository/files/.gitlab-ci.yml" \
  -d @"${PAYLOAD_FILE}")

if [[ "${HTTP_STATUS}" == "400" || "${HTTP_STATUS}" == "409" ]]; then
  python3 -c "
import json
print(json.dumps({
    'branch': 'main',
    'commit_message': 'chore: update CI pipeline',
    'encoding': 'base64',
    'content': '${CI_YML_B64}'
}))" > "${PAYLOAD_FILE}"
  curl -sf -X PUT \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    -H "Content-Type: application/json" \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/repository/files/.gitlab-ci.yml" \
    -d @"${PAYLOAD_FILE}" > /dev/null
fi

# Unprotect main so developers can push directly
curl -s -o /dev/null -X DELETE \
  -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/protected_branches/main" || true

ok "CI pipeline committed"

# ── 3. Set CI variables (infra credentials for the provision job) ──────────────
step "3/4 — Setting CI variables"

set_var() {
  local key="$1" value="$2" masked="${3:-false}"
  local payload
  payload=$(python3 -c "import json; print(json.dumps({'key':'${key}','value':'''${value}''','variable_type':'env_var','protected':False,'masked':${masked}}))")
  local http
  http=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" -H "Content-Type: application/json" \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/variables" -d "${payload}")
  if [[ "${http}" == "400" ]]; then
    curl -sf -X PUT -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" -H "Content-Type: application/json" \
      "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/variables/${key}" -d "${payload}" > /dev/null
  fi
}

# Copy KUBE_CONFIG from source project
KUBE_VALUE=$(curl -sf -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "${GITLAB_URL}/api/v4/projects/${SOURCE_PROJECT_ID}/variables/KUBE_CONFIG" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])")
VAR_FILE=$(mktemp /tmp/provision-kube-XXXXXX.json)
python3 -c "
import json
print(json.dumps({'key':'KUBE_CONFIG','value':'''${KUBE_VALUE}''','variable_type':'env_var','protected':False,'masked':True}))" > "${VAR_FILE}"
http=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" -H "Content-Type: application/json" \
  "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/variables" -d @"${VAR_FILE}")
[[ "${http}" == "400" ]] && curl -sf -X PUT \
  -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" -H "Content-Type: application/json" \
  "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/variables/KUBE_CONFIG" -d @"${VAR_FILE}" > /dev/null
rm -f "${VAR_FILE}"

# Infrastructure variables used by the provision CI job
set_var "K8S_HOST"      "${K8S_HOST}"
set_var "ASTRAEA_HOST"  "${ASTRAEA_HOST}"
set_var "SSH_USER"      "${SSH_USER}"
set_var "SSH_PASS"      "${SSH_PASS}"      "True"
set_var "CF_EMAIL"      "${CF_EMAIL}"
set_var "CF_API_KEY"    "${CF_API_KEY}"    "True"
set_var "CF_ZONE_ID"    "${CF_ZONE_ID}"
set_var "CF_ACCOUNT_ID" "${CF_ACCOUNT_ID}"
set_var "CF_TUNNEL_ID"  "${CF_TUNNEL_ID}"
set_var "CF_IDP_ID"     "${CF_IDP_ID}"
set_var "ADMIN_EMAIL"   "${ADMIN_EMAIL}"
set_var "DOMAIN"        "${DOMAIN}"
set_var "REGISTRY"      "${REGISTRY}"
set_var "NAMESPACE"     "${NAMESPACE}"

ok "CI variables set"

# ── 4. Enable runner ───────────────────────────────────────────────────────────
step "4/4 — Enabling runner"

curl -s -o /dev/null -X POST \
  -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/runners" \
  --form "runner_id=${RUNNER_ID}" || true

ok "Runner ${RUNNER_ID} enabled"

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  ${APP_NAME} — Project Ready${RESET}"
echo -e "${BOLD}════════════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${GREEN}GitLab:${RESET} ${GITLAB_URL}/${NAMESPACE}/${APP_NAME}"
echo ""
echo -e "${BOLD}Developer workflow:${RESET}"
echo ""
echo -e "  1. Clone and add your code:"
echo -e "     git clone ${GITLAB_URL}/${NAMESPACE}/${APP_NAME}.git"
echo -e "     git add . && git commit -m 'initial app' && git push origin main"
echo ""
echo -e "  2. BUILD runs automatically (~2 min)"
echo ""
echo -e "  3. Click ▶ PROVISION in the pipeline"
echo -e "     → Enter your subdomain (e.g. 'myapp')"
echo -e "     → Infrastructure is created automatically"
echo ""
echo -e "  4. Click ▶ DEPLOY — your app goes live at"
echo -e "     https://<your-subdomain>.${DOMAIN}"
echo -e "${BOLD}════════════════════════════════════════════════════════${RESET}"
