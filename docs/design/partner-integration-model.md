# Partner Integration Model

> **Status: PROPOSAL — for agreement between the NTUA platform team and partners.**
> Nothing in this document is implemented yet except where marked *(exists today)*.
> Decisions that need agreement are collected in [Open decisions](#open-decisions).

## Goal

Every partner can add the components it needs, and those components can
communicate with the platform and with each other — **without the NTUA platform
team building or wiring each component by hand**, and without one partner's
component being able to break another's.

## Where we stand

### What already works

Proven end to end by `apps/partner-mock` (external path) and
`scripts/tests/t42-integration-smoke.sh` (in-cluster path, 2026-09):

- **Identity**: any component can be given a Keycloak service account and
  obtain short-lived tokens (client-credentials grant).
- **Messaging**: Kafka with OAUTHBEARER on every listener — in-cluster
  (`kafka:9092`) and external over TLS (NodePort, dev CA).
- **Authorization**: topic ACLs are enforced per identity; the principal is the
  Keycloak client id (`User:svc-dml`).
- **Shared datastores**: PostgreSQL and MongoDB, with credentials delivered
  through Kubernetes Secrets.
- **Declarative topics**: topics and retention are declared in the platform
  chart and created on every deploy.
- **Partner documentation**: `docs/kafka-partner-integration.md` and
  `docs/sso-partner-integration.md` for externally hosted components.

### What stops partners from adding components themselves

The first in-cluster adopter, T4.2 (DML/FRS), exposed these gaps:

| # | Gap | Effect today |
|---|-----|--------------|
| 1 | **No way to ship images.** Platform images are built on the VM and imported into its container runtime (`imagePullPolicy: Never`); only code in this repository can run. | T4.2 pods cannot start: no registry, no build. |
| 2 | **No deployment contract.** Nothing tells a partner what its chart may and may not contain. | T4.2's chart bundles its own broker and databases, which collide with the platform's. |
| 3 | **Onboarding requires editing platform code.** Identities are a hard-coded list in the Keycloak bootstrap Job; topics and ACLs are edited by hand in `values.yaml`. | Every new partner is a custom change by the NTUA team. |
| 4 | **No isolation between partners.** Everything shares one namespace; ACLs fall back to allow-all for unlisted topics. | Name collisions; any partner can read/write any unlisted topic; one partner's memory spike can evict the platform. |
| 5 | **In-cluster addresses only work inside the platform namespace.** Kafka advertises `kafka:9092`; the datastore connection strings use `postgres:5432` / `mongo:27017`. | A component in another namespace can reach the bootstrap address but then fails on the advertised one. |
| 6 | **Capacity.** One VM, 11 GiB RAM. The platform alone takes **1.4 GiB of requests / 3.2 GiB of limits per environment** (dev + pilot = 6.4 GiB of limits). | A few partners' components will not fit. |

## Proposed model

The platform is a **shared service provider**. Partners are **tenants** that
bring their own components.

```
 Platform repo (NTUA)                            Partner repo (each partner)
 ────────────────────                            ───────────────────────────
 broker · Keycloak · datastores                  own services + Dockerfiles
 partners/<partner>.yaml   ◄── onboarding PR ──  own Helm chart (from template)
        │                                        own CI: build → push → deploy
        │ platform deploy                                   │
        ▼                                                   ▼
 ┌─ cluster ─────────────────────────────────────────────────────────────┐
 │  dnavio-dev (platform)          dnavio-dev-<partner> (tenant)          │
 │   kafka, keycloak,      ◄────    partner pods                          │
 │   postgres, mongo,      FQDN     credentials Secret  (created by       │
 │   minio                          ResourceQuota        platform deploy) │
 └───────────────────────────────────────────────────────────────────────┘
```

### Responsibilities

| | NTUA platform team | Partner |
|---|---|---|
| Broker, Keycloak, datastores, TLS | owns and operates | uses |
| Identity, topics, ACLs, namespace, quota | applies on merge | **requests** via `partners/<partner>.yaml` PR |
| Credentials Secret in the tenant namespace | creates and keeps stable | mounts |
| Component code, images, chart | reviews template conformance | **owns** |
| Message contracts (AsyncAPI) | hosts and reviews | **authors** for the topics it produces |
| Deploys of tenant components | provides runner + template | runs from its own repo |

### 1. Onboarding: one file per partner (gap 3)

A partner joins by opening a PR that adds one file to this repository:

```yaml
# partners/t42.yaml
name: t42
organisation: TUBS
contact: e.raptis@...
hosting: in-cluster            # in-cluster | external
identities:
  - clientId: svc-dml
    purpose: DML ingestion and stream processing
  - clientId: svc-frs
    purpose: Failure Reporting System
topics:
  produces:                    # topics this partner owns (creates and writes)
    - name: dnavio.frs.hydra.probability-update
      retention: 30d
  consumes:
    - dnavio.hydra.riskscores
datastores:
  postgres: true               # dedicated database + user
  mongo: true
quota:                         # in-cluster partners only
  memory: 2Gi
  cpu: "2"
contract: https://github.com/D-NAVIO-Project/d-navio-t4.2/blob/main/contracts/asyncapi.yaml
```

On merge, the platform deploy turns that file into: Keycloak clients and their
secrets, the topics and their ACLs, the tenant namespace with quota, a database
and user per enabled datastore, and a credentials Secret **inside the tenant
namespace**. The hard-coded identity list in the bootstrap Job is replaced by
these files. External partners (e.g. MAG) use the same file with
`hosting: external` — they get identity, topics and ACLs, but no namespace.

### 2. One namespace per partner (gaps 4, 5)

- `dnavio-<env>-<partner>`, e.g. `dnavio-dev-t42`.
- A **ResourceQuota** and **LimitRange** from the partner file cap what the
  tenant can consume, so a misbehaving component cannot evict the platform.
- Platform services are addressed by FQDN:
  `kafka.dnavio-dev.svc.cluster.local:9092`,
  `postgres.dnavio-dev.svc.cluster.local:5432`. This requires two platform
  changes: Kafka must **advertise** its FQDN on the INTERNAL listener, and the
  connection strings delivered to tenants must use FQDNs.
- The credentials Secret is created in the tenant namespace (Pods cannot read
  Secrets across namespaces).

### 3. Images and deployment (gaps 1, 2)

**Partner chart template** — a template chart in this repository that a
partner copies. Its rules:

- Components only. **No** broker, Keycloak, database or other platform
  infrastructure.
- Credentials only from the platform-provided Secret; no literal credentials.
- Memory requests and limits, readiness and liveness probes on every container.
- Pinned image tags (git SHA), never `latest`.
- Connects to platform services by FQDN.

**Pipeline** — each partner repository builds, publishes and deploys its own
components, from a reusable workflow provided by this repository:

1. Build on a **GitHub-hosted** runner and push to the GitHub Container
   Registry (`ghcr.io/d-navio-project/<partner>/<image>:<sha>`).
2. Deploy with `helm upgrade --install` into the tenant namespace.

### 4. Messaging rules (gap 4)

- **Topic naming**: `dnavio.<component>.<entity>.<qualifier>` (already used).
  A partner owns the prefix of the topics it produces.
- **Deny by default**: once every existing consumer has ACLs, switch the broker
  to `allow.everyone.if.no.acl.found=false`. Each partner then gets WRITE on
  the topics it owns (prefix ACLs), READ on the topics it consumes, and READ on
  its own **consumer groups** — the last one is the easy-to-miss permission
  that breaks consumers on the day deny-by-default is switched on.
- **Contracts**: every produced topic has an AsyncAPI description
  (`contracts/asyncapi.yaml` in T4.2 is the reference), linked from the
  partner file. Payloads follow the platform envelope.

## Security: the shared runner

All deploy jobs currently run on one self-hosted runner on the platform VM.
That runner has a **cluster-admin** kubeconfig and Docker access (Docker access
is root-equivalent on the host). Any workflow that runs on it — from any
repository allowed to use it — can therefore read every Secret and modify every
component, including other partners'. For a small consortium of trusted
partners this can be an **accepted, documented risk** in phase 1. For real
tenant isolation (phase 2):

- **Builds never run on the VM** — GitHub-hosted runners only (pipeline step 1).
- **Tenant deploys run on a separate runner** that has no Docker access and no
  admin kubeconfig; each deploy authenticates with a **ServiceAccount scoped to
  that tenant's namespace**, stored as a secret in the partner's repository.
- The platform runner (cluster-admin) is restricted to this repository via its
  runner group.

## Capacity (gap 6)

| | Memory requests | Memory limits |
|---|---|---|
| Platform, per environment | 1.4 GiB | 3.2 GiB |
| Platform, dev + pilot | 2.8 GiB | 6.4 GiB |
| VM total | 11 GiB | |

Kubernetes schedules on requests, so the platform fits comfortably, but limits
already exceed half of the VM. T4.2 alone adds eight services and its own
data volume. Realistic options: run **pilot only when needed** (scale to zero
otherwise), a **larger VM**, or a **second node** (which would also require a
registry — see decision 1 — and storage that is not node-local). Each partner's
quota is reserved out of whatever capacity is agreed.

## Phases

| Phase | Scope | Unblocks |
|-------|-------|----------|
| **1 — first tenant** | partner file + onboarding automation; tenant namespace + quota; FQDN addressing; chart template; reusable build/deploy workflow; T4.2 adopts it | T4.2 running on the platform |
| **2 — isolation** | deny-by-default ACLs; separate tenant deploy runner with namespace-scoped credentials; per-partner databases | more partners safely |
| **3 — production** | capacity (larger VM / second node); real domain + trusted certificates; contract validation in CI | pilot operation |

T4.2 is already ~half way to phase 1: the platform hosts its datastores,
topics and identities (`docs/operations/t42-integration.md`). Remaining on the
T4.2 side: OAUTHBEARER in its Kafka client, dropping its bundled
infrastructure, and an image build.

## Open decisions

1. **Registry**: GitHub Container Registry (recommended — no infrastructure to
   run, works with GitHub-hosted builds) vs. a registry inside the cluster.
   With GHCR, pulling private images needs a long-lived read token in each
   tenant namespace: from an organisation **bot account**, not a person's
   account. Alternatively the images could be public, if no partner objects.
2. **Namespace naming**: `dnavio-<env>-<partner>` as proposed?
3. **Datastores**: one shared `dnavio` database (as T4.2 uses today) or a
   dedicated database and user per partner (proposed)?
4. **Onboarding approval**: who reviews and merges `partners/*.yaml` PRs?
5. **Runner trust**: accept the shared cluster-admin runner for phase 1, or
   require the separate tenant runner before the first partner deploys?
6. **Capacity**: is a larger VM or second node available, and does pilot need
   to run continuously before the pilot phase?
7. **Contracts**: is an AsyncAPI description mandatory for every produced
   topic before onboarding, or can it follow?

> Note: `main` contains an empty `docs/partners-onboarding.md`. Once agreed,
> the partner-facing onboarding steps from this model can go there.
