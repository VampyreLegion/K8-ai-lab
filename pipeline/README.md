# GitLab Runner Setup

## Runner registration (run once after GitLab is deployed)

1. In GitLab: Settings → CI/CD → Runners → New project runner
2. Set tag: `docker-nyx`
3. Copy the token, then run:

```
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
```

## CI/CD Variables (set in GitLab project Settings → CI/CD → Variables)

| Key | Description | Masked |
|-----|-------------|--------|
| `KUBE_CONFIG` | base64-encoded kubeconfig from Selene (`cat ~/.kube/config \| base64 -w0`) | Yes |

`CI_REGISTRY`, `CI_REGISTRY_USER`, `CI_REGISTRY_PASSWORD` are auto-injected by GitLab when the built-in container registry is enabled.
