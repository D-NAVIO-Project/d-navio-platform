#!/usr/bin/env bash
# D-NAVIO cluster overview: the state of the platform namespaces at a glance.
#
# Usage: scripts/operations/cluster-overview.sh [options]
#   (no options)           full overview, including Kafka topics and telemetry (~15 s)
#   --fast                 Kubernetes only, no Kafka probe (~2 s)
#   --details              also list every unhealthy item, restarts, releases and notes
#   --window MINUTES       telemetry window (default 15; e.g. 20160 = 14 days)
#   --watch SECONDS        redraw every SECONDS; Ctrl-C to stop
#   --kafka-interval SEC   with --watch: seconds between Kafka probes (default 60)
#   --strict               exit 1 on warnings too (for cron / automation)
#   -n, --namespace NS     check only NS (repeatable; default dnavio-dev and dnavio-pilot)
#   --context NAME         kubeconfig context (default: the current context)
#   --kafka                accepted for compatibility; the Kafka check is now the default
#   -h, --help             show this help
#
# What it touches: nothing that runs the platform. No Deployment, Service,
# Secret or Helm release is changed. It reads with kubectl/helm and `cat`s the
# cgroup memory files of the kafka and keycloak containers. Unless --fast, it
# also starts ONE short-lived pod per namespace (label
# dnavio.ops/cluster-overview) that reads topic offsets over kafka:9092 with a
# Keycloak token (dnavio-api) and is deleted afterwards. Kafka tools never run
# inside the broker container: the broker has no memory headroom for them.
#
# "Kafka connectivity" (the broker served an authenticated client) and
# "Telemetry" (messages arrived on dnavio.dml.telemetry.raw / .normalized in the
# window) are separate lines: a healthy broker does not mean data is arriving.
#
# OVERALL is OK, WARNING (warnings, or checks that could not run: UNKNOWN) or
# FAILED. Exit status: 0 OK or WARNING, 1 FAILED (or WARNING with --strict),
# 2 usage error or no access to the cluster.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$HERE/cluster_overview.py"

NAMESPACES=()
FAST=0
DETAILS=0
STRICT=0
WINDOW=15
WATCH=0
KAFKA_INTERVAL=60
CONTEXT=""
RECENT_HOURS=24          # restarts / failed pods younger than this are a warning
MEM_WARN_PCT=90          # container memory at or above this % of its limit is a warning
TELEMETRY_TOPICS=(dnavio.dml.telemetry.raw dnavio.dml.telemetry.normalized)
PROBE_LABEL="dnavio.ops/cluster-overview"
RUN_ID="$(date +%s)-$$"

usage() { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; }
die_usage() { echo "error: $1" >&2; echo "Run with --help for usage." >&2; exit 2; }
need_number() { [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || die_usage "$1 needs a positive whole number"; }

while (($#)); do
  case "$1" in
    --fast) FAST=1; shift ;;
    --kafka) shift ;;
    --details) DETAILS=1; shift ;;
    --strict) STRICT=1; shift ;;
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
[ -f "$REPORT" ] || { echo "error: $REPORT is missing" >&2; exit 2; }
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
  echo "error: no access to the Kubernetes API with context '${CONTEXT:-$(kubectl config current-context 2>/dev/null || echo none)}'." >&2
  echo "On the VM, see docs/operations/cluster-overview.md (Access)." >&2
  exit 2
fi
CONTEXT_NAME="${CONTEXT:-$(kubectl config current-context 2>/dev/null)}"

DATA="$(mktemp -d)"
cleanup() {
  local ns
  if ((!FAST)); then
    for ns in "${NAMESPACES[@]}"; do
      k delete pod -n "$ns" -l "${PROBE_LABEL}=${RUN_ID}" --ignore-not-found --wait=false >/dev/null 2>&1
    done
  fi
  rm -rf "$DATA"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- collection: kubectl / helm / cgroup files -> $DATA ---------------------------

# Write a command's stdout to FILE only if the command succeeds.
save() { # FILE COMMAND...
  local file="$1" tmp="$1.tmp"
  shift
  if "$@" > "$tmp" 2>/dev/null; then mv "$tmp" "$file"; else rm -f "$tmp" "$file"; fi
}

container_memory() { # NAMESPACE COMPONENT CONTAINER
  local pod
  pod=$(k get pod -n "$1" -l "app.kubernetes.io/name=dnavio-platform,app.kubernetes.io/component=$2" \
    --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -n "$pod" ] || return 1
  k exec -n "$1" "$pod" -c "$3" -- sh -c \
    'cat /sys/fs/cgroup/memory.stat; echo "max_bytes $(cat /sys/fs/cgroup/memory.max)"; grep "^oom_kill " /sys/fs/cgroup/memory.events'
}

collect_kubernetes() {
  local ns d
  save "$DATA/cluster.json" k get nodes,pods -A -o json
  for ns in "${NAMESPACES[@]}"; do
    d="$DATA/$ns"
    mkdir -p "$d"
    if k get namespace "$ns" >/dev/null 2>&1; then
      save "$d/resources.json" k get deployments,pods,jobs,pvc -n "$ns" -o json
    else
      rm -f "$d/resources.json"
    fi
    if ((HAVE_HELM)); then
      save "$d/helm.json" "${HELM[@]}" list -n "$ns" -a -o json
      save "$d/values.json" "${HELM[@]}" get values dnavio-platform -n "$ns" -a -o json
    fi
    save "$d/kafka-memory.txt" container_memory "$ns" kafka kafka
    save "$d/keycloak-memory.txt" container_memory "$ns" keycloak keycloak
  done
}

# --- Kafka probe: one short-lived pod per namespace ---------------------------

PROBE_SEQ=0
KAFKA_AT=0

# Realm or client id from the platform values, with the platform defaults.
platform_setting() { # VALUES_FILE realm|client
  python3 - "$1" "$2" 2>/dev/null <<'PY' || { [ "$2" = realm ] && echo d-navio || echo dnavio-api; }
import json, sys
kc = json.load(open(sys.argv[1])).get("keycloak", {})
if sys.argv[2] == "realm":
    print(kc.get("realm") or "d-navio")
else:
    print((kc.get("clients", {}).get("dnavioApi", {}) or {}).get("clientId") or "dnavio-api")
PY
}

# Start probe pod POD. If it cannot start, record why in probe.state and fail.
probe_start() { # NAMESPACE SINCE_MS POD
  local ns="$1" pod="$3" d="$DATA/$1" image realm client telemetry err
  image=$(k get deploy kafka -n "$ns" \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="kafka")].image}' 2>/dev/null)
  if [ -z "$image" ]; then
    printf 'not-started\tno kafka Deployment to take the image from' > "$d/probe.state"
    return 1
  fi
  realm=$(platform_setting "$d/values.json" realm)
  client=$(platform_setting "$d/values.json" client)
  telemetry=$(IFS=,; echo "${TELEMETRY_TOPICS[*]}")
  sed -e "s|__POD__|${pod}|g" -e "s|__RUN__|${RUN_ID}|g" -e "s|__IMAGE__|${image}|g" \
      -e "s|__REALM__|${realm}|g" -e "s|__CLIENT__|${client}|g" -e "s|__SINCE__|$2|g" \
      -e "s|__TELEMETRY__|${telemetry}|g" -e "s|__LABEL__|${PROBE_LABEL}|g" \
      > "$d/probe.yaml" <<'YAML'
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
  activeDeadlineSeconds: 90
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
          request.timeout.ms=15000
          default.api.timeout.ms=30000
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
  if ! err=$(k apply -n "$ns" -f "$d/probe.yaml" 2>&1 >/dev/null); then
    printf 'not-started\tprobe pod not created (%s)' "$(head -c 160 <<< "$err" | tr '\n' ' ')" > "$d/probe.state"
    return 1
  fi
}

# Wait for a probe pod, keep its log and outcome, then delete it.
probe_collect() { # NAMESPACE POD
  local ns="$1" pod="$2" d="$DATA/$1" waited=0 phase="" waiting
  while ((waited < 100)); do
    phase=$(k get pod "$pod" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)
    case "$phase" in Succeeded|Failed) break ;; esac
    sleep 2
    waited=$((waited + 2))
  done
  k logs "$pod" -n "$ns" > "$d/probe.log" 2>/dev/null || : > "$d/probe.log"
  case "$phase" in
    Succeeded) printf 'ok' > "$d/probe.state" ;;
    Failed) printf 'failed\tprobe could not read Kafka' > "$d/probe.state" ;;
    *)
      waiting=$(k get pod "$pod" -n "$ns" \
        -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)
      printf 'failed\tprobe did not finish in %ss (phase %s%s)' "$waited" "${phase:-unknown}" \
        "${waiting:+, $waiting}" > "$d/probe.state" ;;
  esac
  k delete pod "$pod" -n "$ns" --ignore-not-found --wait=false >/dev/null 2>&1
}

run_kafka_probes() {
  local i pod since_ms pods=()
  since_ms=$((($(date +%s) - WINDOW * 60) * 1000))
  for i in "${!NAMESPACES[@]}"; do   # start them all first, so they run in parallel
    rm -f "$DATA/${NAMESPACES[i]}/probe."*
    pods[i]=""
    PROBE_SEQ=$((PROBE_SEQ + 1))
    pod="cluster-overview-${RUN_ID}-${PROBE_SEQ}"
    if [ -f "$DATA/${NAMESPACES[i]}/resources.json" ] \
        && probe_start "${NAMESPACES[i]}" "$since_ms" "$pod"; then
      pods[i]="$pod"
    fi
  done
  for i in "${!NAMESPACES[@]}"; do
    [ -n "${pods[i]}" ] && probe_collect "${NAMESPACES[i]}" "${pods[i]}"
  done
  KAFKA_AT=$(date +%s)
  for i in "${!NAMESPACES[@]}"; do
    echo "$KAFKA_AT" > "$DATA/${NAMESPACES[i]}/probe.at"
  done
}

# In --watch, Kafka probes run at most every --kafka-interval; in between the
# last result is shown again (with its age).
kafka_due() {
  ((FAST)) && return 1
  ((WATCH == 0 || KAFKA_AT == 0)) && return 0
  (($(date +%s) - KAFKA_AT >= KAFKA_INTERVAL))
}

# --- report -----------------------------------------------------------------------

report() { # [--colour]
  local flags=()
  ((FAST)) && flags+=(--fast)
  ((DETAILS)) && flags+=(--details)
  ((STRICT)) && flags+=(--strict)
  python3 "$REPORT" --data "$DATA" --context "$CONTEXT_NAME" \
    --namespaces "${NAMESPACES[@]}" --telemetry "${TELEMETRY_TOPICS[@]}" \
    --window "$WINDOW" --recent-hours "$RECENT_HOURS" --mem-warn "$MEM_WARN_PCT" \
    --watch "$WATCH" ${flags[@]+"${flags[@]}"} "$@"
}

COLOUR=()
[ -t 1 ] && [ -z "${NO_COLOR:-}" ] && COLOUR=(--colour)

if ((WATCH)); then
  while true; do
    collect_kubernetes
    kafka_due && run_kafka_probes
    output=$(report ${COLOUR[@]+"${COLOUR[@]}"})
    printf '\033[H\033[2J%s\n\n(refreshing every %ss; Kafka every %ss; Ctrl-C to stop)\n' \
      "$output" "$WATCH" "$KAFKA_INTERVAL"
    sleep "$WATCH"
  done
fi

collect_kubernetes
kafka_due && run_kafka_probes
report ${COLOUR[@]+"${COLOUR[@]}"}
exit $?
