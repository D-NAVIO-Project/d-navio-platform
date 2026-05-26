# D-NAVIO Architecture Overview

## Purpose

This document describes the initial platform architecture for D-NAVIO.

The goal of the platform is to provide a reproducible and documented
starting point for event-driven ingestion, authentication, and storage
of datasets and digital twin related artifacts.

## Core Services

The initial platform includes:

- Kafka for event streaming
- Keycloak for authentication and identity management
- MinIO for object storage

## High-Level Architecture

```text
External Systems / Partners
        │
        │ upload raw datasets / files
        ▼
      MinIO
        │
        │ emit metadata + object reference
        ▼
      Kafka
        │
        │ trigger processing / analytics / digital twin workflows
        ▼
Processing Services

Authentication / authorization handled by Keycloak
```

## Design Principles

### 1. Bulk data is stored in MinIO
Large files, raw datasets, binary artifacts, and exports are stored in MinIO.

### 2. Kafka carries events and metadata
Kafka is used for:

- telemetry event streaming
- alerts, failures, and risk events
- orchestration signals and lifecycle events
- processing notifications

Kafka is not treated as persistent operational storage. Persistent structured
telemetry, alerts, failures, and risk states are expected to be owned by the
relevant DML/backend/FRS services, while MinIO stores large artefacts such as
datasets, exports, binary files, and optional visualization assets.

### 3. Keycloak manages access
Keycloak is used for:

- service authentication
- user authentication
- authorization for platform services

## Example Data Flow

1. A partner or external system uploads a dataset to MinIO
2. A metadata event is published to Kafka
3. A processing service consumes the event
4. The processing service reads the file from MinIO
5. Results are stored back in MinIO or emitted as new Kafka events

## Initial Development Scope

The initial development scope includes both the validated Docker Compose baseline
and a Kubernetes bootstrap deployment for the development cluster.

- single-node Kafka in KRaft mode
- single Keycloak instance
- single MinIO instance

## Future Extensions

Potential future extensions include:

- persistent external database for Keycloak
- TLS and secret management
- production deployment topology
- monitoring and observability
- multi-node scaling
