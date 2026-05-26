# Kafka Message Broker Guide

## Purpose

Kafka is used as the asynchronous event backbone of the D-NAVIO platform.

It supports publish/subscribe communication between platform components such as
DML, DYNAMO, DSS, XAI Suite, Cybersecurity Toolkit, FRS, UI backend, and
observability services.

Kafka is not used as a database. It carries live events and integration messages.

## Namespace

The Kubernetes development namespace is:

```bash
dnavio-dev
```

All scripts default to this namespace. Override with the `DNAVIO_NAMESPACE`
environment variable:

```bash
DNAVIO_NAMESPACE=my-namespace ./scripts/kafka/list-topics.sh
```

## Initial Logical Topics

| Topic                        | Description                                |
|------------------------------|--------------------------------------------|
| `dnavio.telemetry.raw`       | Raw sensor / operational readings          |
| `dnavio.telemetry.processed` | Validated/enriched telemetry after DML     |
| `dnavio.alerts`              | Threshold, risk, or monitoring alerts      |
| `dnavio.failures`            | Failure detection events                   |
| `dnavio.risk`                | Risk score / HYDRA indicator events        |

Topic naming convention: `dnavio.<domain>.<event-category>`

## Scripts

All scripts run inside the Kubernetes cluster via `kubectl exec`. They do not
require direct Kafka connectivity from the local machine.

### List Topics

```bash
./scripts/kafka/list-topics.sh
```

### Create Topics

```bash
./scripts/kafka/create-topics.sh
```

Creates all five D-NAVIO logical topics. Safe to run multiple times (`--if-not-exists`).

### Produce Test Message

```bash
./scripts/kafka/produce-test-message.sh <topic>
```

Example:

```bash
./scripts/kafka/produce-test-message.sh dnavio.telemetry.raw
```

### Consume Topic

```bash
./scripts/kafka/consume-topic.sh <topic> [max-messages]
```

Example — read last 10 messages from beginning:

```bash
./scripts/kafka/consume-topic.sh dnavio.telemetry.raw 10
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
D-NAVIO components
        │ publish events
        ▼
Kafka Message Broker (dnavio-dev / kafka:9092)
        │ consume events
        ▼
DYNAMO / DML / DSS / XAI / FRS / UI backend / Observability
```

| Layer          | Responsibility                         |
|----------------|-----------------------------------------|
| Kafka          | live events / async communication       |
| Database / DML | structured, persisted data               |
| MinIO          | files, datasets, large artefacts          |
| Backend APIs   | current state, mappings, query access     |
