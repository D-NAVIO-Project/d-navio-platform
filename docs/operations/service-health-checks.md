# Service Health / Status Checks

## Kubernetes platform (dev, pilot)

Use [`scripts/operations/cluster-overview.sh`](cluster-overview.md). It replaces
the earlier `scripts/check-services.sh`, which only checked placeholder local
endpoints.

```bash
./scripts/operations/cluster-overview.sh          # full overview, including Kafka and telemetry
./scripts/operations/cluster-overview.sh --fast   # Kubernetes only
```

It covers the node, deployments, pods, restarts, jobs, PVCs, Helm releases,
Kafka connectivity, topics, telemetry flow and platform memory, with one
OVERALL verdict. See [cluster-overview.md](cluster-overview.md) for access,
options and how to read the output.

## Docker Compose baseline (local)

```bash
docker compose -f docker/docker-compose.dev.yml ps
```

Keycloak answers on `http://localhost:8080`; Kafka on `localhost:9092`. See
[install-docker.md](../install-docker.md).

## Troubleshooting

Check that kubectl points at the right cluster:

```bash
kubectl config current-context
kubectl get namespaces
```

Reach a ClusterIP service from your machine with a port-forward:

```bash
kubectl port-forward svc/<service-name> <local-port>:<service-port> -n <namespace>
```
