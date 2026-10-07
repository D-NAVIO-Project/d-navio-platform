# dnavio-component

Runs a partner's components on the D-NAVIO platform from one values file.
Partners do not write Kubernetes manifests: they list their services, and this
chart turns each one into a Deployment and (if it has a port) a Service, both
named `<partner>-<component>`.

Design background: [docs/design/partner-integration-model.md](../../docs/design/partner-integration-model.md).
Full example: [examples/t42-values.yaml](examples/t42-values.yaml).

## Values file

```yaml
partner: t42
components:
  - name: ingest-api
    image: t42/ingest-api          # no tag: the build supplies it
    port: 8081
    health: { readiness: /readyz, liveness: /healthz }
    memory: 64Mi                   # request and limit
    env:
      DNAVIO_KAFKA_BROKERS: kafka:9092
    secretEnv:
      DNAVIO_KAFKA_CLIENT_SECRET: credentials/svc-dml-client-secret
      DNAVIO_POSTGRES_DSN: partner/postgres-dsn
```

| Field | Required | Meaning |
|-------|----------|---------|
| `name` | yes | Lowercase letters, digits, hyphens; unique within the partner |
| `image` | yes | Repository without tag, e.g. `t42/ingest-api` |
| `memory` | yes | `Mi` or `Gi`; used as both request and limit |
| `port` | no | Container port; also creates Service `<partner>-<name>` |
| `health` | with `port` | HTTP path for both probes, or `{readiness: ..., liveness: ...}` |
| `healthCommand` | without `port` | Command that exits 0 when healthy |
| `cpu` | no | CPU request |
| `replicas` | no | Default 1 |
| `command`, `args` | no | Override the image entrypoint |
| `env` | no | Literal, non-secret settings |
| `secretEnv` | no | `VAR: <alias>/<key>`, values read from a Secret |

### Secret aliases

| Alias | Holds |
|-------|-------|
| `credentials` | `<client>-client-id`, `<client>-client-secret` for the partner's Keycloak identities (provided by the platform) |
| `partner` | The partner's own credentials, in Secret `<partner>-secrets`: connection strings for the datastores it runs, and third-party keys. Created by the partner's own chart, or by NTUA on request |

## Rules enforced

The chart refuses to render, with a message naming the component and field,
when a values file:

- deploys a platform service (an image named `kafka`, `redpanda`, `keycloak`,
  `minio`, …) — use the platform's instead
- deploys a datastore (`postgres`, `mongo`, `redis`, …) — partners run their
  own datastores, but with their own chart, since this one has no volumes
- omits `memory`, or a health check
- pins an image tag or digest — the build sets the tag to the git SHA
- puts a credential-like variable (`*PASSWORD*`, `*SECRET*`, `*TOKEN*`,
  `*API_KEY*`) in `env` instead of `secretEnv`
- references a Secret other than the aliases above
- references a Secret key that does not exist (checked against the live cluster)
- reuses a component name, or uses an invalid name

## Deploying from your repository

Add one workflow to your repository. It builds each image on the platform VM
and then deploys your release; every push to `main` redeploys.

```yaml
# .github/workflows/dnavio-deploy.yml
name: Deploy to D-NAVIO
on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read

jobs:
  build:
    strategy:
      max-parallel: 1          # one shared build machine
      matrix:
        service: [ingest-api, stream-processor, frs-api,
                  frs-derive, hydra-packager, query-api]
    uses: D-NAVIO-Project/d-navio-platform/.github/workflows/build-component.yml@main
    with:
      partner: t42
      image: ${{ matrix.service }}
      dockerfile: deploy/compose/Dockerfile
      build-args: SERVICE=${{ matrix.service }}

  deploy:
    needs: build
    uses: D-NAVIO-Project/d-navio-platform/.github/workflows/deploy-component.yml@main
    with:
      partner: t42
      values: deploy/dnavio-values.yaml
      # chart: deploy/infra      # optional: your own chart, see below
      environment: dev
      logs: true                 # optional: print startup logs after deploying
```

- Images are named `<partner>/<image>:<commit sha>`; the `image` entries in
  your values file must match (`t42/ingest-api`).
- If a component does not become ready, the deploy fails and the run log shows
  that pod's events and recent logs — you do not need cluster access to debug.
  **If your repository is public, so are those logs.**
- `platform-ref` (default `main`) selects the chart version; keep it equal to
  the `@ref` you call the workflows with.

## Connecting to the platform

Components run in the platform namespace, so platform services resolve by
short name: `kafka:9092` (SASL_PLAINTEXT, OAUTHBEARER) and the token endpoint
`http://keycloak:8080/realms/d-navio/protocol/openid-connect/token`.

**Platform data comes through Kafka topics**; the platform's databases are run
by T4.2 (Data Management Layer) and are not accessed directly.

## Your own chart

For what this chart cannot run — a database, a StatefulSet, a CronJob — pass
your own chart to the deploy workflow (`chart: deploy/infra`). It is installed
as release `<partner>-infra`, before your components, after an automated check
(`scripts/partner-policy/check_partner_chart.py`): every resource named
`<partner>-...`, allowed kinds only (workloads, Services, ConfigMaps, Secrets,
PVCs), `ClusterIP` Services only, memory limits on every container, no host
access or privileged containers, no platform service images, no literal
credentials. Start from [examples/infra-chart](examples/infra-chart): a
PostgreSQL whose connection string lands in `<partner>-secrets` for your
components to read as `partner/postgres-dsn`.
Other components of the same partner are reachable at
`http://<partner>-<component>:<port>`.

## Not supported yet

- **Volumes** (e.g. mounting datasets), StatefulSets, CronJobs — use your own
  chart (above).
- Ingress (exposing a service outside the cluster) — ask the NTUA team.
