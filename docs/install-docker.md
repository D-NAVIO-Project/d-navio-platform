# Docker Bootstrap Installation Guide

## Purpose

This guide describes the Docker Compose bootstrap baseline for the D-NAVIO
platform. For the Kubernetes bootstrap setup, see
[`docs/install-k8s.md`](install-k8s.md).

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

Note: the local dev compose file pins Kafka to `linux/amd64` for compatibility
on Apple Silicon Docker Desktop setups.

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


## Validation

After starting the stack, verify the following services.

### Keycloak Validation

Open:

```text
http://localhost:8080
```

Log in with:

```text
username: admin
password: adminadmin
```

### MinIO Validation

Open:

```text
http://localhost:9001
```

Log in with:

```text
username: admin
password: adminadmin
```

### Kafka Validation

Kafka does not expose a web UI in this setup.
Validate Kafka using the CLI tools inside the container.

Create a test topic:

```bash
docker exec -it dnavio-kafka sh -lc 'kafka-topics --bootstrap-server kafka:9092 --create --topic test-topic --partitions 1 --replication-factor 1'
```

List topics:

```bash
docker exec -it dnavio-kafka sh -lc 'kafka-topics --bootstrap-server kafka:9092 --list'
```

If `test-topic` appears in the output, Kafka is working correctly.


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

## Kubernetes Deployment

For Kubernetes deployment, see the root README Kubernetes section.
The current Kubernetes baseline uses:

- kubeadm single-node cluster
- Flannel CNI
- local-path-provisioner for development PVCs
- namespace: `dnavio-dev`

