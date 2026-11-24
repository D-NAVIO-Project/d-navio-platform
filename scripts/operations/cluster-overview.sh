#!/usr/bin/env bash
# D-NAVIO cluster overview: one read-only snapshot of the platform namespaces.
#
# Usage: scripts/operations/cluster-overview.sh [options]
#   --details              list what is unhealthy (deployments, pods, jobs, restarts)
#   --kafka                also check Kafka topics and telemetry flow (see below)
#   --window MINUTES       telemetry window for --kafka (default 15)
#   --watch SECONDS        redraw every SECONDS; Ctrl-C to stop
#   --kafka-interval SEC   with --watch and --kafka: seconds between Kafka checks (default 300)
#   -n, --namespace NS     check only NS (repeatable; default dnavio-dev and dnavio-pilot)
#   --context NAME         kubeconfig context (default: the current context)
#   -h, --help             show this help
#
# Changes nothing: no Deployment, Service, Secret or Helm release is touched.
#   Default  kubectl get, helm list / get values, and `cat` of the cgroup
#            memory files inside the kafka and keycloak containers.
#   --kafka  additionally starts ONE short-lived pod per namespace (label
#            dnavio.ops/cluster-overview) that reads topic offsets over
#            kafka:9092 as the platform operations identity (dnavio-api), and
#            deletes it afterwards. Kafka tools are never run inside the broker
#            container: the broker has no memory headroom for a second JVM.
#
# "Broker running" and "telemetry arriving" are reported separately: the broker
# can be up while no data is sent. With --kafka, the telemetry line counts the
# messages whose timestamp falls in the last --window minutes on
# dnavio.dml.telemetry.raw (received) and .normalized (processed by T4.2).
#
# Exit status: 0 everything OK, 1 at least one [WARN], 2 usage error or no
# cluster access.

set -uo pipefail

NAMESPACES=()
DETAILS=0
KAFKA=0
WINDOW=15
WATCH=0
KAFKA_INTERVAL=300
CONTEXT=""
RECENT_HOURS=24          # restarts / failed pods younger than this are a [WARN]
MEM_WARN_PCT=90          # container memory (anon) at or above this % of its limit is a [WARN]
TELEMETRY_TOPICS=(dnavio.dml.telemetry.raw dnavio.dml.telemetry.normalized)
PROBE_LABEL="dnavio.ops/cluster-overview"
RUN_ID="$(date +%s)-$$"

usage() { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; }
die_usage() { echo "error: $1" >&2; echo "Run with --help for usage." >&2; exit 2; }
need_number() { [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || die_usage "$1 needs a positive whole number"; }

while (($#)); do
  case "$1" in
    --details) DETAILS=1; shift ;;
    --kafka) KAFKA=1; shift ;;
    --window) need_number "$1" "${2:-}"; WINDOW="$2"; shift 2 ;;
    --watch) need_number "$1" "${2:-}"; WATCH="$2"; shift 2 ;;
    --kafka-interval) need_number "$1" "${2:-}"; KAFKA_INTERVAL="$2"; shift 2 ;;
    -n|--namespace)
      [[ "${2:-}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die_usage "$1 needs a namespace name"
      NAMESPACES+=("$2"); shift 2 ;;
    --context) [ -n "${2:-}" ] || die_usage "$1 needs a context name"; CONTEXT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unknown option '$1'" ;;
  esac
done
((${#NAMESPACES[@]})) || NAMESPACES=(dnavio-dev dnavio-pilot)

for cmd in kubectl python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "error: $cmd is required but not installed" >&2; exit 2; }
done
HAVE_HELM=0
command -v helm >/dev/null 2>&1 && HAVE_HELM=1

KUBECTL=(kubectl --request-timeout=15s)
HELM=(helm)
if [ -n "$CONTEXT" ]; then
  KUBECTL+=(--context "$CONTEXT")
  HELM+=(--kube-context "$CONTEXT")
fi
k() { "${KUBECTL[@]}" "$@"; }

if ! k get namespaces -o name >/dev/null 2>&1; then
  echo "error: no access to the Kubernetes API with context '$(kubectl config current-context 2>/dev/null || echo none)'." >&2
  echo "On the VM, see docs/operations/cluster-overview.md (Access)." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# All parsing happens here: kubectl/helm return JSON, Python summarises it.
# Exit codes: 0 all OK, 1 at least one [WARN].
read -r -d '' PY <<'PYEOF'
import json, re, sys
from datetime import datetime, timezone

NOW = datetime.now(timezone.utc)
WARNED = False

def out(label, value, level=""):
    global WARNED
    if level == "WARN":
        WARNED = True
    print(f"  {label:<20} {value}" + (f" [{level}]" if level else ""))

def sub(text):
    print(f"      {text}")

def ts(value):
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return None

def age(t):
    if t is None:
        return "?"
    s = int((NOW - t).total_seconds())
    if s < 3600:
        return f"{s // 60}m"
    if s < 86400:
        return f"{s // 3600}h"
    return f"{s // 86400}d"

UNITS = {"": 1, "k": 1e3, "K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12,
         "Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "Ti": 2**40}

def to_bytes(q):
    m = re.fullmatch(r"(\d+(?:\.\d+)?)(Ki|Mi|Gi|Ti|k|K|M|G|T)?", str(q or "").strip())
    return float(m.group(1)) * UNITS[m.group(2) or ""] if m else 0.0

def gib(n):
    return f"{n / 2**30:.1f}Gi"

def mib(n):
    return f"{n / 2**20:.0f}Mi"

def owner_name(pod):
    """Deployment-style name for a pod (strip the ReplicaSet/pod hashes)."""
    name = pod["metadata"]["name"]
    refs = pod["metadata"].get("ownerReferences") or []
    if refs and refs[0].get("kind") == "ReplicaSet":
        return name.rsplit("-", 2)[0]
    if refs and refs[0].get("kind") == "Job":
        return refs[0].get("name", name)
    return name

def container_statuses(pod, init=True):
    s = pod.get("status", {})
    return ((s.get("initContainerStatuses") or []) if init else []) + (s.get("containerStatuses") or [])

# --- cluster: nodes + every pod, for readiness, pressure and memory budget ---
def cluster(data):
    items = data.get("items", [])
    nodes = [x for x in items if x.get("kind") == "Node"]
    pods = [x for x in items if x.get("kind") == "Pod"
            and x.get("status", {}).get("phase") in ("Pending", "Running")]
    ready, pressure = 0, []
    for n in nodes:
        conds = {c.get("type"): c.get("status") for c in n.get("status", {}).get("conditions", [])}
        if conds.get("Ready") == "True":
            ready += 1
        pressure += [f"{n['metadata']['name']} {t}" for t in ("MemoryPressure", "DiskPressure", "PIDPressure")
                     if conds.get(t) == "True"]
    out("Nodes", f"{ready}/{len(nodes)} Ready", "WARN" if not nodes or ready != len(nodes) else "")
    out("Node pressure", ", ".join(pressure) or "none", "WARN" if pressure else "")
    alloc = sum(to_bytes(n.get("status", {}).get("allocatable", {}).get("memory")) for n in nodes)
    req = lim = 0.0
    for p in pods:
        for c in p.get("spec", {}).get("containers", []):
            r = c.get("resources") or {}
            req += to_bytes((r.get("requests") or {}).get("memory"))
            lim += to_bytes((r.get("limits") or {}).get("memory"))
    if alloc:
        level = "WARN" if req / alloc >= 0.9 else ("INFO" if lim > alloc else "")
        text = (f"requests {gib(req)} ({req / alloc:.0%}), limits {gib(lim)} ({lim / alloc:.0%})"
                f" of {gib(alloc)} allocatable")
        out("Memory budget", text, level)
        if lim > alloc:
            sub("limits exceed the node: under load the kubelet evicts pods (no metrics-server, so actual use is not shown)")

# --- one namespace: deployments, pods, restarts, failed pods, jobs, PVCs ---
def namespace(data, ns, details, recent_hours):
    recent = lambda t: t is not None and (NOW - t).total_seconds() < recent_hours * 3600
    items = [x for x in data.get("items", [])
             if "dnavio.ops/cluster-overview" not in (x.get("metadata", {}).get("labels") or {})]
    kind = lambda k: [x for x in items if x.get("kind") == k]
    hint = False

    deps = kind("Deployment")
    def dep_ready(d):
        want = d.get("spec", {}).get("replicas", 1)
        s = d.get("status", {})
        return (s.get("readyReplicas", 0) >= want and s.get("updatedReplicas", 0) >= want
                and s.get("observedGeneration", 0) >= d["metadata"].get("generation", 1))
    bad = [d for d in deps if not dep_ready(d)]
    out("Deployments", f"{len(deps) - len(bad)}/{len(deps)} Ready", "WARN" if bad else "")
    hint |= bool(bad)
    if details:
        for d in bad:
            s = d.get("status", {})
            sub(f"deployment/{d['metadata']['name']}: {s.get('readyReplicas', 0)}/"
                f"{d.get('spec', {}).get('replicas', 1)} ready, {s.get('updatedReplicas', 0)} updated")

    pods = kind("Pod")
    active = [p for p in pods if not p["metadata"].get("deletionTimestamp")
              and p.get("status", {}).get("phase") in ("Pending", "Running")]
    def pod_ready(p):
        cs = p.get("status", {}).get("containerStatuses") or []
        return p["status"].get("phase") == "Running" and bool(cs) and all(c.get("ready") for c in cs)
    def why(p):
        for c in container_statuses(p):
            state = c.get("state") or {}
            if "waiting" in state:
                w = state["waiting"]
                msg = (w.get("message") or "")[:120]
                return f"{c.get('name')}: {w.get('reason') or 'waiting'}" + (f" ({msg})" if msg else "")
            if "running" in state and not c.get("ready", True):
                return f"{c.get('name')}: running, not ready"
        for cond in p.get("status", {}).get("conditions") or []:
            if cond.get("status") == "False" and cond.get("reason"):
                return f"{cond.get('reason')}: {(cond.get('message') or '')[:120]}"
        return p.get("status", {}).get("phase", "?")
    not_ready = [p for p in active if not pod_ready(p)]
    out("Pods", f"{len(active) - len(not_ready)}/{len(active)} Ready", "WARN" if not_ready else "")
    hint |= bool(not_ready)
    if details:
        for p in not_ready:
            sub(f"pod/{p['metadata']['name']}: {why(p)}")

    restarts = []
    for p in active:
        for c in container_statuses(p, init=False):
            if c.get("restartCount", 0):
                t = (c.get("lastState") or {}).get("terminated") or {}
                restarts.append((owner_name(p), c.get("name"), c["restartCount"],
                                 t.get("reason") or "unknown", ts(t.get("finishedAt"))))
    fresh = [r for r in restarts if recent(r[4])]
    text = f"{sum(r[2] for r in restarts)} total, {len(fresh)} in last {recent_hours}h"
    oom = [r for r in restarts if r[3] == "OOMKilled"]
    if oom:
        text += "; OOMKilled: " + ", ".join(f"{r[0]} ({age(r[4])} ago)" for r in oom)
    out("Restarts", text, "WARN" if fresh else "")
    hint |= bool(fresh)
    if details:
        for r in restarts:
            sub(f"{r[0]}/{r[1]}: {r[2]}x, last {r[3]} {age(r[4])} ago")

    failed = [p for p in pods if p.get("status", {}).get("phase") in ("Failed", "Unknown")]
    def ended(p):
        times = [ts(c.get("lastTransitionTime")) for c in p.get("status", {}).get("conditions") or []]
        times = [t for t in times if t]
        return max(times) if times else ts(p["metadata"].get("creationTimestamp"))
    if failed:
        groups = {}
        for p in failed:
            groups.setdefault(p["status"].get("reason") or p["status"].get("phase"), []).append(p)
        newest = max((t for t in map(ended, failed) if t), default=None)
        fresh_failed = recent(newest)
        out("Failed pods", ", ".join(f"{len(v)} {k}" for k, v in sorted(groups.items()))
            + f" (newest {age(newest)} ago)", "WARN" if fresh_failed else "INFO")
        hint |= fresh_failed
        if details:
            for reason, group in sorted(groups.items()):
                names = ", ".join(sorted({owner_name(p) for p in group}))
                sub(f"{reason}: {len(group)} pod(s) of {names}")
            sub(f"leftovers can be removed with: kubectl delete pod -n {ns} --field-selector=status.phase=Failed")
    else:
        out("Failed pods", "0")

    jobs = kind("Job")
    def job_failed(j):
        return [c for c in j.get("status", {}).get("conditions") or []
                if c.get("type") == "Failed" and c.get("status") == "True"]
    failed_jobs = [j for j in jobs if job_failed(j)]
    running = [j for j in jobs if j.get("status", {}).get("active")]
    out("Jobs", f"{len(jobs)} total, {len(failed_jobs)} failed" + (f", {len(running)} running" if running else ""),
        "WARN" if failed_jobs else "")
    hint |= bool(failed_jobs)
    if details:
        for j in failed_jobs:
            c = job_failed(j)[0]
            sub(f"job/{j['metadata']['name']}: {c.get('reason')} {(c.get('message') or '')[:120]}")

    pvcs = kind("PersistentVolumeClaim")
    unbound = [x for x in pvcs if x.get("status", {}).get("phase") != "Bound"]
    out("PVCs", f"{len(pvcs) - len(unbound)}/{len(pvcs)} Bound", "WARN" if unbound else "")
    hint |= bool(unbound)
    if details:
        for x in unbound:
            sub(f"pvc/{x['metadata']['name']}: {x.get('status', {}).get('phase', '?')}")

    broker = [d for d in deps if d["metadata"]["name"] == "kafka"]
    if broker:
        probe = any(c.get("readinessProbe") for c in broker[0]["spec"]["template"]["spec"].get("containers", []))
        state = "running" if dep_ready(broker[0]) else "NOT running"
        note = "" if probe else " (container state only: the Deployment has no readiness probe)"
        out("Kafka broker", state + note, "" if dep_ready(broker[0]) else "WARN")
    else:
        out("Kafka broker", "no kafka Deployment in this namespace", "WARN")

    if hint and not details:
        sub("run with --details for the list")

# --- Helm releases of one namespace ---
def helm(data):
    if not data:
        out("Helm releases", "none", "WARN")
        return
    bad = [r for r in data if r.get("status") != "deployed"]
    out("Helm releases", ", ".join(f"{r.get('name')} {r.get('status')} (rev {r.get('revision')})" for r in data),
        "WARN" if bad else "")

# --- realm, client id and topic list from the platform release's values ---
def platform_values(data):
    kc = data.get("keycloak", {})
    topics = [t.get("name") for t in data.get("kafka", {}).get("topics", []) if t.get("name")]
    print(kc.get("realm") or "d-navio")
    print((kc.get("clients", {}).get("dnavioApi", {}) or {}).get("clientId") or "dnavio-api")
    print(",".join(topics))

# --- cgroup v2 memory of one container ---
def memory(text, label, warn_pct):
    vals = dict(line.split()[:2] for line in text.splitlines() if len(line.split()) >= 2)
    if "anon" not in vals or "max_bytes" not in vals:
        out(label, "unknown (container not reachable, or not cgroup v2)", "INFO")
        return
    anon, limit, kills = int(vals["anon"]), vals["max_bytes"], int(vals.get("oom_kill", 0))
    if limit == "max":
        out(label, f"{mib(anon)} (no limit)")
        return
    pct = anon * 100 / int(limit)
    text = f"{mib(anon)} / {mib(int(limit))} ({pct:.0f}%)"
    if kills:
        text += f", {kills} OOM kill(s) since the container started"
    out(label, text, "WARN" if pct >= warn_pct or kills else "")
    if pct >= warn_pct:
        sub(f"{mib(int(limit) - anon)} left: any extra process in this container (e.g. a Kafka CLI) risks an OOM kill")

# --- Kafka probe pod output: topic offsets now and at the start of the window ---
def kafka(text, ok, expected, window, telemetry):
    section, end, since, errors = None, {}, {}, []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("@@ "):
            section = line[3:]
            continue
        m = re.fullmatch(r"(\S+):(\d+):(-?\d*)", line)
        if m and section in ("end", "since"):
            target = end if section == "end" else since
            target.setdefault(m.group(1), {})[int(m.group(2))] = int(m.group(3)) if m.group(3) else -1
        elif section == "error" and line:
            errors.append(line)
    label = "Telemetry"
    if ok != "1" or not end:
        reason = " | ".join(errors[-3:])[:300] or "the probe pod did not complete"
        out("Kafka client check", f"FAILED: {reason}", "WARN")
        out("Kafka topics", "unknown")
        out(label, "unknown")
        return
    out("Kafka client check", "OK: offsets read over kafka:9092 with a Keycloak token (dnavio-api)")
    want = [t for t in expected.split(",") if t]
    missing = [t for t in want if t not in end]
    other = sorted(set(end) - set(want))
    if want:
        out("Kafka topics", f"{len(want) - len(missing)}/{len(want)} expected topics exist"
            + (f" (+{len(other)} other)" if other else ""), "WARN" if missing else "")
        for t in missing:
            sub(f"missing: {t}")
    else:
        out("Kafka topics", f"{len(end)} topics (expected list unavailable: helm values not readable)")
    counts = {}
    for t in telemetry:
        if t not in end:
            counts[t] = None
            continue
        counts[t] = sum(max(eo - since.get(t, {}).get(p, -1), 0) if since.get(t, {}).get(p, -1) >= 0 else 0
                        for p, eo in end[t].items())
    raw, norm = (counts.get(t) for t in telemetry[:2])
    shown = f"last {window} min: " + " · ".join(f"{t.rsplit('.', 1)[-1]} +{counts[t]:,}" if counts[t] is not None else f"{t} missing"
                       for t in telemetry)
    if raw is None or norm is None:
        out(label, f"{shown}: telemetry topic missing", "WARN")
    elif raw and norm:
        out(label, f"{shown}: flowing")
    elif raw:
        out(label, f"{shown}: received but not normalised, check T4.2 stream-processor", "WARN")
    elif norm:
        out(label, f"{shown}: normalised output only (T4.2 still working through a backlog?)", "INFO")
    else:
        out(label, f"{shown}: NO DATA, the broker is up but nothing arrived in this window", "INFO")

mode, args = sys.argv[1], sys.argv[2:]
try:
    if mode == "kafka":
        kafka(sys.stdin.read(), args[0], args[1], args[2], args[3:])
    elif mode == "memory":
        memory(sys.stdin.read(), args[0], float(args[1]))
    else:
        data = json.load(sys.stdin)
        if mode == "cluster":
            cluster(data)
        elif mode == "namespace":
            namespace(data, args[0], args[1] == "1", int(args[2]))
        elif mode == "helm":
            helm(data)
        elif mode == "platform-values":
            platform_values(data)
except (ValueError, KeyError, TypeError, IndexError) as exc:
    print(f"  {'(parse error)':<20} {mode}: {exc} [WARN]")
    sys.exit(1)
sys.exit(1 if WARNED else 0)
PYEOF

STATUS=0
py() { python3 -c "$PY" "$@"; }
# Run one Python summary; record a warning in STATUS. Usage: summarise MODE [args] < json
summarise() { py "$@" || STATUS=1; }
line() {
  printf '  %-20s %s%s\n' "$1" "$2" "${3:+ [$3]}"
  [ "${3:-}" = WARN ] && STATUS=1
  return 0
}

# Platform settings per namespace (index-aligned with NAMESPACES; bash 3 has no maps).
REALMS=() CLIENTS=() TOPICS=()
load_platform_values() {
  local i=0 ns values
  for ns in "${NAMESPACES[@]}"; do
    REALMS[i]=d-navio
    CLIENTS[i]=dnavio-api
    TOPICS[i]=""
    if ((HAVE_HELM)) && values=$("${HELM[@]}" get values dnavio-platform -n "$ns" -a -o json 2>/dev/null); then
      { read -r "REALMS[$i]"; read -r "CLIENTS[$i]"; read -r "TOPICS[$i]"; } < <(py platform-values <<< "$values")
    fi
    i=$((i + 1))
  done
}

# --- cgroup memory of a platform container (only `cat`: no extra JVM) -------
container_memory() { # NAMESPACE COMPONENT CONTAINER
  local pod stats
  pod=$(k get pod -n "$1" -l "app.kubernetes.io/name=dnavio-platform,app.kubernetes.io/component=$2" \
    --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$pod" ]; then
    line "$2 memory" "no running pod"
    return
  fi
  stats=$(k exec -n "$1" "$pod" -c "$3" -- sh -c \
    'cat /sys/fs/cgroup/memory.stat; echo "max_bytes $(cat /sys/fs/cgroup/memory.max)"; grep "^oom_kill " /sys/fs/cgroup/memory.events' \
    2>/dev/null)
  summarise memory "$2 memory" "$MEM_WARN_PCT" <<< "$stats"
}

# --- Kafka probe (only with --kafka) ----------------------------------------
KAFKA_OUT=() KAFKA_RC=()
KAFKA_AT=0
PROBE_SEQ=0

cleanup_probes() {
  ((KAFKA)) || return 0
  local ns
  for ns in "${NAMESPACES[@]}"; do
    k delete pod -n "$ns" -l "${PROBE_LABEL}=${RUN_ID}" --ignore-not-found --wait=false >/dev/null 2>&1
  done
}
trap cleanup_probes EXIT
trap 'exit 130' INT TERM

# Start a probe pod; print its name, or nothing if it could not be created.
probe_start() { # NAMESPACE REALM CLIENT SINCE_MS
  local image pod telemetry
  image=$(k get deploy kafka -n "$1" \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="kafka")].image}' 2>/dev/null)
  [ -n "$image" ] || return 0
  PROBE_SEQ=$((PROBE_SEQ + 1))
  pod="cluster-overview-${RUN_ID}-${PROBE_SEQ}"
  telemetry=$(IFS=,; echo "${TELEMETRY_TOPICS[*]}")
  sed -e "s|__POD__|${pod}|g" -e "s|__RUN__|${RUN_ID}|g" -e "s|__IMAGE__|${image}|g" \
      -e "s|__REALM__|$2|g" -e "s|__CLIENT__|$3|g" -e "s|__SINCE__|$4|g" \
      -e "s|__TELEMETRY__|${telemetry}|g" -e "s|__LABEL__|${PROBE_LABEL}|g" <<'YAML' \
    | k apply -n "$1" -f - >/dev/null 2>&1 || return 0
apiVersion: v1
kind: Pod
metadata:
  name: __POD__
  labels:
    __LABEL__: "__RUN__"
spec:
  restartPolicy: Never
  enableServiceLinks: false
  automountServiceAccountToken: false
  activeDeadlineSeconds: 150
  terminationGracePeriodSeconds: 0
  containers:
    - name: probe
      image: __IMAGE__
      imagePullPolicy: IfNotPresent
      resources:
        requests: { memory: 256Mi, cpu: 50m }
        limits: { memory: 384Mi }
      securityContext:
        allowPrivilegeEscalation: false
      env:
        - name: KAFKA_HEAP_OPTS
          value: "-Xms64m -Xmx128m"
        - name: CLIENT_SECRET
          valueFrom: { secretKeyRef: { name: keycloak-client-secrets, key: dnavio-api-secret } }
      command:
        - /bin/bash
        - -c
        - |
          cat > /tmp/client.properties <<EOF
          security.protocol=SASL_PLAINTEXT
          sasl.mechanism=OAUTHBEARER
          sasl.login.callback.handler.class=org.apache.kafka.common.security.oauthbearer.secured.OAuthBearerLoginCallbackHandler
          sasl.oauthbearer.token.endpoint.url=http://keycloak:8080/realms/__REALM__/protocol/openid-connect/token
          sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required clientId="__CLIENT__" clientSecret="${CLIENT_SECRET}" ;
          EOF
          offsets() {
            kafka-get-offsets --bootstrap-server kafka:9092 \
              --command-config /tmp/client.properties "$@" 2>/tmp/err \
              || { echo "@@ error"; grep -E 'Exception|ERROR|Error' /tmp/err | tail -3; exit 1; }
          }
          echo "@@ end"
          offsets --time -1
          echo "@@ since"
          offsets --topic-partitions '__TELEMETRY__' --time __SINCE__
YAML
  echo "$pod"
}

# Wait for a probe pod, print its log, delete it. Succeeds if the pod did.
probe_collect() { # NAMESPACE POD
  local waited=0 phase=""
  while ((waited < 170)); do
    phase=$(k get pod "$2" -n "$1" -o jsonpath='{.status.phase}' 2>/dev/null)
    case "$phase" in Succeeded|Failed) break ;; esac
    sleep 3
    waited=$((waited + 3))
  done
  k logs "$2" -n "$1" 2>&1
  k delete pod "$2" -n "$1" --ignore-not-found --wait=false >/dev/null 2>&1
  [ "$phase" = Succeeded ]
}

run_kafka_checks() {
  local i ns pods=() logs ok since_ms
  since_ms=$((($(date +%s) - WINDOW * 60) * 1000))
  # Start every namespace's probe first, so they run in parallel.
  for i in "${!NAMESPACES[@]}"; do
    pods[i]=$(probe_start "${NAMESPACES[i]}" "${REALMS[i]}" "${CLIENTS[i]}" "$since_ms")
  done
  for i in "${!NAMESPACES[@]}"; do
    ns="${NAMESPACES[i]}"
    if [ -z "${pods[i]}" ]; then
      KAFKA_OUT[i]=$(printf '  %-20s %s [WARN]' "Kafka client check" \
        "probe pod not started (no kafka Deployment, or no permission to create pods)")
      KAFKA_RC[i]=1
      continue
    fi
    ok=0
    logs=$(probe_collect "$ns" "${pods[i]}") && ok=1
    KAFKA_OUT[i]=$(py kafka "$ok" "${TOPICS[i]}" "$WINDOW" "${TELEMETRY_TOPICS[@]}" <<< "$logs")
    KAFKA_RC[i]=$?
  done
  KAFKA_AT=$(date +%s)
}

kafka_due() {
  ((KAFKA)) || return 1
  ((WATCH == 0 || KAFKA_AT == 0)) && return 0
  (($(date +%s) - KAFKA_AT >= KAFKA_INTERVAL))
}

# --- the snapshot -------------------------------------------------------------
render() {
  local i ns data
  STATUS=0
  printf 'D-NAVIO CLUSTER OVERVIEW   %s   context %s\n' \
    "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "${CONTEXT:-$(kubectl config current-context 2>/dev/null)}"

  printf '\nCluster\n'
  if data=$(k get nodes,pods -A -o json 2>/dev/null); then
    summarise cluster <<< "$data"
  else
    line "Nodes" "unknown (API request failed)" WARN
  fi

  for i in "${!NAMESPACES[@]}"; do
    ns="${NAMESPACES[i]}"
    printf '\n%s\n' "$ns"
    if ! data=$(k get deployments,pods,jobs,pvc -n "$ns" -o json 2>/dev/null) \
        || ! k get namespace "$ns" >/dev/null 2>&1; then
      line "Status" "unknown (namespace missing, forbidden, or API unreachable)" WARN
      continue
    fi
    summarise namespace "$ns" "$DETAILS" "$RECENT_HOURS" <<< "$data"

    if ((HAVE_HELM)) && data=$("${HELM[@]}" list -n "$ns" -a -o json 2>/dev/null); then
      summarise helm <<< "$data"
    else
      line "Helm releases" "not checked (helm missing or not permitted)" INFO
    fi

    container_memory "$ns" kafka kafka
    container_memory "$ns" keycloak keycloak

    if ((KAFKA)); then
      printf '%s\n' "${KAFKA_OUT[i]:-}"
      [ "${KAFKA_RC[i]:-0}" = 0 ] || STATUS=1
      if ((WATCH)); then
        printf '      (Kafka checked %ss ago, every %ss)\n' "$(($(date +%s) - KAFKA_AT))" "$KAFKA_INTERVAL"
      fi
    else
      line "Kafka topics" "not checked (add --kafka)"
      line "Telemetry" "not checked (add --kafka): a running broker does not mean data is arriving"
    fi
  done
  return "$STATUS"
}

snapshot() {
  load_platform_values
  kafka_due && run_kafka_checks
  render
}

if ((WATCH)); then
  while true; do
    load_platform_values
    kafka_due && run_kafka_checks
    output=$(render)
    printf '\033[H\033[2J%s\n\n(refreshing every %ss, Ctrl-C to stop)\n' "$output" "$WATCH"
    sleep "$WATCH"
  done
fi

snapshot
exit $?
