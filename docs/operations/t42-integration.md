# T4.2 (DML / FRS) Integration Contract

How the T4.2 services (`D-NAVIO-Project/d-navio-t4.2`) run against the D-NAVIO
platform instead of their own bundled broker and databases. The platform side
is implemented in this chart; the **T4.2 side is not yet changed** — see
[Required changes in d-navio-t4.2](#required-changes-in-d-navio-t42).

T4.2 is deployed into the same namespace as the platform (`dnavio-dev`,
`dnavio-pilot`), so every endpoint below is an in-cluster Service name.

## What the platform provides

| Need | Platform endpoint | Notes |
|------|-------------------|-------|
| Message broker | `kafka:9092` | INTERNAL listener: `SASL_PLAINTEXT`, mechanism `OAUTHBEARER` |
| Token endpoint | `http://keycloak:8080/realms/d-navio/protocol/openid-connect/token` | client-credentials grant; tokens live 5 min |
| Relational store | `postgres:5432`, database `dnavio` | PostgreSQL 16, T4.2 schema pre-loaded |
| Document store | `mongo:27017`, database `dnavio` | MongoDB 7.0, auth enabled, T4.2 collections/indexes pre-created |
| Topics | all T4.2 topics pre-created | incl. `dnavio.frs.hydra.probability-update`, `dnavio.hydra.riskscores`, `dnavio.frs.incidents.cyber` |

The in-cluster token endpoint issues tokens whose `iss` is the pinned external
hostname, which is what the broker validates — no extra configuration needed.

### Credentials (Kubernetes Secrets in the same namespace)

| Secret | Keys | Use |
|--------|------|-----|
| `dnavio-component-credentials` | `svc-dml-client-id`, `svc-dml-client-secret`, `svc-frs-client-id`, `svc-frs-client-secret` | Kafka OAUTHBEARER client credentials |
| `dnavio-datastores` | `postgres-dsn`, `mongo-uri` (plus the individual user/password/database keys) | Ready-made connection strings |

Both are generated on first install and stay stable across upgrades
(`helm.sh/resource-policy: keep`). The Mongo URI uses a least-privilege
application user (`readWrite` on `dnavio` only), not root.

### Service → identity mapping

| T4.2 service | Kafka | Identity | Postgres | Mongo |
|--------------|-------|----------|----------|-------|
| `ingest-api` | produce | `svc-dml` | yes | — |
| `stream-processor` | consume + produce | `svc-dml` | yes | yes |
| `frs-api` | consume + produce | `svc-frs` | yes | yes |
| `frs-derive` | consume | `svc-frs` | yes | — |
| `hydra-packager` | consume + produce | `svc-frs` | yes | — |
| `query-api` | — | — | yes | yes |
| `pilot-replayer`, `metis-connector` | — (HTTP to `ingest-api`) | — | — | — |

The broker derives the Kafka principal from the token's `azp` claim, so these
appear as `User:svc-dml` / `User:svc-frs`. Topic ACLs are currently enforced
only on `dnavio.ops.admin-audit`; every other topic accepts any authenticated
client.

### Environment wiring for a T4.2 Deployment

```yaml
env:
  - name: DNAVIO_KAFKA_BROKERS
    value: "kafka:9092"
  - name: DNAVIO_POSTGRES_DSN
    valueFrom: { secretKeyRef: { name: dnavio-datastores, key: postgres-dsn } }
  - name: DNAVIO_MONGO_URI
    valueFrom: { secretKeyRef: { name: dnavio-datastores, key: mongo-uri } }
  - name: DNAVIO_MONGO_DB
    value: "dnavio"
  # Once T4.2 supports broker authentication (see below) — variable names are
  # T4.2's choice:
  - name: DNAVIO_KAFKA_CLIENT_ID
    valueFrom: { secretKeyRef: { name: dnavio-component-credentials, key: svc-dml-client-id } }
  - name: DNAVIO_KAFKA_CLIENT_SECRET
    valueFrom: { secretKeyRef: { name: dnavio-component-credentials, key: svc-dml-client-secret } }
  - name: DNAVIO_KAFKA_TOKEN_URL
    value: "http://keycloak:8080/realms/d-navio/protocol/openid-connect/token"
```

## Required changes in d-navio-t4.2

These are **not** made by the platform; they belong to the T4.2 owners.

1. **Kafka authentication (blocking).** `internal/broker/broker.go` builds its
   franz-go clients with no SASL, so the broker rejects them. Add OAUTHBEARER,
   off by default so the local docker-compose/Redpanda setup keeps working:

   ```go
   import (
       "github.com/twmb/franz-go/pkg/sasl/oauth"
       "golang.org/x/oauth2/clientcredentials"
   )

   ts := (&clientcredentials.Config{
       ClientID: id, ClientSecret: secret, TokenURL: tokenURL,
   }).TokenSource(ctx) // caches the token and refreshes it on expiry

   opts = append(opts, kgo.SASL(oauth.Oauth(func(ctx context.Context) (oauth.Auth, error) {
       tok, err := ts.Token()
       if err != nil {
           return oauth.Auth{}, err
       }
       return oauth.Auth{Token: tok.AccessToken}, nil
   })))
   ```

   The METIS connector already implements client-credentials and can share
   the configuration pattern. In-cluster, no TLS is needed (`kafka:9092` is
   `SASL_PLAINTEXT`).

2. **Drop the bundled infrastructure from the T4.2 chart**: `redpanda-*`,
   `postgres-*`, `mongo-*` templates and their PVCs/ConfigMaps. The platform
   already owns `postgres`, `mongo`, `postgres-data` and `mongo-data` in the
   same namespace, so Helm will refuse to install a second release that
   declares them.

3. **Remove hardcoded credentials.** The kompose templates embed
   `postgres://dnavio:dnavio@postgres:5432/...`; use the `secretKeyRef`
   wiring above.

4. **Fix the deploy workflow.** `deploy.yml` points at `./helm/frs-platform`,
   which does not exist (the chart is `deploy/compose/dnavio-t42/`); the values
   files are empty; images (`ingest-api`, …) have no build/publish step and no
   `imagePullPolicy`, so pods cannot start. Resource limits and probes are
   also missing.

5. **Pace the replay in shared environments.** A full replay publishes
   ~7.5M records in ~5 minutes while persistence drains at ~7,400/s. The
   telemetry topics are capped at 512 MiB per partition (the dev broker
   volume is 2 GiB), so an unpaced replay can age out records before
   `stream-processor` consumes them. Use `DNAVIO_REPLAY_SPEED` or
   `DNAVIO_REPLAY_MAX_ROWS` on dev/pilot.

## Schema ownership

The initial schema is a byte-identical copy of T4.2's `db/` scripts, pinned to
a commit — see `helm/dnavio-platform/files/datastores/README.md`. Init scripts
only run on an **empty** volume, so once a store holds data, schema changes
must ship as migrations (owned by T4.2) rather than edits to the copied files.
