# Cluster Overview

`scripts/operations/cluster-overview.sh` prints one snapshot of the platform
namespaces (`dnavio-dev`, `dnavio-pilot`): node, deployments, pods, restarts,
failed pods, jobs, PVCs, Helm releases, platform container memory and, on
request, Kafka topics and telemetry flow.

It changes nothing: no Deployment, Service, Secret or Helm release is touched.

## Access (on the platform VM)

Run it on the VM (`ssh <you>@147.102.6.143`), from a clone of this repository:

```bash
git clone https://github.com/D-NAVIO-Project/d-navio-platform.git   # once
cd d-navio-platform && git pull
```

The script needs a kubeconfig. If `kubectl get nodes` works for your user, run
it directly. Otherwise, as a member of `sudo`, use the cluster's admin
kubeconfig for that one command:

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf ./scripts/operations/cluster-overview.sh
```

That kubeconfig is cluster-admin: the script only reads, but other commands
run this way can change anything.

## Usage

```bash
./scripts/operations/cluster-overview.sh                 # snapshot, both namespaces (~2 s)
./scripts/operations/cluster-overview.sh --details       # plus the list of what is unhealthy
./scripts/operations/cluster-overview.sh --kafka         # plus topics and telemetry flow (~15 s)
./scripts/operations/cluster-overview.sh --kafka --window 60   # telemetry over the last hour
./scripts/operations/cluster-overview.sh --watch 5       # redraw every 5 s (Ctrl-C to stop)
./scripts/operations/cluster-overview.sh -n dnavio-dev   # one namespace only
```

With `--watch` and `--kafka` together, Kafka is checked at most every 300 s
(`--kafka-interval`), the rest on every refresh.

Exit status: `0` all OK, `1` at least one `[WARN]`, `2` usage error or no
cluster access, so it can also be used from cron or CI.

## Reading the output

| Tag | Meaning |
|-----|---------|
| *(none)* | OK |
| `[WARN]` | Needs attention now; makes the exit status 1 |
| `[INFO]` | Worth knowing, not a fault (e.g. old evicted pods, no telemetry) |

| Line | What it says | WARN when |
|------|--------------|-----------|
| Nodes, Node pressure | Node readiness; Memory/Disk/PID pressure (pressure means the kubelet evicts pods) | not Ready, any pressure |
| Memory budget | Memory requests and limits of all running pods against the node | requests ≥ 90% (INFO when limits exceed the node) |
| Deployments, Pods | Ready / total | any not ready |
| Restarts | Container restarts, with OOM kills and their age | a restart in the last 24 h |
| Failed pods | Failed/Unknown pods grouped by reason (`Evicted`, `DeadlineExceeded`, ...) | one failed in the last 24 h (older: INFO) |
| Jobs, PVCs | Failed jobs; PVCs not Bound | any |
| Kafka broker | The broker container is running | not running |
| Helm releases | Every release in the namespace, including pending ones | status other than `deployed` |
| kafka / keycloak memory | Real (anonymous) memory of the container against its limit, and OOM kills | ≥ 90% of the limit, or an OOM kill |
| Kafka client check | `--kafka`: a client authenticated with a Keycloak token and read offsets | the check failed |
| Kafka topics | `--kafka`: topics declared in the platform values exist | one missing |
| Telemetry | `--kafka`: messages that arrived in the window | received but not normalised |

### Broker running is not data arriving

These are separate lines on purpose:

- **Kafka broker: running** only means the container is up. The Kafka
  Deployment has no readiness probe, so this is not a test of the broker.
- **Kafka client check: OK** (`--kafka`) means the broker served a client that
  authenticated through Keycloak, i.e. the platform path works.
- **Telemetry** (`--kafka`) counts the messages on
  `dnavio.dml.telemetry.raw` (received by T4.2's ingest) and
  `dnavio.dml.telemetry.normalized` (processed by T4.2's stream-processor)
  whose timestamp falls in the window (default 15 min):

| raw | normalized | Means |
|-----|------------|-------|
| > 0 | > 0 | Telemetry is flowing |
| > 0 | 0 | Data arrives but T4.2's stream-processor is not processing it `[WARN]` |
| 0 | 0 | Nothing is being sent (e.g. no DANAOS feed, no replay running). The platform can still be healthy `[INFO]` |

## What `--kafka` does

It starts one short-lived pod per namespace, labelled
`dnavio.ops/cluster-overview`, from the broker's own image. The pod
authenticates as the platform operations identity `dnavio-api` (the secret is
mounted from `keycloak-client-secrets` and never printed), reads topic offsets
over `kafka:9092`, and is deleted when the script ends, also on Ctrl-C. It
reads offsets only, never message contents.

It never runs Kafka tools inside the broker container. The broker's memory
limit leaves almost no headroom (the `kafka memory` line shows it), and a
second JVM in that container can get the broker OOM-killed.

If a probe pod is ever left behind:

```bash
kubectl get pods -A -l dnavio.ops/cluster-overview
kubectl delete pods -A -l dnavio.ops/cluster-overview
```
