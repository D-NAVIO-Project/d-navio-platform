# Partner Integration Model

> **Status: PROPOSAL.** The approach below has been agreed within the NTUA
> platform team; it still needs agreement with the partners. Nothing here is
> implemented yet except where marked *(exists today)*. Points that still need a
> decision are listed under [Open decisions](#open-decisions).

## Goal

Every partner can add the components it needs, and those components can
communicate with the platform and with each other — without the NTUA platform
team building each component by hand, and without one partner's component
being able to take down the platform.

## Where we stand

### What already works *(exists today)*

Proven end to end by `apps/partner-mock` (external path) and
`scripts/tests/t42-integration-smoke.sh` (in-cluster path):

- **Identity**: any component can be given a Keycloak service account and obtain
  short-lived tokens (client-credentials grant).
- **Messaging**: Kafka with OAUTHBEARER on every listener — in-cluster
  (`kafka:9092`) and external over TLS (NodePort, dev CA).
- **Authorization**: topic ACLs are enforced per identity; the principal is the
  Keycloak client id (`User:svc-dml`).
- **Credentials delivery**: component credentials are kept in Kubernetes
  Secrets and injected into pods; partners never handle them.
- **Declarative topics**: topics and retention are declared in the platform
  chart and created on every deploy.
- **Partner documentation**: `docs/kafka-partner-integration.md` and
  `docs/sso-partner-integration.md` for externally hosted components.

### What stops partners from adding components themselves

The first in-cluster adopter, T4.2 (DML/FRS), exposed these gaps. The rest of
this document addresses each one.

| # | Gap | Effect today | Addressed in |
|---|-----|--------------|--------------|
| 1 | **No way to ship images.** Platform images are built on the VM and imported into its container runtime; only code in this repository can run. | T4.2 pods cannot start: no image build. | [Images](#1-images) |
| 2 | **No deployment standard.** Nothing tells a partner what its chart may and may not contain. | T4.2's chart bundles its own broker (duplicating the platform's) and uses unprefixed names. | [Deployment](#2-deployment-the-component-chart) |
| 3 | **Onboarding requires editing platform code.** Identities are a hard-coded list in the Keycloak bootstrap Job. | Every new partner is a custom script change. | [Onboarding](#3-onboarding-by-request) |
| 4 | **No isolation between partners.** Shared namespace, allow-all fallback for unlisted topics. | Name collisions; one partner's memory spike can evict the platform. | [Shared namespace](#4-one-shared-namespace) |
| 5 | **Short service names.** Kafka advertises `kafka:9092`. | Only works inside the platform namespace. | [Shared namespace](#4-one-shared-namespace) |
| 6 | **Capacity.** One VM, 11 GiB RAM. | Heavy components may not fit. | [Capacity](#5-capacity) |

## The model

The platform is a **shared service provider**; partners bring **components**.

- **NTUA** runs the broker and Keycloak, and onboards partners on request.
- **Partners** write their components and describe how to run them in a short
  values file. Partners that need datastores run their own (see
  [Datastores](#datastores-run-by-each-partner)). They build and deploy from their own repository using workflows
  provided by this repository.
- Everything runs in the **platform namespace** (`dnavio-dev`, `dnavio-pilot`),
  each partner as its **own Helm release**.

```
 Partner repo                                    Platform repo (NTUA)
 ────────────                                    ────────────────────
 services + Dockerfiles                          broker · Keycloak · MinIO
 deploy/dnavio-values.yaml                       helm/dnavio-component
 .github/workflows/deploy.yml ──calls──►         reusable build + deploy workflows
                                                 partners list (identities, topics)
                    onboarding request (issue) ─► applied by NTUA
                                      │
 ┌─ namespace dnavio-dev ─────────────▼────────────────────────────┐
 │  release dnavio-platform: kafka, keycloak, minio, credentials   │
 │  release t42:     t42-ingest-api, t42-stream-processor, ...     │
 │  release t42-db:  t42-postgres, t42-mongo, t42-secrets (own)    │
 │  release <next>:  <next>-...                                    │
 └─────────────────────────────────────────────────────────────────┘
```

### Responsibilities

| | NTUA platform team | Partner |
|---|---|---|
| Broker, Keycloak, TLS | owns and operates | uses |
| Datastores (Postgres, Mongo, ...) | — | **runs its own**, in its own chart |
| Identities, topics, ACLs | applies on request | **requests** (issue form) |
| Credentials Secrets | creates and keeps stable | references by key |
| Component chart, build/deploy workflows | provides and maintains | uses |
| Component code, Dockerfiles, values file | reviews on onboarding | **owns** |
| Message contracts (AsyncAPI) | hosts and reviews | **authors** for topics it produces |
| Deploying its components | provides runner | triggers from its own repo |

## 1. Images

Two steps. Partners call the same reusable workflows in both, so moving from
step A to step B changes nothing in partner repositories.

### Step A — build on the platform VM (now)

A reusable workflow in this repository builds a partner's image on the
platform runner and imports it into the VM's container runtime — the method
`test-producer` already uses *(exists today)*, generalised:

```yaml
# partner repo: .github/workflows/deploy.yml
jobs:
  build:
    strategy:
      matrix:
        service: [ingest-api, stream-processor, frs-api, frs-derive,
                  hydra-packager, query-api, pilot-replayer]
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
      environment: dev
```

- Images are tagged `<partner>/<image>:<git-sha>` and pulled with
  `imagePullPolicy: IfNotPresent`; `latest` is never used.
- Old images accumulate on the VM; a scheduled prune keeps disk usage bounded.
- **Limits**: single node only, and the build runs with Docker access on the
  platform VM (root-equivalent) — accepted for trusted partners, see
  [Security](#security-accepted-risks).

### Step B — GitHub Container Registry (later)

Triggered by either a second node or a partner whose builds should not run on
the platform VM:

- `build-component.yml` moves to GitHub-hosted runners and pushes to
  `ghcr.io/d-navio-project/<partner>/<image>:<git-sha>`.
- The cluster pulls with a read-only token from an **organisation bot
  account** (not a personal account), stored as an image pull Secret.
- Private repositories consume the organisation's GitHub Actions minutes.

## 2. Deployment: the component chart

This repository provides a generic chart, `helm/dnavio-component`. A partner
does not write Kubernetes manifests; it lists its services in one values file:

```yaml
# partner repo: deploy/dnavio-values.yaml
partner: t42
components:
  - name: ingest-api
    image: t42/ingest-api          # tag injected by the workflow (git SHA)
    port: 8081
    health: /readyz
    memory: 64Mi                   # becomes request and limit
    env:
      DNAVIO_COMPONENT: ingest-api
      DNAVIO_HTTP_ADDR: ":8081"
      DNAVIO_KAFKA_BROKERS: kafka:9092
    secretEnv:                     # <alias>/<key>
      DNAVIO_POSTGRES_DSN: partner/postgres-dsn
      DNAVIO_KAFKA_CLIENT_ID: credentials/svc-dml-client-id
      DNAVIO_KAFKA_CLIENT_SECRET: credentials/svc-dml-client-secret
  - name: stream-processor
    # ...
```

The chart turns each entry into a Deployment and a Service named
`<partner>-<name>` (e.g. `t42-ingest-api`), and enforces the rules by
construction:

| Rule | How it is guaranteed |
|------|----------------------|
| No platform services (broker, Keycloak, MinIO) | Their images are refused |
| No datastores in the service chart | Their images are refused — datastores go in the partner's own chart |
| Memory limits and health checks on every container | Required fields; the deploy fails without them |
| Credentials only from Secrets | `secretEnv` resolves only the `credentials` alias (platform identities) and the `partner` alias (`<partner>-secrets`, the partner's own) |
| Pinned images | The workflow supplies the git SHA tag |
| No name collisions | Every resource is prefixed with the partner name |
| Lower priority than the platform | Every pod gets the partner PriorityClass |

Each partner is a **separate Helm release** in the platform namespace, so it
deploys on its own schedule without touching the platform release. If two
releases try to own the same resource, Helm refuses — a collision fails
loudly instead of overwriting.

**Escape hatch**: a partner that needs something the component chart cannot
express (a StatefulSet, a CronJob) may ship its own chart, reviewed against the
same rules.

### Datastores: run by each partner

Partners that need a database run it themselves, as a second release from
their own chart (the component chart runs stateless services only). In the
shared namespace that chart must:

- prefix every resource with the partner id (`t42-postgres`, `t42-mongo`);
- keep credentials in Secret `<partner>-secrets`, which the partner's services
  read through the `partner` alias (`partner/postgres-dsn`);
- set memory limits and probes, and size storage within the agreed budget.

The platform provides only MinIO (object storage) as a shared store.

## 3. Onboarding by request

Partners **request**; NTUA **applies**. The request is a GitHub issue form in
this repository ("Partner onboarding request") asking for:

- partner name, organisation, technical contact
- hosting: in-cluster or external (e.g. MAG)
- identities needed, and what each is used for
- topics produced (with expected volume) and topics consumed
- datastores the partner will run (for the capacity budget)
- memory budget for all components
- link to the AsyncAPI contract for produced topics

NTUA applies it as **data, not code**: one entry in the platform values, which
the deploy turns into Keycloak clients, credential Secrets, topics and ACLs.

```yaml
# platform: helm/dnavio-platform/values.yaml
partners:
  - name: t42
    identities: [svc-dml, svc-frs]
    topics:
      - name: dnavio.frs.hydra.probability-update
        writers: [svc-frs]
        retention.ms: 2592000000
```

This replaces the hard-coded identity list in the Keycloak bootstrap Job.
External partners use the same entry; they just do not deploy into the cluster.

## 4. One shared namespace

All partners run in the platform namespace. This is acceptable for a small
consortium of trusted partners, with these safeguards:

| Risk in a shared namespace | Safeguard |
|---|---|
| Name collisions | Partner prefix on every resource, one Helm release per partner |
| A partner's memory use evicts the platform | **PriorityClasses**: platform pods high, partner pods lower — under memory pressure partner pods are evicted first. A **LimitRange** gives a default limit to any container that lacks one. |
| Per-partner memory cap (a ResourceQuota applies to the whole namespace) | Memory is declared per component in the values file; NTUA checks the total against the budget in the onboarding request |
| Any pod can mount any Secret in the namespace | Accepted for trusted partners — see [Security](#security-accepted-risks) |
| Topic access | Unaffected: Kafka authorizes by identity, not by namespace |

**Addressing**: short names (`kafka:9092`, `keycloak:8080`) work inside
the shared namespace. Kafka will nevertheless **advertise its
fully qualified name** (`kafka.<namespace>.svc.cluster.local:9092`), which works
inside the namespace too. If partners later move to their own namespaces,
their configuration keeps working. The change costs one Kafka restart.

Separate namespaces per partner become necessary when a partner is not fully
trusted, or needs a hard memory cap.

## 5. Capacity

| | Memory requests | Memory limits |
|---|---|---|
| Platform (Kafka, Keycloak, MinIO), per environment | 0.9 GiB | 1.6 GiB |
| Platform, dev + pilot | 1.8 GiB | 3.3 GiB |
| VM total | 11 GiB | |

Partners' datastores come out of their own budget. For reference, T4.2
reports **~140 MB for all its Go services combined**; its databases are the
heavier part (a full replay measured Postgres ~3.3 GB and Mongo ~0.8 GB of
data). The other risk is JVM-based, ML and simulation components (e.g. DSS,
XAI, DYNAMO/OSP). Plan:

1. **Measure** actual usage (`kubectl top pods -A`; requires metrics-server)
   before sizing anything.
2. **Run pilot only when needed** instead of continuously, freeing half the
   platform footprint.
3. **Request a larger VM before onboarding heavy components**, using the
   memory budgets from the onboarding requests.

## Security: accepted risks

For phase 1 these are accepted, on the basis that all partners are consortium
members and every onboarding is reviewed:

- **The shared runner has cluster-admin and Docker access.** Any workflow that
  runs on it can read every Secret and modify every component.
- **Shared namespace**: any pod can mount any Secret in the namespace,
  including other partners' credentials and datastore passwords.
- **Allow-all fallback**: topics without ACLs accept any authenticated client.

Revisit when any of these become true: a partner's code is not reviewed by the
consortium, real operational data flows through the platform, or the platform
is exposed beyond the consortium. The hardening path is in phase 3.

## Phases

| Phase | Platform (NTUA) | Partner |
|-------|-----------------|---------|
| **1 — first partner** | onboarding issue form; `partners` values driving identities, topics and ACLs; `helm/dnavio-component`; reusable build (step A) and deploy workflows; PriorityClasses + LimitRange; Kafka FQDN | T4.2: OAUTHBEARER in its Kafka client, drop Redpanda, own datastores with `t42-` names and `t42-secrets`, add `deploy/dnavio-values.yaml` |
| **2 — more partners** | GHCR builds (step B); deny-by-default ACLs (incl. consumer-group READ); metrics-server and capacity review | AsyncAPI contracts for produced topics |
| **3 — production** | separate namespaces and a namespace-scoped deploy runner where trust requires it; larger VM or second node; real domain and trusted certificates | — |

T4.2 is already part of the way through phase 1: the platform provides its
topics and identities (`docs/operations/t42-integration.md`). The deploy path
itself is proven by NTUA's reference component (`apps/test-producer`), which is
built and deployed through the shared workflows exactly as a partner would.

## Open decisions

To agree with the partners:

1. **Component chart**: do partners accept the values-file approach as the
   default, with their own chart only as an exception?
2. **Contracts**: is an AsyncAPI description required before onboarding, or
   can it follow?

Decided: partners run their own datastores; the platform does not host
partner databases.

For the NTUA team:

4. **GHCR bot account**: when to create it (needed for step B).
5. **Pilot schedule**: when does pilot need to run continuously?
6. **VM size**: request now, or after measuring actual usage?

> Note: `main` contains an empty `docs/partners-onboarding.md`. Once agreed,
> the partner-facing onboarding steps from this model can go there.
