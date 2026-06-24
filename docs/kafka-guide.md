# Kafka Message Broker Guide

## Purpose

Kafka is the asynchronous event backbone of the D-NAVIO platform.

It supports publish/subscribe communication between platform components such as
DML, DYNAMO, DSS, XAI Suite, Cybersecurity Toolkit, FRS, UI backend, and
observability services, as well as external partners (e.g. Maggioli).

Kafka is not used as a database. It carries live events and integration messages.

## Authentication

Every network-reachable Kafka listener requires a **Keycloak-issued OAuth token**
(SASL/OAUTHBEARER). There is no anonymous access. See
[operations/kafka-auth.md](operations/kafka-auth.md) for the full model; the short
version:

| Listener | Address | Security | Used by |
|----------|---------|----------|---------|
| INTERNAL | `kafka:9092` | SASL_PLAINTEXT / OAUTHBEARER | in-cluster D-NAVIO services |
| EXTERNAL | `147.102.6.143:30094` | SASL_PLAINTEXT / OAUTHBEARER | external partners |
| BROKER | `127.0.0.1:9091` | PLAINTEXT (loopback) | broker inter-broker only |
| CONTROLLER | `127.0.0.1:9093` | PLAINTEXT (loopback) | KRaft quorum only |

Clients obtain a token from Keycloak (realm `d-navio`, client credentials grant)
and present it during the SASL handshake. The broker validates the token's
signature, issuer, and audience against Keycloak.

## Namespace

The Kubernetes development namespace is `dnavio-dev`. All scripts default to it;
override with `DNAVIO_NAMESPACE`:

```bash
DNAVIO_NAMESPACE=my-namespace ./scripts/kafka/list-topics.sh
```

## Topics

| Topic                              | Owner | Description                                  |
|------------------------------------|-------|----------------------------------------------|
| `dnavio.dml.telemetry.raw`         | DML   | Raw sensor / operational readings ingested   |
| `dnavio.dml.telemetry.normalized`  | DML   | Validated / normalized telemetry             |
| `dnavio.frs.failures.reported`     | FRS   | Failure events reported by FRS               |
| `dnavio.dml.deadletter`            | DML   | Messages that could not be processed         |

Topic naming convention: `dnavio.<owning-domain>.<event>[.<detail>]` — dots only,
no underscores. The owning domain (`dml`, `frs`, …) is the service responsible
for producing to the topic.

Topics are defined declaratively in `helm/dnavio-platform/values.yaml` (and the
per-environment `values-<env>.yaml`) and created by the `kafka-topics-init` Helm
hook Job on every install/upgrade.

## Scripts

All scripts run inside the cluster via `kubectl exec` and authenticate using the
`dnavio-api` client secret read from the `keycloak-client-secrets` Secret. They
require `kubectl` access to the `dnavio-dev` namespace.

### List Topics

```bash
./scripts/kafka/list-topics.sh
```

### Create Topics

```bash
./scripts/kafka/create-topics.sh
```

Idempotent (`--if-not-exists`). Normally unnecessary — the Helm Job already
creates topics — but useful for ad-hoc additions.

### Produce Test Message

```bash
./scripts/kafka/produce-test-message.sh dnavio.dml.telemetry.raw
```

### Consume Topic

```bash
./scripts/kafka/consume-topic.sh dnavio.dml.telemetry.raw 10
```

## Example Event

```json
{
  "event_type": "sensor_update",
  "timestamp": "2026-05-26T12:00:00Z",
  "ship_id": "ship_001",
  "component_id": "pump_01",
  "sensor_id": "temp_01",
  "value": 82.4,
  "unit": "C"
}
```

## Architecture

```text
D-NAVIO components / external partners
        │ publish events (OAuth token required)
        ▼
Kafka Message Broker (dnavio-dev / kafka:9092 internal, :30094 external)
        │ consume events (OAuth token required)
        ▼
DYNAMO / DML / DSS / XAI / FRS / UI backend / Observability
```

| Layer          | Responsibility                          |
|----------------|------------------------------------------|
| Kafka          | live events / async communication        |
| Database / DML | structured, persisted data               |
| MinIO          | files, datasets, large artefacts         |
| Backend APIs   | current state, mappings, query access    |
