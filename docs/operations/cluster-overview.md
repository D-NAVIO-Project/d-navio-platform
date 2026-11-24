# Cluster Overview

`scripts/operations/cluster-overview.sh` shows the state of the platform
namespaces (`dnavio-dev`, `dnavio-pilot`) at a glance: node, Kubernetes
workloads, Kafka connectivity, topics, telemetry flow and platform memory, with
one OVERALL verdict.

```text
D-NAVIO CLUSTER OVERVIEW
2026-11-24 17:31:06 UTC · context kubernetes-admin@kubernetes
────────────────────────────────────────────────────────────────

CLUSTER
  Node readiness       OK        1/1 Ready
  Deployments          OK        14/14 Ready (checked namespaces)
  Memory budget        OK        29% requested, 48% in limits, of 7.7Gi

DEV ENVIRONMENT (dnavio-dev)
  Kubernetes           OK        12 deployments, 12 pods, 4 PVCs ready; 3/3 releases deployed
  Kafka connectivity   OK        Keycloak token accepted, offsets read on kafka:9092
  Kafka topics         OK        8/8 present
  Telemetry (15 min)   NO DATA   nothing arrived; the platform can still be healthy
  Kafka memory         WARN      94% of 640Mi, 37Mi left
  Keycloak memory      OK        72% of 768Mi
...
────────────────────────────────────────────────────────────────
OVERALL: WARNING
  WARN     dev  Kafka memory at 94% of its 640Mi limit (37Mi left): any extra process in the container risks an OOM kill
```

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

That kubeconfig is cluster-admin: the script changes nothing, but other
commands run this way can change anything.

## Usage

| Command | Does |
|---------|------|
| `./scripts/operations/cluster-overview.sh` | Full overview, including Kafka (~15 s) |
| `... --fast` | Kubernetes only, no Kafka probe (~2 s) |
| `... --details` | Full overview plus every unhealthy item, restarts, Helm releases, topic totals and notes |
| `... --window 20160` | Telemetry over the last 14 days instead of 15 minutes |
| `... --watch 30` | Redraw every 30 s (Ctrl-C to stop); Kafka is probed at most every 60 s (`--kafka-interval`) |
| `... --strict` | Exit 1 on warnings too, for cron / automation |
| `... -n dnavio-dev` | One namespace only (repeatable) |

`--kafka` is still accepted and does nothing: the Kafka check is the default.
Colour is used on a terminal; set `NO_COLOR=1` to turn it off.

## Reading the output

| Status | Meaning | OVERALL |
|--------|---------|---------|
| `OK`, `FLOWING` | Fine | |
| `NO DATA`, `BACKLOG`, `SKIPPED` | Worth knowing, not a fault | |
| `WARN`, `STALLED` | Works, but needs attention | WARNING |
| `UNKNOWN` | The check could not run (reason shown); nothing is confirmed | WARNING |
| `FAIL` | Something does not work | FAILED |

Below OVERALL every WARN / UNKNOWN / FAIL is listed with its environment.
`--details` also prints the notes (e.g. earlier OOM kills, old evicted pods
and the command to remove them).

| Exit status | When |
|-------------|------|
| `0` | OVERALL OK or WARNING |
| `1` | OVERALL FAILED; with `--strict`, also WARNING |
| `2` | Usage error, or no access to the cluster |

| Line | FAIL when | WARN when |
|------|-----------|-----------|
| Node readiness | a node is not Ready | memory / disk / PID pressure (shown as *Node pressure*) |
| Deployments | any not ready | |
| Memory budget | | pod memory requests ≥ 90% of the node |
| Kubernetes (per namespace) | deployment or pod not ready, failed job, PVC not Bound, Helm release missing or not `deployed`, no Kafka Deployment | container restart or failed pod in the last 24 h |
| Kafka connectivity | | `UNKNOWN` if the probe could not start or authenticate |
| Kafka topics | a topic declared in the platform values is missing | |
| Telemetry | a telemetry topic is missing | `STALLED`: received but not normalised |
| Kafka / Keycloak memory | | ≥ 90% of the limit, or an OOM kill; `UNKNOWN` if not readable |

### Kafka connectivity is not telemetry

They are separate lines on purpose: the broker can be healthy while no data is
sent.

- **Kafka connectivity: OK** means a client got a token from Keycloak and the
  broker served it on `kafka:9092`. With `--fast` it is `SKIPPED`: the
  Kubernetes line then only says the broker container runs (the Kafka
  Deployment has no readiness probe).
- **Telemetry** counts the messages on `dnavio.dml.telemetry.raw` (received
  by T4.2's ingest) and `dnavio.dml.telemetry.normalized` (processed by T4.2's
  stream-processor) whose timestamp falls in the window:

| raw | normalized | Status |
|-----|------------|--------|
| > 0 | > 0 | `FLOWING` |
| > 0 | 0 | `STALLED`: data arrives, T4.2's stream-processor does not process it |
| 0 | > 0 | `BACKLOG`: T4.2 is still working through earlier data |
| 0 | 0 | `NO DATA`: nothing is being sent (e.g. no DANAOS feed, no replay running) |

## What the script touches

Nothing that runs the platform: no Deployment, Service, Secret or Helm release
is changed. It reads with `kubectl get`, `helm list` / `helm get values`, and
reads the cgroup memory files inside the kafka and keycloak containers with
`cat`.

Unless `--fast`, it starts one short-lived pod per namespace, labelled
`dnavio.ops/cluster-overview`, from the broker's image. The pod authenticates as
the platform operations identity `dnavio-api` (the secret is mounted from
`keycloak-client-secrets` and never printed), reads topic offsets over
`kafka:9092`, never message contents, and is deleted at the end, also on
Ctrl-C. Running it needs permission to create pods in the namespace; without
it, the Kafka lines show `UNKNOWN`.

It never runs Kafka tools inside the broker container. The broker's memory
limit leaves almost no headroom (the *Kafka memory* line shows it), and a
second JVM in that container can get the broker OOM-killed.

If a probe pod is ever left behind:

```bash
kubectl get pods -A -l dnavio.ops/cluster-overview
kubectl delete pods -A -l dnavio.ops/cluster-overview
```

## Files

- `scripts/operations/cluster-overview.sh` collects the data (kubectl, helm,
  the Kafka probe) and handles the options and `--watch`.
- `scripts/operations/cluster_overview.py` turns the data into the report and
  decides OVERALL and the exit status.
