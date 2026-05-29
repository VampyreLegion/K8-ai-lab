#!/usr/bin/env bash
# provision-app.sh — Fully automated GitLab + K8s + Cloudflare app onboarding
# Usage: ./provision-app.sh <app-name> [google-email]
#
# Requires: scripts/provision.env (copy from provision.env.example and fill in)
set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; BOLD='\033[1m'; RESET='\033[0m'
ok()   { echo -e "${GREEN}✔ ${BOLD}$*${RESET}"; }
step() { echo -e "\n${BOLD}▶ $*${RESET}"; }

# ── Args ───────────────────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <app-name> [google-email]"
  exit 1
fi
APP_NAME="$1"
EXTRA_EMAIL="${2:-}"

# ── Load config ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/provision.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Error: ${ENV_FILE} not found."
  echo "Copy scripts/provision.env.example to scripts/provision.env and fill in your values."
  exit 1
fi

# shellcheck source=provision.env.example
source "${ENV_FILE}"

HOSTNAME_FQDN="${APP_NAME}.${DOMAIN}"

_ssh() { sshpass -p "${SSH_PASS}" ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no -o StrictHostKeyChecking=no "${SSH_USER}@$1" "${@:2}"; }

# ── 1. Create GitLab project ───────────────────────────────────────────────────
step "1/9 — Creating GitLab project '${APP_NAME}'"

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
  -d "{\"name\":\"${APP_NAME}\",\"namespace_id\":${NS_ID},\"visibility\":\"private\",\"initialize_with_readme\":false}" || true)

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

# ── 2. Commit .gitlab-ci.yml ───────────────────────────────────────────────────
step "2/9 — Committing .gitlab-ci.yml"

# Single-quoted heredoc: shell does NOT expand $ so CI vars stay literal
CI_YML=$(cat <<'YAML_EOF'
stages:
  - build
  - deploy

variables:
  REGISTRY: "192.168.1.236:5050"
  IMAGE_TAG: "$REGISTRY/__NAMESPACE__/__APPNAME__:$CI_COMMIT_SHA"
  LATEST_TAG: "$REGISTRY/__NAMESPACE__/__APPNAME__:latest"

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
    - kubectl set image deployment/__APPNAME__ __APPNAME__=$IMAGE_TAG -n default
    - kubectl rollout status deployment/__APPNAME__ -n default --timeout=120s
  only:
    - main
YAML_EOF
)
CI_YML="${CI_YML//__APPNAME__/${APP_NAME}}"
CI_YML="${CI_YML//__NAMESPACE__/${NAMESPACE}}"
CI_YML="${CI_YML//192.168.1.236:5050/${REGISTRY}}"

CI_YML_B64=$(printf '%s' "${CI_YML}" | base64 -w0)

PAYLOAD_FILE=$(mktemp /tmp/provision-ci-XXXXXX.json)
trap 'rm -f "${PAYLOAD_FILE}"' EXIT

python3 -c "
import json
print(json.dumps({
    'branch': 'main',
    'commit_message': 'chore: add default CI/CD pipeline',
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
    'commit_message': 'chore: update CI/CD pipeline',
    'encoding': 'base64',
    'content': '${CI_YML_B64}'
}))" > "${PAYLOAD_FILE}"
  curl -sf -X PUT \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    -H "Content-Type: application/json" \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/repository/files/.gitlab-ci.yml" \
    -d @"${PAYLOAD_FILE}" > /dev/null
fi

ok ".gitlab-ci.yml committed"

# ── 3. Copy KUBE_CONFIG variable ───────────────────────────────────────────────
step "3/9 — Copying KUBE_CONFIG CI variable"

KUBE_VALUE=$(curl -sf \
  -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "${GITLAB_URL}/api/v4/projects/${SOURCE_PROJECT_ID}/variables/KUBE_CONFIG" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])")

VAR_FILE=$(mktemp /tmp/provision-var-XXXXXX.json)
trap 'rm -f "${PAYLOAD_FILE}" "${VAR_FILE}"' EXIT

python3 - <<PYEOF > "${VAR_FILE}"
import json
print(json.dumps({
    "key": "KUBE_CONFIG",
    "value": """${KUBE_VALUE}""",
    "variable_type": "env_var",
    "protected": False,
    "masked": True
}))
PYEOF

VAR_HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST \
  -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  -H "Content-Type: application/json" \
  "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/variables" \
  -d @"${VAR_FILE}")

if [[ "${VAR_HTTP}" == "400" ]]; then
  curl -sf -X PUT \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    -H "Content-Type: application/json" \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/variables/KUBE_CONFIG" \
    -d @"${VAR_FILE}" > /dev/null
fi

ok "KUBE_CONFIG set on project ${PROJECT_ID}"

# ── 4. Enable runner ───────────────────────────────────────────────────────────
step "4/9 — Enabling runner ${RUNNER_ID}"

curl -s -o /dev/null \
  -X POST \
  -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/runners" \
  --form "runner_id=${RUNNER_ID}" || true

ok "Runner ${RUNNER_ID} enabled"

# ── 5. K8s deployment on Selene ────────────────────────────────────────────────
step "5/9 — Creating K8s Deployment + NodePort Service on Selene"

_ssh "${K8S_HOST}" bash -s <<SELENE_EOF
set -euo pipefail
kubectl create deployment ${APP_NAME} \
  --image=nginx:alpine --replicas=1 \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl expose deployment ${APP_NAME} \
  --port=80 --target-port=80 --type=NodePort -n default 2>/dev/null || true
kubectl rollout status deployment/${APP_NAME} -n default --timeout=60s
SELENE_EOF

NODE_PORT=$(_ssh "${K8S_HOST}" \
  kubectl get svc "${APP_NAME}" -n default -o "jsonpath={.spec.ports[0].nodePort}")

ok "NodePort: ${NODE_PORT}"

# ── 6. Apache VirtualHost on Astraea ──────────────────────────────────────────
step "6/9 — Configuring Apache VirtualHost on Astraea"

_ssh "${ASTRAEA_HOST}" bash -s <<ASTRAEA_EOF
set -euo pipefail
python3 -c "
content = '''<VirtualHost *:80>
    ServerName ${HOSTNAME_FQDN}
    ProxyPreserveHost On
    ProxyPass / http://${K8S_HOST}:${NODE_PORT}/
    ProxyPassReverse / http://${K8S_HOST}:${NODE_PORT}/
</VirtualHost>
'''
print(content, end='')
" | echo "${SSH_PASS}" | sudo -S tee /etc/apache2/sites-available/${APP_NAME}.conf > /dev/null
echo "${SSH_PASS}" | sudo -S a2ensite ${APP_NAME}.conf
echo "${SSH_PASS}" | sudo -S systemctl reload apache2
ASTRAEA_EOF

ok "Apache VirtualHost ${HOSTNAME_FQDN} active"

# ── 7. Cloudflare DNS CNAME ────────────────────────────────────────────────────
step "7/9 — Adding Cloudflare DNS CNAME"

DNS_RESP=$(curl -s -X POST \
  "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
  -H "X-Auth-Email: ${CF_EMAIL}" \
  -H "X-Auth-Key: ${CF_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"type\":\"CNAME\",\"name\":\"${APP_NAME}\",\"content\":\"${CF_TUNNEL_ID}.cfargotunnel.com\",\"proxied\":true,\"ttl\":1}" || true)

DNS_OK=$(echo "${DNS_RESP}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('success',False))" 2>/dev/null || echo "False")
if [[ "${DNS_OK}" != "True" ]]; then
  DNS_CODE=$(echo "${DNS_RESP}" | python3 -c "import sys,json; d=json.load(sys.stdin); errs=d.get('errors',[]); print(errs[0].get('code','') if errs else '')" 2>/dev/null || echo "")
  [[ "${DNS_CODE}" == "81057" ]] && ok "DNS CNAME already exists" || echo "  Warning: ${DNS_RESP}"
else
  ok "DNS CNAME ${HOSTNAME_FQDN} created"
fi

# ── 8. Cloudflare Tunnel route on Astraea ─────────────────────────────────────
step "8/9 — Adding cloudflared tunnel route"

_ssh "${ASTRAEA_HOST}" bash -s <<CF_EOF
set -euo pipefail
CF_CONFIG="/etc/cloudflared/config.yml"
if ! grep -q "hostname: ${HOSTNAME_FQDN}" "\${CF_CONFIG}"; then
  echo "${SSH_PASS}" | sudo -S sed -i \
    "/http_status:404/i\\  - hostname: ${HOSTNAME_FQDN}\\n    service: http://localhost:80" \
    "\${CF_CONFIG}"
fi
echo "${SSH_PASS}" | sudo -S systemctl restart cloudflared
CF_EOF

ok "cloudflared route added and restarted"

# ── 9. Cloudflare Access app + policy ─────────────────────────────────────────
step "9/9 — Creating Cloudflare Access app"

INCLUDE_JSON=$(python3 -c "
import json
emails = ['${ADMIN_EMAIL}']
extra = '${EXTRA_EMAIL}'.strip()
if extra and extra != '${ADMIN_EMAIL}':
    emails.append(extra)
print(json.dumps([{'email': {'email': e}} for e in emails]))
")

ACCESS_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'name': '${APP_NAME}',
    'domain': '${HOSTNAME_FQDN}',
    'type': 'self_hosted',
    'session_duration': '24h',
    'allowed_idps': ['${CF_IDP_ID}'],
    'auto_redirect_to_identity': True
}))")

ACCESS_RESP=$(curl -s -X POST \
  "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/access/apps" \
  -H "X-Auth-Email: ${CF_EMAIL}" \
  -H "X-Auth-Key: ${CF_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "${ACCESS_PAYLOAD}" || true)

ACCESS_APP_ID=$(echo "${ACCESS_RESP}" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d['result']['id'] if d.get('success') else '')" 2>/dev/null || echo "")

if [[ -n "${ACCESS_APP_ID}" ]]; then
  curl -sf -X POST \
    "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/access/apps/${ACCESS_APP_ID}/policies" \
    -H "X-Auth-Email: ${CF_EMAIL}" \
    -H "X-Auth-Key: ${CF_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"Allow users\",\"decision\":\"allow\",\"precedence\":1,\"include\":${INCLUDE_JSON}}" > /dev/null
  ok "Cloudflare Access app created (ID=${ACCESS_APP_ID})"
else
  ok "Cloudflare Access app may already exist — skipping"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  ${APP_NAME} — Provisioned Successfully${RESET}"
echo -e "${BOLD}════════════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${GREEN}GitLab:${RESET}     ${GITLAB_URL}/${NAMESPACE}/${APP_NAME}"
echo -e "  ${GREEN}Public URL:${RESET} https://${HOSTNAME_FQDN}"
echo -e "  ${GREEN}NodePort:${RESET}   ${K8S_HOST}:${NODE_PORT}"
echo ""
echo -e "${BOLD}Next steps for the developer:${RESET}"
echo ""
echo -e "  1. Clone the repo:"
echo -e "     git clone ${GITLAB_URL}/${NAMESPACE}/${APP_NAME}.git"
echo ""
echo -e "  2. Add your files (Dockerfile, index.html) and push:"
echo -e "     git add . && git commit -m 'initial app' && git push origin main"
echo ""
echo -e "  3. Build runs automatically. Then go to:"
echo -e "     ${GITLAB_URL}/${NAMESPACE}/${APP_NAME}/-/pipelines"
echo -e "     Click ▶ next to 'deploy' to go live."
echo ""
echo -e "  4. Visit https://${HOSTNAME_FQDN}"
echo -e "     (Google auth via Cloudflare Access required)"
echo -e "${BOLD}════════════════════════════════════════════════════════${RESET}"
