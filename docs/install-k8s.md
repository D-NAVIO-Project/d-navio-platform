# Kubernetes Bootstrap Installation Guide

## Purpose

This guide describes how to deploy the D-NAVIO platform on a Kubernetes
development cluster. This is the deployment target introduced in the
`feat/k8s-bootstrap` branch.

The Docker Compose bootstrap baseline is documented separately in
[`docs/install-docker.md`](install-docker.md).

## Prerequisites

- A running Kubernetes cluster (validated with kubeadm + Flannel on a single-node VM)
- `kubectl` configured to reach the cluster
- Git

## Clone Repository

```bash
git clone https://github.com/epu-ntua/d-navio.git
cd d-navio
```

## Storage Provisioner

On bare kubeadm clusters there is no default StorageClass. PVCs will remain
in `Pending` without one.

Install the vendored local-path-provisioner (v0.0.30):

```bash
kubectl apply -f infra/local-path-provisioner.yaml
```

> **Note:** `local-path-provisioner` is used only for the single-node development cluster.
> Pilot-grade or production-like deployments should use a proper CSI-backed storage solution,
> such as Longhorn, Rook/Ceph, NFS CSI, or cloud-managed persistent volumes depending on the
> target infrastructure.

Verify the StorageClass is registered as default:

```bash
kubectl get storageclass
```

Expected output:

```text
NAME                   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
local-path (default)   rancher.io/local-path   Delete          WaitForFirstConsumer
```

## Deploy Platform Services

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/
```

## Verify

```bash
kubectl get pods,pvc,svc -n dnavio-dev
```

Expected:

- 3 pods `Running 1/1` — kafka, keycloak, minio
- 2 PVCs `Bound` — kafka-data, minio-data
- 3 Services `ClusterIP` — kafka, keycloak, minio

## Access Services

All services are `ClusterIP`. Use `kubectl port-forward` to reach them:

```bash
kubectl port-forward svc/keycloak 18080:8080 -n dnavio-dev
kubectl port-forward svc/minio 19000:9000 19001:9001 -n dnavio-dev
```

| Service       | Forwarded endpoint           |
|---------------|------------------------------|
| Keycloak      | `http://localhost:18080`     |
| MinIO Console | `http://localhost:19001`     |
| MinIO API     | `http://localhost:19000`     |

Default development credentials: `admin / adminadmin`

## Kafka Validation

After the broker pod is `Running`, create the D-NAVIO logical topics and
validate end-to-end producer/consumer exchange.

Create topics (idempotent — safe to run multiple times):

```bash
kubectl exec deploy/kafka -n dnavio-dev -- bash -c \
  'for t in dnavio.telemetry.raw dnavio.telemetry.processed dnavio.alerts dnavio.failures dnavio.risk; do
     kafka-topics --bootstrap-server kafka:9092 --create --topic "$t" \
       --partitions 1 --replication-factor 1 --if-not-exists
   done'
```

List topics:

```bash
kubectl exec deploy/kafka -n dnavio-dev -- \
  kafka-topics --bootstrap-server kafka:9092 --list
```

Producer test — publish one telemetry event:

```bash
echo '{"event_type":"sensor_update","timestamp":"2026-05-21T12:00:00Z","ship_id":"ship_001","component_id":"pump_01","sensor_id":"temp_01","value":82.4,"unit":"C"}' \
  | kubectl exec -i deploy/kafka -n dnavio-dev -- \
    kafka-console-producer --bootstrap-server kafka:9092 --topic dnavio.telemetry.raw
```

Consumer test — read it back:

```bash
kubectl exec deploy/kafka -n dnavio-dev -- \
  kafka-console-consumer --bootstrap-server kafka:9092 --topic dnavio.telemetry.raw \
  --from-beginning --max-messages 1 --timeout-ms 20000
```

The consumer should print the JSON message published above. This confirms:

- Kafka topic creation
- Producer publish
- Consumer receive
- Internal service DNS `kafka:9092`
- Message broker baseline

## Tear Down

```bash
kubectl delete namespace dnavio-dev
```

This removes all D-NAVIO platform resources in `dnavio-dev`. The
`local-path-provisioner` in the `local-path-storage` namespace is unaffected.
