# Installation Guide

## Purpose

This guide describes how to run the initial D-NAVIO platform stack
for development purposes.

## Prerequisites

Install the following:

- Docker
- Docker Compose
- Git

Optional:

- VS Code
- PyCharm

## Clone Repository

```bash
git clone https://github.com/epu-ntua/d-navio.git
cd d-navio
```

## Start Development Stack

```bash
docker compose -f docker/docker-compose.dev.yml up -d
```

## Verify Running Containers

```bash
docker ps
```

Expected containers:

- dnavio-kafka
- dnavio-keycloak
- dnavio-minio

## Access Services

### Kafka
Broker endpoint:

```text
localhost:9092
```

### Keycloak
Web UI:

```text
http://localhost:8080
```

Default development credentials:

```text
username: admin
password: adminadmin
```

### MinIO
API:

```text
http://localhost:9000
```

Console:

```text
http://localhost:9001
```

Default development credentials:

```text
username: admin
password: adminadmin
```

## Stop Stack

```bash
docker compose -f docker/docker-compose.dev.yml down
```

## Remove Volumes

```bash
docker compose -f docker/docker-compose.dev.yml down -v
```

## Notes for Future VM Deployment

For VM deployment the following will need to be validated:

- SSH access
- Docker installation
- exposed ports
- advertised Kafka listener configuration
- persistent storage paths
