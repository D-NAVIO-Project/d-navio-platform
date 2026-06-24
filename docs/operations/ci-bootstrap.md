# CI Bootstrap

## Purpose

This document describes the CI/CD pipeline for the D-NAVIO repository on GitHub.

The pipeline runs on every push and pull request (validate jobs) and deploys to
dev, integration, and pilot environments on every merge to `main` (deploy jobs).

## Workflows

The pipeline is defined in `.github/workflows/`:

```text
validate.yml   — runs on every push and PR
deploy.yml     — runs after Validate succeeds on main
```

## Validate Jobs

All validate jobs run on GitHub-hosted `ubuntu-latest` runners. No secrets or
cluster access required.

| Job | What it checks |
|-----|----------------|
| `validate-yaml` | YAML syntax for `.github/`, `helm/`, `infra/` via `scripts/ci/validate-yaml.py` |
| `shellcheck` | Shell scripts under `scripts/` — `--severity=error` |
| `helm-lint` | Helm chart linted against all three environment values files |
| `kubeconform` | Rendered Helm manifests validated against Kubernetes 1.30 schema |
| `docker-compose-validate` | `docker/docker-compose.dev.yml` config syntax |
| `check-executable` | Operational scripts retain their executable bit |
| `check-docs` | Key documentation files are present |

## Deploy Jobs

Deploy jobs run on the self-hosted `dnavio-vm` runner (the kubeadm dev VM).
They require GitHub environment secrets `KEYCLOAK_ADMIN_PASSWORD` and
`MINIO_ROOT_PASSWORD` to be configured per environment in the GitHub repo
settings.

Deployment order: `dev` → `integration` → `pilot`. Each stage gates on the
previous one succeeding.

All deploys use:

```bash
helm upgrade --install dnavio-platform ./helm/dnavio-platform \
  --namespace <env> \
  --create-namespace \
  -f helm/dnavio-platform/values-<env>.yaml \
  --wait --timeout 10m --atomic
```

Passwords are injected at deploy time via a temporary values file — never
written to the repository.

## Run Validate Locally

```bash
# YAML syntax
python3 scripts/ci/validate-yaml.py

# Shell lint
shellcheck --severity=error scripts/*.sh scripts/kafka/*.sh

# Helm lint
helm lint ./helm/dnavio-platform -f helm/dnavio-platform/values-dev.yaml

# Kubernetes schema validation
helm template dnavio-platform ./helm/dnavio-platform \
  -f helm/dnavio-platform/values-dev.yaml \
  --set keycloak.adminPassword=placeholder \
  --set minio.rootPassword=placeholder \
  | kubeconform -strict -summary -kubernetes-version 1.30.0 -
```

## Self-Hosted Runner Setup

The deploy pipeline requires a GitHub Actions runner registered on the kubeadm
VM with the label `dnavio-vm`. See GitHub → Settings → Actions → Runners to
generate the registration token and follow the Linux runner install instructions.

## Current Limitations

- No TLS — all services run over HTTP in dev mode
- No persistent database for Keycloak — realm config is lost on pod restart
- Secrets injected via CI `--set` flags — proper secrets management is a
  future branch

## Next Improvements

- `feat/keycloak-baseline` — realm setup, client config, token scripts
- `feat/rbac-access-model` — Kubernetes RBAC for team and partners
- `feat/secrets-management` — replace CI `--set` with proper secrets store
