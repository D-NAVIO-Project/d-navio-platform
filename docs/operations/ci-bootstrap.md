# CI Bootstrap

## Purpose

This document describes the initial CI baseline for the D-NAVIO repository on
GitLab.

The goal of this baseline is not to perform automated deployment, but to validate
repository quality before changes are merged. CD (deployment to dev/test/pilot
environments) is intentionally out of scope and will be addressed in a later
branch once the team aligns on environment strategy.

## Pipeline Stages

The current pipeline has one stage:

```text
validate
```

All jobs run on public images and require no GitLab runner with cluster access
or secrets.

## Jobs

### validate_yaml

Parses every YAML file under known repository paths and fails on syntax errors.

Targets:

- `.gitlab-ci.yml`
- `k8s/` (Kubernetes manifests)
- `infra/` (cluster prerequisites such as the storage provisioner)

`docker/docker-compose.dev.yml` is intentionally excluded — D-NAVIO's
operational direction is Kubernetes-only. The Docker Compose file remains in
the repo as the validated bootstrap baseline but is not gated by CI.

### shellcheck

Runs `shellcheck --severity=error` over all operational shell scripts:

- `scripts/*.sh`
- `scripts/kafka/*.sh`

Warnings pass; only real errors fail the job.

### check_executable

Asserts that operational scripts retain their executable bit:

- `scripts/check-services.sh`
- `scripts/kafka/create-topics.sh`
- `scripts/kafka/list-topics.sh`
- `scripts/kafka/produce-test-message.sh`
- `scripts/kafka/consume-topic.sh`

### check_docs

Asserts that key documentation exists. Protects against accidental file
removal during refactors.

- `docs/architecture.md`
- `docs/install-docker.md`
- `docs/install-k8s.md`
- `docs/kafka-guide.md`
- `docs/operations/service-health-checks.md`
- `docs/operations/ci-bootstrap.md`

## Run Locally

Same checks the CI runs, from the repository root:

```bash
python3 scripts/ci/validate-yaml.py
shellcheck --severity=error scripts/*.sh scripts/kafka/*.sh
```

`pyyaml` is the only Python dependency. `shellcheck` is widely packaged
(`apt install shellcheck`, `brew install shellcheck`); if it is not installed
locally, the GitLab pipeline will still run it.

## Current Limitations

This CI baseline does not yet perform:

- Kubernetes schema validation against a real API server
- Container image builds
- Security scanning
- Integration tests
- Deployment to any environment

## Next Improvements

Possible next steps, in roughly increasing complexity:

- Replace pure YAML syntax checks with `kubeconform` or `kubeval` for proper
  Kubernetes schema validation
- Add Markdown linting
- Add schema validation for Kafka event contracts
- Add Docker image build validation when D-NAVIO services are introduced
- Add deployment stages for `dnavio-dev` / `dnavio-test` / `dnavio-pilot`
  once the environment strategy is defined
