# D-NAVIO RBAC / Access Model

> **Status: DESIGN — partially enforced.**
> Identities and roles in this document are being provisioned in Keycloak.
> Kafka topic **authorization (ACLs) is NOT yet enforced** — the broker currently
> accepts any valid `d-navio` token (authentication only). ACL enforcement is
> deferred until producer/consumer contracts are confirmed with component owners
> (see [Topic Access Matrix](#topic-access-matrix-proposed--to-confirm)).

## Purpose

Define who (humans) and what (services) may access D-NAVIO platform resources,
and how that is realised in Keycloak and Kafka. This operationalises the access
requirements of the D4.1 architecture.

## Grounding in D4.1

| Reference | Requirement | Effect on this model |
|-----------|-------------|----------------------|
| AP01 — Single Entry & Trust Boundary | All access via the platform; backend/internal services accept only tokenized calls | Keycloak is the sole identity authority; no anonymous access |
| AP06 — Security by Design | Zero-trust, **least privilege**, service-to-service tokens, audit trails | One identity per component; grant only the topics/APIs each needs |
| AP02 — Separation of Concerns | Distinct components (DYNAMO, DML, DSS, XAI, Cybersecurity, FRS, XDTLib) | One service account per component |
| NFR-AUTH-01 | Reject invalid/expired tokens; **log security events** | Broker/API validate tokens; auth failures are logged |
| FR-AUTH-02 / PLATFORM-REQ-07 | Role-based access — Operator, Analyst, Integrator, Admin | Four human realm roles |

## Principal Types

D-NAVIO has two kinds of principal, both issued by the `d-navio` Keycloak realm.

### 1. Machine identities (service accounts)

Confidential clients using the **client-credentials** grant. One per component so
that least privilege (AP06) and audit (NFR-AUTH-01) are per-component.

Naming convention: `svc-<component>`.

**In scope for this branch (near-term integration):**

| Client | Component | Notes |
|--------|-----------|-------|
| `svc-dml` | Data Management Layer | Ingestion/streaming; owns `dnavio.dml.*` topics |
| `svc-frs` | Failure Reporting System | Owns `dnavio.frs.*` topics |
| `svc-dynamo` | DYNAMO Core | DT orchestration/execution |

**Deferred to per-component onboarding:** `svc-dss`, `svc-xai`,
`svc-cybersecurity`, `svc-xdtlib`, `svc-ui-backend`.

> The existing `dnavio-api` client is retained as the platform **operations/tooling**
> identity (used by the Kafka scripts and the `kafka-topics-init` Job). It is not a
> component identity and will not receive component-scoped ACLs.
>
> Operational topics (e.g. `dnavio.dml.deadletter`) are consumed by a **platform-ops
> service account** — referred to as `svc-platform-ops` and currently fulfilled by
> `dnavio-api`. A human role is **never** a Kafka client principal.

### 2. Human roles (realm roles)

Assigned to users; surfaced by the UI (FR-AUTH-02). Enforced by the UI/backend
once those exist — defined here so the model is stable.

| Role | Intended capabilities (from D4.1) | Example requirements |
|------|-----------------------------------|----------------------|
| `operator` | Monitor vessel systems, dashboards, view DSS recommendations, receive alerts | FR-OPS-02, FR-DSS-01/02 |
| `analyst` | View/search incidents & failure reports, deeper analysis | FR-INC-01/02 |
| `integrator` | Request promotions Dev→Test→Operational, manage templates/components | FR-PLM-01, AP11 |
| `admin` | User/role administration, platform health, governance exports | FR-OBS-01, FR-GOV-02 |

Roles are additive; a user may hold several. `admin` is not a Keycloak realm-admin —
it is a platform role within the `d-navio` realm. Human roles are **never** used as
Kafka client principals; machine access to Kafka is always via a `svc-*` service
account.

## Connection Access Coverage

How each connection into and out of the platform is authenticated. The D-NAVIO
platform secures the resources it operates — the message bus (Kafka), IAM
(Keycloak) and object storage (MinIO). Partner-owned datastores (MongoDB,
PostgreSQL) are provisioned and secured by the owning component, not the platform.

| Connection | Mechanism | Status |
|------------|-----------|--------|
| Components → Kafka | SASL/OAUTHBEARER `d-navio` token via a `svc-*` service account | Implemented |
| Components → MongoDB | Datastore owned/secured by the component; credentials not platform-issued | Component-owned (out of platform scope) |
| Components → PostgreSQL | As MongoDB — component-owned datastore | Component-owned (out of platform scope) |
| External components → Kafka | External NodePort listener, `d-navio` token via a partner client | Mechanism ready; partner client at onboarding |
| External components → MongoDB | Partner-side datastore, not exposed by the platform | Out of platform scope |
| CI/CD → Kubernetes | GitHub Actions self-hosted runner on `dnavio-vm` using a kubeconfig context (cluster RBAC, not Keycloak) | Implemented |
| Maggioli ↔ D-NAVIO | Keycloak client in `d-navio` realm → Kafka external listener; token from the external Keycloak URL | Mechanism ready; client at onboarding |
| Component ↔ Component APIs (optional) | Service-to-service tokens (client credentials), AP01 trust boundary + AP05 versioned contracts | Proposed / future |

Kubernetes cluster access (kubeconfig / RBAC) and partner datastore access are
deliberately **out of the Keycloak scope** — Keycloak governs platform application
identity, not cluster or partner-internal infrastructure.

## Kafka Authorization

### Current state (this branch)

- **Authentication:** enforced on **client-facing listeners** — the INTERNAL and
  EXTERNAL listeners require a valid `d-navio` token. The loopback BROKER and
  CONTROLLER listeners are internal operational listeners, not exposed to partner
  clients (see [kafka-auth.md](kafka-auth.md)).
- **Authorization:** **not enforced** — no Kafka authorizer is enabled, so any
  authenticated client can produce/consume any topic.

### Enforcement plan (follow-up, needs confirmed contracts)

Enabling `StandardAuthorizer` makes Kafka **default-deny**: every producer and
consumer relationship must have an explicit ACL or the platform breaks. We
therefore do **not** enable it until the producer/consumer contracts below are
confirmed. When they are, each `svc-<component>` principal
(`User:service-account-svc-<component>`) receives:

- `WRITE` + `DESCRIBE` on topics it produces
- `READ` + `DESCRIBE` on topics it consumes, plus `READ` on its consumer group

### Topic Access Matrix (PROPOSED — TO CONFIRM)

Producers are inferred from the topic naming convention
(`dnavio.<owning-domain>.*`) and are reasonably firm. **Consumers are
placeholders and MUST be confirmed with each component owner before any ACL is
written.**

| Topic | Producer (by convention) | Consumers (PROPOSED — confirm) |
|-------|--------------------------|--------------------------------|
| `dnavio.dml.telemetry.raw` | `svc-dml` | `svc-dynamo`? `svc-xai`? |
| `dnavio.dml.telemetry.normalized` | `svc-dml` | `svc-dynamo`? `svc-dss`? `svc-xai`? `svc-frs`? |
| `dnavio.frs.failures.reported` | `svc-frs` | `svc-dss`? `svc-dml`? `svc-ui-backend`? |
| `dnavio.dml.deadletter` | `svc-dml` | `svc-platform-ops`? |

`?` marks an unconfirmed relationship. Do not translate these into ACLs.

## Contract Collection Template

To confirm the matrix, each component owner completes the following. One block per
component; this is the input that unlocks ACL enforcement.

```yaml
component: <name>              # e.g. DML, FRS, DYNAMO
service_account: svc-<name>
produces:
  - topic: dnavio.<domain>.<event>
    format: <json|avro>        # per AP05 Explicit Data Contracts
    schema_ref: <link/version> # versioned schema
consumes:
  - topic: dnavio.<domain>.<event>
    consumer_group: <group-id>
apis_exposed:                  # optional, for future API-level RBAC
  - path: <route>
    roles_allowed: [operator|analyst|integrator|admin]
```

## Realisation in Keycloak

- Service-account clients (`svc-dml`, `svc-frs`, `svc-dynamo`) and realm roles
  (`operator`, `analyst`, `integrator`, `admin`) are created idempotently by the
  `keycloak-realm-bootstrap` Job, alongside the existing `dnavio-api` client.
- Client secrets come from the `keycloak-client-secrets` Secret (injected at
  deploy time, never committed) — same pattern as `dnavio-api`.
- Human role→user assignment is manual (or via future user-federation) until the
  UI/identity onboarding flow exists.

## Audit & Logging (NFR-AUTH-01)

- Kafka logs every failed authentication (`invalid_token`) and, once ACLs are on,
  every authorization denial.
- Keycloak event logging (login/token events) should be enabled on the `d-navio`
  realm as part of the enforcement follow-up.

## Out of Scope / Next Steps

1. **Confirm the topic matrix** with DML, FRS, DYNAMO owners (blocks ACLs).
2. Enable `StandardAuthorizer` + write per-principal ACLs from confirmed contracts.
3. Add remaining service accounts (`svc-dss`, `svc-xai`, `svc-cybersecurity`,
   `svc-xdtlib`, `svc-ui-backend`) at their onboarding.
4. API-level RBAC (roles → routes) when the UI/backend lands.
5. Enable Keycloak realm event logging; TLS is tracked in `feat/secrets-management`.
