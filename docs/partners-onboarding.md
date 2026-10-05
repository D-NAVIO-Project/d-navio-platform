# Partner Onboarding Guide

How to connect your components to the D-NAVIO platform. Start here: this guide
tells you what to request from the NTUA team and which steps apply to you.

---

## Choose your path

| | **In-cluster** | **External** |
|---|---|---|
| Where your components run | On the D-NAVIO platform cluster | In your own environment (e.g. MAG) |
| How you reach the broker | `kafka:9092` inside the cluster | The external broker address, over TLS (sent with your credentials) |
| Credentials | Injected into your pods — you never handle them | Handed to you through a private channel |
| How you deploy | From your repository, with the shared workflows | Yourself, in your environment |
| Steps | 1, then [Path A](#path-a--in-cluster) | 1, then [Path B](#path-b--external) |

---

## Step 1 — Request access (both paths)

Open a **Partner onboarding request** issue in this repository:
**Issues → New issue → Partner onboarding request**.

The form asks for:

- your partner id (a short prefix for all your resources, e.g. `t42`), organisation and technical contact
- whether your components run in-cluster or externally
- the components you will deploy, with their memory (in-cluster)
- the identities you need (one per role that talks to the broker)
- the topics you produce and consume, with expected volume and retention
- the datastores you will run (in-cluster, for the capacity budget)
- a link to the AsyncAPI description of the topics you produce, if available

> **This repository is public, so the issue is visible to anyone.** Never put
> passwords, tokens, internal hostnames, IP addresses or personal data in it.

The NTUA team reviews the request, creates your identities, topics and access
rules, and replies on the issue. To change anything later (a new topic, more
memory), comment on the same issue.

---

## Path A — In-cluster

Your components run in the platform namespace, next to the broker. You never
see a credential: the platform stores them and injects them into your pods.

### A1. What the platform gives you

| | |
|---|---|
| Message broker | `kafka:9092` — `SASL_PLAINTEXT`, mechanism `OAUTHBEARER` |
| Token endpoint | `http://keycloak:8080/realms/d-navio/protocol/openid-connect/token` |
| Your identities | Referenced as `credentials/<client>-client-id` and `credentials/<client>-client-secret` |
| Your own secrets | Secret `<partner>-secrets`, referenced as `partner/<key>` |
| Object storage | MinIO, on request |

### A2. Prepare your code

- **Configuration from environment variables** — broker address, token
  endpoint, client id and secret, database connection strings. Nothing
  hard-coded.
- **Authenticate to Kafka with OAUTHBEARER** using the client-credentials grant.
  The client examples in the
  [Kafka integration guide, section 6](kafka-partner-integration.md#6-code-examples)
  apply with these in-cluster values: bootstrap `kafka:9092`, security protocol
  `SASL_PLAINTEXT` (no CA certificate needed), token endpoint
  `http://keycloak:8080/realms/d-navio/protocol/openid-connect/token`.
- **Health endpoints** — an HTTP path that answers when the service is ready
  (and optionally a separate one for liveness).
- **No bundled platform services** — use the platform's broker and Keycloak;
  do not ship Kafka, Redpanda or Keycloak of your own.
- **One image per service**, each with a Dockerfile.

### A3. Your datastores

If your components need a database, you run it yourself, with your own chart:

- name every resource with your partner prefix (`t42-postgres`, `t42-mongo`) so
  it cannot collide with other partners' resources;
- put its credentials in Secret `<partner>-secrets` (e.g. key `postgres-dsn`),
  never as literal values in templates;
- set memory limits and health checks, and keep storage within the budget
  agreed in your request.

Your services then read the connection string as `partner/postgres-dsn`.

### A4. Describe your services in a values file

Add `deploy/dnavio-values.yaml` to your repository. You do not write
Kubernetes manifests: the platform's component chart turns each entry into a
running service named `<partner>-<name>`.

```yaml
partner: t42
components:
  - name: ingest-api
    image: t42/ingest-api           # <partner>/<name>, no tag
    port: 8081
    health: { readiness: /readyz, liveness: /healthz }
    memory: 64Mi                    # request and limit
    env:
      DNAVIO_KAFKA_BROKERS: kafka:9092
    secretEnv:
      DNAVIO_KAFKA_CLIENT_ID: credentials/svc-dml-client-id
      DNAVIO_KAFKA_CLIENT_SECRET: credentials/svc-dml-client-secret
      DNAVIO_POSTGRES_DSN: partner/postgres-dsn
```

Full field reference and rules:
[helm/dnavio-component/README.md](../helm/dnavio-component/README.md).
A complete example for six services:
[helm/dnavio-component/examples/t42-values.yaml](../helm/dnavio-component/examples/t42-values.yaml).

The deploy is refused, with a message naming the component and field, if a
values file bundles a platform service or a datastore, omits memory or a health
check, pins an image tag, or puts a credential in `env` instead of `secretEnv`.

### A5. Add the deploy workflow

Add `.github/workflows/dnavio-deploy.yml` to your repository:

```yaml
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
      max-parallel: 1
      matrix:
        service: [ingest-api, stream-processor]
    uses: D-NAVIO-Project/d-navio-platform/.github/workflows/build-component.yml@main
    with:
      partner: t42
      image: ${{ matrix.service }}
      dockerfile: Dockerfile           # path in your repository
      build-args: SERVICE=${{ matrix.service }}

  deploy:
    needs: build
    uses: D-NAVIO-Project/d-navio-platform/.github/workflows/deploy-component.yml@main
    with:
      partner: t42
      values: deploy/dnavio-values.yaml
      environment: dev
```

> While the shared workflows are in preview, the NTUA team will tell you which
> version to reference instead of `@main`.

### A6. Deploy and debug

Every push to `main` builds your images and deploys them to the dev
environment. In the workflow run:

- **On success**, the run summary lists your running pods.
- **On failure**, the log contains the events and recent logs of every pod that
  did not become ready — you do not need cluster access to debug. If your
  repository is public, these logs are public too.

### A7. In-cluster checklist

- [ ] Onboarding request approved; identities and topics confirmed on the issue
- [ ] Code reads its configuration from environment variables
- [ ] Kafka client authenticates with OAUTHBEARER
- [ ] Health endpoints in every service
- [ ] Datastores (if any) prefixed, with credentials in `<partner>-secrets`
- [ ] `deploy/dnavio-values.yaml` and the deploy workflow added
- [ ] First deploy green; test message produced and consumed

---

## Path B — External

Your components run in your own environment and connect over the network.

1. **Receive your credentials.** Once your request is approved, the NTUA team
   sends you, through a private channel (never the issue), your client id and
   client secret, the D-NAVIO CA certificate (`ca.crt`), and the platform
   endpoints: the broker address (`<broker>`) and the Keycloak base URL
   (`<keycloak>`).
2. **Connect to the broker** following the
   [Kafka integration guide](kafka-partner-integration.md): broker `<broker>`
   (TLS), token endpoint
   `<keycloak>/realms/d-navio/protocol/openid-connect/token`.
3. **Browser login for users** (if you have a user interface): see the
   [SSO integration guide](sso-partner-integration.md).

---

## Rules at a glance

| Do | Don't |
|---|---|
| Use the platform's broker and Keycloak | Run your own Kafka, Redpanda or Keycloak |
| Prefix every resource with your partner id | Use generic names (`postgres`, `api`) |
| Keep credentials in Secrets | Put credentials in values files, issues or code |
| Set memory limits and health checks | Deploy without limits — the VM is shared |
| Name topics `dnavio.<component>.<entity>.<qualifier>` | Write to topics you have not requested |
| Request changes on your onboarding issue | Change platform resources yourself |

---

*Questions or problems: comment on your onboarding issue, or contact the NTUA team.*
