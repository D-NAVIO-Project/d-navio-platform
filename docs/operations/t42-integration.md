# T4.2 (DML / FRS) Integration Contract

How the T4.2 services (`D-NAVIO-Project/d-navio-t4.2`) run on the D-NAVIO
platform. The platform side is in place; the **T4.2 side is not yet changed** —
see [Required changes in d-navio-t4.2](#required-changes-in-d-navio-t42).

## Who runs what

| | Run by | Notes |
|---|---|---|
| Message broker (Kafka), topics, ACLs | **Platform** | T4.2 drops its bundled Redpanda |
| Identity provider (Keycloak), `svc-dml` / `svc-frs` | **Platform** | Credentials injected into T4.2 pods |
| PostgreSQL and MongoDB | **T4.2** | With T4.2's schema, in T4.2's own chart |
| T4.2 services | **T4.2** | Via `helm/dnavio-component` and the shared build/deploy workflows |

Everything runs in the platform namespace (`dnavio-dev`, `dnavio-pilot`), so
the endpoints below are in-cluster Service names.

## What the platform provides

| Need | Endpoint | Notes |
|------|----------|-------|
| Message broker | `kafka:9092` | INTERNAL listener: `SASL_PLAINTEXT`, mechanism `OAUTHBEARER` |
| Token endpoint | `http://keycloak:8080/realms/d-navio/protocol/openid-connect/token` | client-credentials grant; tokens live 5 min |
| Topics | all T4.2 topics pre-created | incl. `dnavio.frs.hydra.probability-update`, `dnavio.hydra.riskscores`, `dnavio.frs.incidents.cyber` |

The in-cluster token endpoint issues tokens whose `iss` is the pinned external
hostname, which is what the broker validates — no extra configuration needed.

### Credentials

Secret `dnavio-component-credentials` holds `svc-dml-client-id`,
`svc-dml-client-secret`, `svc-frs-client-id` and `svc-frs-client-secret`. It
is generated on first install and stays stable across upgrades. In the
component values file these are referenced through the `credentials` alias,
e.g. `credentials/svc-dml-client-secret`.

### Service → identity mapping

| T4.2 service | Kafka | Identity |
|--------------|-------|----------|
| `ingest-api` | produce | `svc-dml` |
| `stream-processor` | consume + produce | `svc-dml` |
| `frs-api` | consume + produce | `svc-frs` |
| `frs-derive` | consume | `svc-frs` |
| `hydra-packager` | consume + produce | `svc-frs` |
| `query-api` | — | — |
| `pilot-replayer`, `metis-connector` | — (HTTP to `ingest-api`) | — |

The broker derives the Kafka principal from the token's `azp` claim, so these
appear as `User:svc-dml` / `User:svc-frs`. Topic ACLs are currently enforced
only on `dnavio.ops.admin-audit`; every other topic accepts any authenticated
client.

## What T4.2 runs: its datastores

T4.2 deploys its own PostgreSQL and MongoDB with its own chart (the component
chart runs stateless services only). Requirements, because they share the
platform namespace and VM:

- **Names prefixed `t42-`** — e.g. Services `t42-postgres`, `t42-mongo`, and
  their PVCs/ConfigMaps — so they cannot collide with other releases.
- **Credentials in Secret `t42-secrets`** — e.g. keys `postgres-dsn` and
  `mongo-uri` — never literal values in templates or values files. Services
  read them through the `partner` alias: `partner/postgres-dsn`.
- **Memory limits, readiness/liveness probes, and storage sized for the dev
  VM.** A full replay measured Postgres ~3.3 GB and Mongo ~0.8 GB.
- **Schema** is T4.2's: init scripts run only on an empty volume, so later
  changes ship as migrations.

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
   `SASL_PLAINTEXT`). Suggested variable names (T4.2's choice):
   `DNAVIO_KAFKA_CLIENT_ID`, `DNAVIO_KAFKA_CLIENT_SECRET`,
   `DNAVIO_KAFKA_TOKEN_URL`.

2. **Drop Redpanda** from the T4.2 chart and point all services at
   `kafka:9092`.

3. **Datastores** as described above: `t42-` names, credentials in
   `t42-secrets` instead of the hardcoded `postgres://dnavio:dnavio@...`,
   limits and probes.

4. **Services via the component chart.** Add `deploy/dnavio-values.yaml` —
   `helm/dnavio-component/examples/t42-values.yaml` is a ready-made draft for
   the six core services — and a workflow calling the shared
   `build-component.yml` and `deploy-component.yml` (example in
   `helm/dnavio-component/README.md`). This replaces the current `deploy.yml`,
   which points at `./helm/frs-platform` (does not exist) and has no image
   build.

5. **Pace the replay in shared environments.** A full replay publishes
   ~7.5M records in ~5 minutes while persistence drains at ~7,400/s. The
   telemetry topics are capped at 512 MiB per partition (the dev broker
   volume is 2 GiB), so an unpaced replay can age out records before
   `stream-processor` consumes them. Use `DNAVIO_REPLAY_SPEED` or
   `DNAVIO_REPLAY_MAX_ROWS` on dev/pilot.

## Testing

`scripts/tests/t42-integration-smoke.sh` checks the platform side from inside
the namespace: platform deployments and hook Jobs, memory limits, the
credentials Secret, topics and retention, and Kafka authentication as
`svc-dml` and `svc-frs` (including an ACL denial). T4.2's own datastores are
outside its scope.
