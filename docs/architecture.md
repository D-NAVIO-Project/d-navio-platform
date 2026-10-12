# D-NAVIO Architecture Overview

## Purpose

This document describes the platform architecture for D-NAVIO: the shared
services every component uses, and where data lives.

## Core Services

The platform provides:

- Kafka for event streaming between components
- Keycloak for authentication and identity management

Data stores are not platform services. Each component runs the stores it owns
(T4.2's Data Management Layer runs PostgreSQL and MongoDB), and other components
receive that data through Kafka topics or the owner's APIs.

> MinIO appeared in the initial example as a placeholder for object storage. It
> is not part of the platform; the chart still deploys it until it is removed.

## High-Level Architecture

```text
Pilot data sources / partner systems
        │
        │ telemetry, files (T4.2 ingest-api)
        ▼
T4.2 Data Management Layer ── stores ──► PostgreSQL · MongoDB (owned by T4.2)
        │
        │ validated live data, failure records
        ▼
      Kafka ◄──► other components (DYNAMO, DSS, XAI Suite, HYDRA, UI backend)

Every connection to Kafka is authenticated with a Keycloak token
```

## Design Principles

### 1. Kafka carries live events
Kafka is used for:

- telemetry event streaming
- alerts, failures, and risk events
- orchestration signals and lifecycle events
- processing notifications

Kafka is not persistent storage: each topic keeps data for a limited time.

### 2. Data stays with the component that owns it
Persistent structured telemetry, alerts, failures, and risk states are owned by
the relevant DML/backend/FRS services. Other components do not connect to those
databases: they consume the owner's topics, and data older than a topic's
retention comes from the owner's services (for T4.2, its query service).

### 3. Keycloak manages access
Keycloak is used for:

- service authentication
- user authentication
- authorization for platform services

## Example Data Flow

1. A pilot system or partner sends telemetry to T4.2's ingest API
2. T4.2 validates and stores it, and publishes it to `dnavio.dml.telemetry.normalized`
3. A consuming component reads the topic, authenticated with its Keycloak token
4. The consumer publishes its results as new Kafka events
5. Data older than the topic's retention is requested from T4.2's query service

## Initial Development Scope

The initial development scope includes both the validated Docker Compose baseline
and a Kubernetes bootstrap deployment for the development cluster.

- single-node Kafka in KRaft mode
- single Keycloak instance

## Future Extensions

Potential future extensions include:

- persistent external database for Keycloak
- TLS and secret management
- production deployment topology
- monitoring and observability
- multi-node scaling
