#!/usr/bin/env bash
# WP4 platform demo (a few minutes, step by step), run on the platform VM with
# kubectl access to the namespace. It shows:
#   1. the platform and T4.2 running in the namespace
#   2. a component proving who it is: a short-lived token from Keycloak
#      (claims only; the token and the secret are never printed)
#   3. another component reading T4.2's live topic with its own token
#   4. that component writing to a topic it may use, and reading it back
#   5. what is refused: a wrong secret, and a write the access rules forbid
#
# T4.2's data is only read. The demo writes only to a temporary topic, and
# removes it, its consumer groups and its client pod at the end.
#
# Usage: scripts/demo/wp4-platform-demo.sh [namespace]      (default dnavio-dev)
#   DEMO_CLIENT=svc-...   identity of the demo component (default svc-test-producer)
#   KC_URL=...            Keycloak as seen from the VM (default http://127.0.0.1:30080)
#   NO_PAUSE=1            run straight through, e.g. to record a fallback video

set -uo pipefail

NS="${1:-dnavio-dev}"
REALM="${REALM:-d-navio}"
CLIENT="${DEMO_CLIENT:-svc-test-producer}"
KC_URL="${KC_URL:-http://127.0.0.1:30080}"
LIVE_TOPIC="${LIVE_TOPIC:-dnavio.dml.telemetry.normalized}"
FALLBACK_TOPIC="${FALLBACK_TOPIC:-dnavio.frs.failures.reported}"
DENIED_TOPIC="dnavio.ops.admin-audit"
RUN_ID="$(date +%s)"
POD="wp4-demo-${RUN_ID}"
TOPIC="dnavio.demo.${RUN_ID}"
GROUP="wp4-demo-${RUN_ID}"
CREDS="dnavio-component-credentials"
KAFKA_IMAGE="$(kubectl get deploy kafka -n "$NS" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
KAFKA_IMAGE="${KAFKA_IMAGE:-confluentinc/cp-kafka:7.8.3}"

bold=$'\e[1m'; dim=$'\e[2m'; green=$'\e[32m'; red=$'\e[31m'; reset=$'\e[0m'
step()  { printf '\n%s== %s ==%s\n' "$bold" "$1" "$reset"; }
show()  { printf '%s$ %s%s\n' "$dim" "$*" "$reset"; }
ok()    { printf '%s  [ok] %s%s\n' "$green" "$1" "$reset"; }
no()    { printf '%s  [!!] %s%s\n' "$red" "$1" "$reset"; }
info()  { printf '    %s\n' "$1"; }
pause() { [ "${NO_PAUSE:-0}" = 1 ] || read -r -p "  [Enter] " _; }

# Commands run in the demo client pod; they never contain a secret.
client() { kubectl exec -n "$NS" "$POD" -c client -- bash -c "$1" 2>&1; }
# Admin tasks (the temporary topic, offsets, consumer groups) also run in the
# demo client pod, with its token. Never run Kafka's tools inside the broker
# container: each starts a second JVM within the broker's memory limit, which
# can get the broker itself killed and restarted.
admin() {
  kubectl exec -n "$NS" "$POD" -c client -- "$@" \
    --bootstrap-server kafka:9092 --command-config /tmp/good.properties 2>/dev/null
}
# Messages a topic holds now (latest minus earliest offset), or "?" if unknown.
topic_size() {
  local hi lo
  hi="$(admin kafka-get-offsets --topic "$1" --time -1)"
  lo="$(admin kafka-get-offsets --topic "$1" --time -2)"
  if [ -z "$hi" ] || [ -z "$lo" ]; then echo "?"; return; fi
  echo $(( $(awk -F: '{s+=$NF} END {print s+0}' <<< "$hi") - $(awk -F: '{s+=$NF} END {print s+0}' <<< "$lo") ))
}
secret_key() {
  kubectl get secret "$CREDS" -n "$NS" -o go-template="{{index .data \"$1\"}}" 2>/dev/null \
    | base64 -d 2>/dev/null
}

cleanup() {
  admin kafka-topics --delete --topic "$TOPIC" >/dev/null
  for g in "$GROUP" "${GROUP}-own"; do
    admin kafka-consumer-groups --delete --group "$g" >/dev/null
  done
  kubectl delete pod "$POD" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1
}
trap cleanup EXIT

# --- Preflight ----------------------------------------------------------------
if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
  echo "namespace $NS not reachable with kubectl" >&2; exit 1
fi
if [ -z "$(secret_key "${CLIENT}-client-id")" ]; then
  echo "identity $CLIENT not found in $CREDS; set DEMO_CLIENT to one that exists" >&2; exit 1
fi

# Start the demo client now, so it is ready by step 3. It holds the identity's
# credentials (from the Secret, never printed) in two client configs: the right
# secret, and a deliberately wrong one for step 5.
render() {
  sed -e "s|__POD__|$POD|g" -e "s|__RUN__|$RUN_ID|g" -e "s|__IMAGE__|$KAFKA_IMAGE|g" \
      -e "s|__CLIENT__|$CLIENT|g" -e "s|__REALM__|$REALM|g" -e "s|__CREDS__|$CREDS|g"
}
render <<'YAML' | kubectl apply -n "$NS" -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: __POD__
  labels:
    dnavio.demo/run: "__RUN__"
spec:
  restartPolicy: Never
  enableServiceLinks: false
  activeDeadlineSeconds: 1800
  containers:
    - name: client
      image: __IMAGE__
      imagePullPolicy: IfNotPresent
      resources:
        requests: { memory: 256Mi }
        limits: { memory: 512Mi }
      env:
        - name: CLIENT_ID
          valueFrom: { secretKeyRef: { name: __CREDS__, key: __CLIENT__-client-id } }
        - name: CLIENT_SECRET
          valueFrom: { secretKeyRef: { name: __CREDS__, key: __CLIENT__-client-secret } }
      command:
        - /bin/bash
        - -c
        - |
          write() {
            cat > "$1" <<EOF
          security.protocol=SASL_PLAINTEXT
          sasl.mechanism=OAUTHBEARER
          sasl.login.callback.handler.class=org.apache.kafka.common.security.oauthbearer.secured.OAuthBearerLoginCallbackHandler
          sasl.oauthbearer.token.endpoint.url=http://keycloak:8080/realms/__REALM__/protocol/openid-connect/token
          sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required clientId="${CLIENT_ID}" clientSecret="$2" ;
          EOF
          }
          write /tmp/good.properties "${CLIENT_SECRET}"
          write /tmp/bad.properties "not-the-secret"
          exec sleep 1800
YAML

LIMITS="--producer-property max.block.ms=20000 --producer-property delivery.timeout.ms=30000 --producer-property request.timeout.ms=15000"

printf '%sD-NAVIO platform demo — namespace %s%s\n' "$bold" "$NS" "$reset"
info "demo component identity: $CLIENT"
pause

# --- 1 ------------------------------------------------------------------------
step "1 · The platform and T4.2, running on NTUA premises"
show "kubectl get pods -n $NS --field-selector=status.phase=Running"
kubectl get pods -n "$NS" --field-selector=status.phase=Running 2>&1 | grep -v "^${POD} " | sed 's/^/    /'
info "Kafka and Keycloak are the platform; the other pods are T4.2 (DML, FRS) with its own databases."
pause

# --- 2 ------------------------------------------------------------------------
step "2 · A component proves who it is: a token from Keycloak"
cid="$(secret_key "${CLIENT}-client-id")"
show "curl -X POST $KC_URL/realms/$REALM/protocol/openid-connect/token -d grant_type=client_credentials -d client_id=$cid -d client_secret=••••••"
resp="$(printf 'grant_type=client_credentials&client_id=%s&client_secret=%s' \
          "$cid" "$(secret_key "${CLIENT}-client-secret")" \
        | curl -s --max-time 15 -X POST --data @- \
            "$KC_URL/realms/$REALM/protocol/openid-connect/token")"
if TOKEN_JSON="$resp" python3 - <<'PY'
import base64, json, os, sys
try:
    r = json.loads(os.environ["TOKEN_JSON"])
    payload = r["access_token"].split(".")[1]
except (ValueError, KeyError):
    print("    no token: " + os.environ["TOKEN_JSON"][:200])
    sys.exit(1)
c = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
print("    issued by  " + str(c.get("iss")))
print("    client     " + str(c.get("azp")) + "   (Kafka sees it as User:" + str(c.get("azp")) + ")")
print("    valid for  " + str(c.get("exp", 0) - c.get("iat", 0)) + " seconds, then the client fetches a new one")
PY
then
  ok "token issued by the D-NAVIO realm (the token itself is never shown)"
else
  no "Keycloak issued no token (check KC_URL)"
fi
pause

# --- 3 ------------------------------------------------------------------------
step "3 · Another component reads T4.2's live data, with its token"
for _ in $(seq 1 40); do
  [ "$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ] && break
  sleep 2
done
# Telemetry is kept 7 days; if T4.2 has not replayed pilot data since, that
# topic is empty and the consumer would only time out. Then fall back to T4.2's
# failure reports (derived from the same telemetry, kept indefinitely).
held=0
for t in $LIVE_TOPIC $FALLBACK_TOPIC; do
  held="$(topic_size "$t")"
  if [ "$held" = 0 ]; then
    info "$t holds no messages (T4.2 has published nothing there recently)"
  else
    LIVE_TOPIC="$t"; break
  fi
done
out=""; msgs=""
if [ "$held" != 0 ]; then
  [ "$held" = "?" ] || info "$LIVE_TOPIC holds $held messages"
  show "kafka-console-consumer --bootstrap-server kafka:9092 --consumer.config <token config> --topic $LIVE_TOPIC --max-messages 3"
  out="$(client "kafka-console-consumer --bootstrap-server kafka:9092 --consumer.config /tmp/good.properties \
    --topic $LIVE_TOPIC --from-beginning --max-messages 3 --timeout-ms 20000 --group $GROUP")"
  msgs="$(grep -vE '^\[|^Processed a total|WARN|ERROR|Exception|^[[:space:]]+at ' <<< "$out" | head -3)"
fi
if [ "$held" = 0 ]; then
  no "nothing to read; ask T4.2 to replay pilot data before the demo"
elif [ -n "$msgs" ]; then
  # T4.2 envelopes carry their record in "payload" (contracts/*.v1): show the
  # record itself rather than the envelope ids.
  MSGS="$msgs" python3 - <<'PY'
import json, os
rows = []
for line in os.environ["MSGS"].splitlines():
    try:
        env = json.loads(line)
        p = env.get("payload") or {}
        if env.get("event_type") == "dnavio.failure.report":
            sev = (p.get("severity") or {}).get("label") or "csn %s" % (p.get("severity") or {}).get("csn", "?")
            what = "%s: %s" % (p.get("system", "?"), p.get("summary", "?"))
            rows.append(("failure", str(p.get("detected_at", "?"))[:19], p.get("vessel_id", "?"),
                         what[:52], "%s, %s" % (sev, p.get("status", "?"))))
        else:
            value = next(iter((p.get("value") or {}).values()), "?")
            reading = ("%s = %s %s" % (p.get("metric", "?"), value, p.get("unit", ""))).strip()
            rows.append(("reading", str(p.get("observed_at", "?"))[:19], p.get("vessel_id", "?"),
                         reading[:52], (p.get("quality") or {}).get("status", "good")))
    except (ValueError, AttributeError):
        rows.append(("raw", line[:110]))
kind = next((r[0] for r in rows if r[0] != "raw"), "reading")
head = ("detected (UTC)", "failure", "severity, status") if kind == "failure" else ("observed (UTC)", "reading", "quality")
print("    %-20s %-12s %-52s %s" % (head[0], "vessel", head[1], head[2]))
for r in rows:
    print("    " + r[1] if r[0] == "raw" else "    %-20s %-12s %-52s %s" % r[1:])
PY
  ok "read as User:$cid from T4.2's topic $LIVE_TOPIC"
elif grep -q TimeoutException <<< "$out"; then
  no "no message arrived from $LIVE_TOPIC within 20 seconds"
elif grep -q Exception <<< "$out"; then
  grep -m2 Exception <<< "$out" | cut -c1-150 | sed 's/^/    /'
  no "could not read $LIVE_TOPIC"
else
  no "no messages read from $LIVE_TOPIC"
fi
pause

# --- 4 ------------------------------------------------------------------------
step "4 · It writes to a topic it may use, and reads it back"
if ! admin kafka-topics --create --topic "$TOPIC" --partitions 1 --replication-factor 1 >/dev/null; then
  no "the broker could not create the temporary topic $TOPIC"
fi
marker="hello from $cid, run $RUN_ID"
show "echo '$marker' | kafka-console-producer --bootstrap-server kafka:9092 --producer.config <token config> --topic $TOPIC"
out="$(client "echo '$marker' | kafka-console-producer --bootstrap-server kafka:9092 \
  --producer.config /tmp/good.properties --topic $TOPIC $LIMITS")"
back="$(client "kafka-console-consumer --bootstrap-server kafka:9092 --consumer.config /tmp/good.properties \
  --topic $TOPIC --from-beginning --max-messages 1 --timeout-ms 20000 --group ${GROUP}-own")"
if grep -qF "$marker" <<< "$back"; then
  info "read back: $marker"
  ok "written and read back with a Keycloak token (temporary topic, removed at the end)"
else
  grep -m2 Exception <<< "$out$back" | cut -c1-150 | sed 's/^/    /'
  no "message not read back"
fi
pause

# --- 5 ------------------------------------------------------------------------
step "5 · What is refused"
show "kafka-console-producer ... --producer.config <config with a wrong secret> --topic $TOPIC"
out="$(client "echo should-not-arrive | kafka-console-producer --bootstrap-server kafka:9092 \
  --producer.config /tmp/bad.properties --topic $TOPIC $LIMITS")"
if grep -qiE 'invalid_client|401|Unauthorized|SaslAuthentication|LoginException|Failed to create' <<< "$out"; then
  ok "wrong secret: Keycloak issues no token, so the client never reaches Kafka"
else
  no "the client with a wrong secret was not refused"
fi
show "kafka-console-producer ... --producer.config <token config> --topic $DENIED_TOPIC"
out="$(client "echo should-not-arrive | kafka-console-producer --bootstrap-server kafka:9092 \
  --producer.config /tmp/good.properties --topic $DENIED_TOPIC $LIMITS")"
if grep -qE 'TopicAuthorizationException|TOPIC_AUTHORIZATION_FAILED|Not authorized' <<< "$out"; then
  ok "valid token, forbidden topic: the access rules refuse User:$cid on $DENIED_TOPIC"
else
  no "the write to $DENIED_TOPIC was not refused"
fi

printf '\n%sDone.%s Cleaning up the demo pod, temporary topic and consumer groups.\n' "$bold" "$reset"
