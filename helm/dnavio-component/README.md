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
      DNAVIO_POSTGRES_DSN: datastores/postgres-dsn
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
| `datastores` | `postgres-dsn`, `mongo-uri` (and the individual user/password/database keys) |
| `credentials` | `<client>-client-id`, `<client>-client-secret` for the partner's Keycloak identities |
| `partner` | The partner's own external credentials (e.g. a third-party API key), in Secret `<partner>-secrets`, created by NTUA on request |

## Rules enforced

The chart refuses to render, with a message naming the component and field,
when a values file:

- deploys platform infrastructure (an image named `kafka`, `redpanda`,
  `keycloak`, `postgres`, `mongo`, `minio`, …) — use the platform's instead
- omits `memory`, or a health check
- pins an image tag or digest — the build sets the tag to the git SHA
- puts a credential-like variable (`*PASSWORD*`, `*SECRET*`, `*TOKEN*`,
  `*API_KEY*`) in `env` instead of `secretEnv`
- references a Secret other than the aliases above
- references a Secret key that does not exist (checked against the live cluster)
- reuses a component name, or uses an invalid name

## Connecting to the platform

Components run in the platform namespace, so platform services resolve by
short name: `kafka:9092` (SASL_PLAINTEXT, OAUTHBEARER), `postgres:5432`,
`mongo:27017`, and the token endpoint
`http://keycloak:8080/realms/d-navio/protocol/openid-connect/token`.
Other components of the same partner are reachable at
`http://<partner>-<component>:<port>`.

## Not supported yet

- **Volumes** (e.g. mounting datasets). Ship the data in the image, or use your
  own chart under the same rules.
- StatefulSets, CronJobs, Ingress.
